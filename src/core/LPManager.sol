// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ILPManager} from "../interfaces/ILPManager.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {ICreatorFeeProcessor} from "../interfaces/ICreatorFeeProcessor.sol";
import {IV3LiquidityActor} from "../interfaces/IV3LiquidityActor.sol";
import {IV3SwapAdapter} from "../interfaces/IV3SwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BPS} from "../libraries/Constants.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";

interface ICreatorFeeProcessorGraph {
    function protocolManager() external view returns (address);
}

contract LPManager is ILPManager, UUPSUpgradeable, AccessManagedUpgradeable {
    using SafeERC20 for IERC20;
    address private _tokenRegistry;
    mapping(address => mapping(address => uint256)) private _liquidities;
    address public v3Factory;
    address public v3LiquidityActor;
    mapping(address => ILPManager.PoolData) private _pools;
    bool private _entered;
    address public creatorFeeProcessor;
    address public v3SwapAdapter;
    error InvalidFactory();
    error InvalidPool();
    error InvalidConfig();
    error InvalidBatch();
    error DuplicateToken(address token);
    error UnauthorizedCaller();
    error BalanceDelta();
    event V3Allocation(address indexed token, address indexed pool, uint256 tokenUsed, uint256 quoteUsed);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address protocolManager_,
        address tokenRegistry_,
        address creatorFeeProcessor_,
        address v3SwapAdapter_
    ) external initializer {
        if (
            protocolManager_.code.length == 0 || tokenRegistry_.code.length == 0
                || creatorFeeProcessor_.code.length == 0 || v3SwapAdapter_.code.length == 0
        ) revert InvalidConfig();
        try ICreatorFeeProcessorGraph(creatorFeeProcessor_).protocolManager() returns (address processorManager) {
            if (processorManager != protocolManager_) revert InvalidConfig();
        } catch {
            revert InvalidConfig();
        }
        if (IV3SwapAdapter(v3SwapAdapter_).tokenRegistry() != tokenRegistry_) revert InvalidConfig();
        __AccessManaged_init(protocolManager_);
        _tokenRegistry = tokenRegistry_;
        creatorFeeProcessor = creatorFeeProcessor_;
        v3SwapAdapter = v3SwapAdapter_;
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
        if (IV3SwapAdapter(v3SwapAdapter).factory() != factory) revert InvalidFactory();
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

    function collect(address[] calldata tokens) external restricted nonReentrant {
        uint256 length = tokens.length;
        if (length == 0) revert InvalidBatch();

        for (uint256 i; i < length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (tokens[i] == tokens[j]) revert DuplicateToken(tokens[i]);
            }
        }

        for (uint256 i; i < length; ++i) {
            _collect(tokens[i]);
        }
    }

    function _collect(address token) private {
        ILPManager.PoolData memory live = _validatedStoredPool(token);
        uint256 tokenBalanceEntry = IERC20(token).balanceOf(address(this));
        uint256 quoteBalanceEntry = IERC20(live.quoteToken).balanceOf(address(this));
        (uint256 tokenFee, uint256 directQuoteFee) = _collectRawFees(token, live, tokenBalanceEntry, quoteBalanceEntry);
        uint256 swappedQuote = _swapCollectedToken(token, live, tokenFee, tokenBalanceEntry);
        (uint256 protocolQuote, uint256 creatorQuote) =
            _distributeCollectedQuote(token, live.quoteToken, directQuoteFee + swappedQuote);

        _requireBalance(IERC20(token), tokenBalanceEntry);
        _requireBalance(IERC20(live.quoteToken), quoteBalanceEntry);
        emit V3FeesCollected(
            token, live.quoteToken, tokenFee, directQuoteFee, swappedQuote, protocolQuote, creatorQuote
        );
    }

    function _validatedStoredPool(address token) private view returns (ILPManager.PoolData memory live) {
        ILPManager.PoolData memory stored = _pools[token];
        if (stored.pool == address(0)) revert InvalidPool();
        live = _loadPoolData(token);
        if (live.pool != stored.pool) revert InvalidPool();
    }

    function _collectRawFees(
        address token,
        ILPManager.PoolData memory poolData,
        uint256 tokenBalanceEntry,
        uint256 quoteBalanceEntry
    ) private returns (uint256 tokenFee, uint256 directQuoteFee) {
        IERC20 launchToken = IERC20(token);
        IERC20 quoteToken = IERC20(poolData.quoteToken);
        (uint256 amount0, uint256 amount1) = IV3LiquidityActor(v3LiquidityActor).collectFees(poolData.pool);
        tokenFee = poolData.quoteIsToken0 ? amount1 : amount0;
        directQuoteFee = poolData.quoteIsToken0 ? amount0 : amount1;
        _requireBalanceIncrease(launchToken, address(this), tokenBalanceEntry, tokenFee);
        _requireBalanceIncrease(quoteToken, address(this), quoteBalanceEntry, directQuoteFee);
    }

    function _distributeCollectedQuote(address token, address quoteTokenAddress, uint256 totalQuote)
        private
        returns (uint256 protocolQuote, uint256 creatorQuote)
    {
        IProtocolManager.QuoteConfig memory config = IProtocolManager(authority()).getConfig(quoteTokenAddress);
        if (!config.active || config.lpFeeProtocolShareBps > BPS) revert InvalidConfig();

        protocolQuote = totalQuote * config.lpFeeProtocolShareBps / BPS;
        creatorQuote = totalQuote - protocolQuote;
        IERC20 quoteToken = IERC20(quoteTokenAddress);
        if (protocolQuote != 0) {
            _pushExact(quoteToken, IProtocolManager(authority()).feeReceiver(), protocolQuote);
        }
        if (creatorQuote != 0) {
            quoteToken.forceApprove(creatorFeeProcessor, creatorQuote);
            ICreatorFeeProcessor(creatorFeeProcessor).processCreatorFee(token, quoteTokenAddress, creatorQuote);
        }
        quoteToken.forceApprove(creatorFeeProcessor, 0);
    }

    function _swapCollectedToken(
        address token,
        ILPManager.PoolData memory poolData,
        uint256 tokenFee,
        uint256 tokenBalanceEntry
    ) private returns (uint256 swappedQuote) {
        if (tokenFee == 0) return 0;

        IERC20 launchToken = IERC20(token);
        IERC20 quoteToken = IERC20(poolData.quoteToken);
        uint256 quoteBalanceBefore = quoteToken.balanceOf(address(this));
        launchToken.forceApprove(v3SwapAdapter, tokenFee);
        (uint256 amountIn, uint256 amountOut) = IV3SwapAdapter(v3SwapAdapter)
            .exactInput(
                IV3SwapAdapter.ExactInputParams({
                    token: token,
                    tokenIn: token,
                    amountIn: tokenFee,
                    amountOutMin: 0,
                    recipient: address(this),
                    sqrtPriceLimitX96: poolData.quoteIsToken0
                        ? TickMath.MAX_SQRT_RATIO - 1
                        : TickMath.MIN_SQRT_RATIO + 1,
                    deadline: block.timestamp
                })
            );
        launchToken.forceApprove(v3SwapAdapter, 0);
        if (amountIn != tokenFee) revert BalanceDelta();
        _requireBalance(launchToken, tokenBalanceEntry);
        _requireBalanceIncrease(quoteToken, address(this), quoteBalanceBefore, amountOut);
        return amountOut;
    }

    function _pushExact(IERC20 token, address recipient, uint256 amount) private {
        uint256 senderBalanceBefore = token.balanceOf(address(this));
        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        if (senderBalanceBefore < amount) revert BalanceDelta();
        _requireBalance(token, senderBalanceBefore - amount);
        _requireBalanceIncrease(token, recipient, recipientBalanceBefore, amount);
    }

    function _requireBalanceIncrease(IERC20 token, address account, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        if (amount > type(uint256).max - balanceBefore) revert BalanceDelta();
        if (token.balanceOf(account) != balanceBefore + amount) revert BalanceDelta();
    }

    function _requireBalance(IERC20 token, uint256 balance) private view {
        if (token.balanceOf(address(this)) != balance) revert BalanceDelta();
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
                || i.dexType != ITokenRegistry.DexType.UniswapV3
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

    /// @inheritdoc ILPManager
    function callStaticGetAccumulatedFees(address token)
        public
        view
        override
        returns (uint256 quoteAmount, uint256 tokenAmount)
    {
        ILPManager.PoolData memory poolData = _pools[token];
        if (poolData.pool == address(0)) revert InvalidPool();

        (uint256 amount0, uint256 amount1) = IV3LiquidityActor(v3LiquidityActor).viewFees(poolData.pool);
        (quoteAmount, tokenAmount) = poolData.quoteIsToken0 ? (amount0, amount1) : (amount1, amount0);
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
