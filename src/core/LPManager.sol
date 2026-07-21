// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ILPManager} from "../interfaces/ILPManager.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {IV3LiquidityActor} from "../interfaces/IV3LiquidityActor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";

contract LPManager is ILPManager, UUPSUpgradeable, AccessManagedUpgradeable {
    using SafeERC20 for IERC20;
    address private _tokenRegistry;
    mapping(address => mapping(address => uint256)) private _liquidities;
    address public v3Factory;
    address public v3LiquidityActor;
    mapping(address => ILPManager.PoolData) private _pools;
    bool private _entered;
    error InvalidFactory();
    error InvalidPool();
    error InvalidConfig();
    error UnauthorizedCaller();
    error BalanceDelta();
    event V3Allocation(address indexed token, address indexed pool, uint256 tokenUsed, uint256 quoteUsed);

    constructor() {
        _disableInitializers();
    }

    function initialize(address protocolManager_, address tokenRegistry_) external initializer {
        __AccessManaged_init(protocolManager_);
        _tokenRegistry = tokenRegistry_;
    }
    modifier nonReentrant() {
        if (_entered) revert UnauthorizedCaller();
        _entered = true;
        _;
        _entered = false;
    }

    function setV3LiquidityActor(address actor, address factory) external restricted {
        if (
            v3LiquidityActor != address(0) || actor == address(0) || actor.code.length == 0 || factory == address(0)
                || factory.code.length == 0
        ) revert InvalidFactory();
        if (IV3LiquidityActor(actor).owner() != address(this) || IV3LiquidityActor(actor).factory() != factory) {
            revert InvalidFactory();
        }
        v3LiquidityActor = actor;
        v3Factory = factory;
    }

    function addLiquidity(address, address, uint256, uint256, ITokenRegistry.DexType, address)
        external
        pure
        returns (uint256)
    {
        revert LegacyLiquidityDisabled();
    }

    function claimFees(address) external pure returns (uint256, uint256) {
        revert LegacyLiquidityDisabled();
    }

    function allocate(AllocateParams calldata p) external restricted nonReentrant {
        ILPManager.PoolData memory d = _loadPoolData(p.token);
        d.bondingTick = calculateBondingTick(p, d.quoteIsToken0, d.tickSpacing);
        uint256 a0 = d.quoteIsToken0 ? p.quoteAmount : p.tokenAmount;
        uint256 a1 = d.quoteIsToken0 ? p.tokenAmount : p.quoteAmount;
        _approve(d.token0, a0);
        _approve(d.token1, a1);
        uint256 b0 = IERC20(d.token0).balanceOf(address(this));
        uint256 b1 = IERC20(d.token1).balanceOf(address(this));
        (uint256 u0, uint256 u1) = IV3LiquidityActor(v3LiquidityActor).mint(d, a0, a1);
        _approve(d.token0, 0);
        _approve(d.token1, 0);
        _settle(d.token0, b0, a0, u0);
        _settle(d.token1, b1, a1, u1);
        _pools[p.token] = d;
        emit V3Allocation(p.token, d.pool, d.quoteIsToken0 ? u1 : u0, d.quoteIsToken0 ? u0 : u1);
    }

    function increaseLiquidity(address token, uint256 tokenAmount, uint256 quoteAmount)
        external
        restricted
        nonReentrant
    {
        ILPManager.PoolData memory stored = _pools[token];
        if (stored.pool == address(0)) revert InvalidPool();

        ILPManager.PoolData memory live = _loadPoolData(token);
        if (live.pool != stored.pool) revert InvalidPool();
        // Keep the stored graduation metadata while refreshing only values that can
        // legitimately move between calls.
        stored.sqrtPrice = live.sqrtPrice;
        stored.currentTick = live.currentTick;
        stored.alignedTick = live.alignedTick;
        stored.token0 = live.token0;
        stored.token1 = live.token1;
        stored.quoteToken = live.quoteToken;
        stored.quoteIsToken0 = live.quoteIsToken0;
        stored.tickSpacing = live.tickSpacing;

        uint256 amount0 = stored.quoteIsToken0 ? quoteAmount : tokenAmount;
        uint256 amount1 = stored.quoteIsToken0 ? tokenAmount : quoteAmount;
        _approve(stored.token0, amount0);
        _approve(stored.token1, amount1);
        uint256 balance0Before = IERC20(stored.token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(stored.token1).balanceOf(address(this));
        (uint256 used0, uint256 used1) = IV3LiquidityActor(v3LiquidityActor).increase(stored, amount0, amount1);
        _approve(stored.token0, 0);
        _approve(stored.token1, 0);
        _settle(stored.token0, balance0Before, amount0, used0);
        _settle(stored.token1, balance1Before, amount1, used1);
    }

    function _approve(address t, uint256 a) internal {
        IERC20(t).forceApprove(v3LiquidityActor, a);
    }

    function _settle(address t, uint256 beforeBal, uint256 input, uint256 used) internal {
        if (used > input || used > beforeBal) revert BalanceDelta();
        if (IERC20(t).balanceOf(address(this)) != beforeBal - used) revert BalanceDelta();

        uint256 remainder = input - used;
        if (remainder == 0) return;
        address receiver = IProtocolManager(authority()).feeReceiver();
        uint256 receiverBefore = IERC20(t).balanceOf(receiver);
        IERC20(t).safeTransfer(receiver, remainder);
        if (
            IERC20(t).balanceOf(address(this)) != beforeBal - input
                || IERC20(t).balanceOf(receiver) != receiverBefore + remainder
        ) revert BalanceDelta();
    }

    function _loadPoolData(address token) internal view returns (ILPManager.PoolData memory d) {
        ITokenRegistry.TokenInfo memory i = ITokenRegistry(_tokenRegistry).getTokenInfo(token);
        IProtocolManager.QuoteConfig memory c = IProtocolManager(authority()).getConfig(i.quoteToken);
        if (
            !c.active || i.pool == address(0) || i.quoteToken == address(0)
                || i.dexType != ITokenRegistry.DexType.UniswapV3 || c.v3FeeTier != i.feeTier
        ) revert InvalidPool();
        if (IUniswapV3Factory(v3Factory).getPool(token, i.quoteToken, i.feeTier) != i.pool) revert InvalidPool();
        IUniswapV3Pool p = IUniswapV3Pool(i.pool);
        if (p.factory() != v3Factory || p.fee() != i.feeTier) revert InvalidPool();
        d.pool = i.pool;
        d.quoteToken = i.quoteToken;
        d.token0 = p.token0();
        d.token1 = p.token1();
        if (d.token0 != token && d.token1 != token) revert InvalidPool();
        d.quoteIsToken0 = d.token0 == i.quoteToken;
        if (!d.quoteIsToken0 && d.token1 != i.quoteToken) revert InvalidPool();
        d.tickSpacing = p.tickSpacing();
        (d.sqrtPrice, d.currentTick,,,,,) = p.slot0();
        if (d.tickSpacing <= 0) revert InvalidConfig();
        d.alignedTick = (d.currentTick / d.tickSpacing) * d.tickSpacing;
    }

    function calculateBondingTick(AllocateParams calldata p, bool q, int24 s) public pure returns (int24) {
        if (s <= 0 || p.virtualQuoteReserve <= p.graduateFee || p.virtualTokenReserve == 0) revert InvalidConfig();
        uint256 at =
            FullMath.mulDiv(p.virtualTokenReserve, p.virtualQuoteReserve, p.virtualQuoteReserve - p.graduateFee);
        uint160 sp = q ? _calculateSqrtPrice(p.virtualQuoteReserve, at) : _calculateSqrtPrice(at, p.virtualQuoteReserve);
        int24 raw = TickMath.getTickAtSqrtRatio(sp);
        int24 a = (raw / s) * s;
        return q ? a - s : a + s;
    }

    function _calculateSqrtPrice(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 ratioX128 = FullMath.mulDiv(amount1, uint256(1) << 128, amount0);
        uint256 sqrtRatioX64 = Math.sqrt(ratioX128);
        uint256 encoded = sqrtRatioX64 << 32;
        if (encoded > type(uint160).max) revert InvalidConfig();
        return uint160(encoded);
    }

    function getPositions(address token)
        external
        view
        returns (bytes32 a, int24 b, int24 c, uint128 d, bytes32 e, int24 f, int24 g, uint128 h)
    {
        address pool = _pools[token].pool;
        if (pool == address(0)) revert InvalidPool();
        (a, b, c, d) = IV3LiquidityActor(v3LiquidityActor).quoteLiquidityPositions(pool);
        (e, f, g, h) = IV3LiquidityActor(v3LiquidityActor).tokenLiquidityPositions(pool);
    }

    function getPair(address token) external view returns (address) {
        return ITokenRegistry(_tokenRegistry).getPair(token);
    }

    function getLiquidity(address, address) external pure returns (uint256) {
        return 0;
    }

    function feeReceiver() external view returns (address) {
        return IProtocolManager(authority()).feeReceiver();
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }
    function _authorizeUpgrade(address) internal override restricted {}
}
