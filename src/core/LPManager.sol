// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILPManager} from "../interfaces/ILPManager.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {INadFunPair} from "../dex/interfaces/INadFunPair.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LPManager
/// @notice Executes liquidity actions through the configured DEX adapter and tracks LP balances per caller.
/// @dev Uses TokenRegistry as the pair source of truth and keeps only LP accounting state locally.
contract LPManager is ILPManager, UUPSUpgradeable, AccessManagedUpgradeable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------
    // Errors
    // -------------------------------------------------------

    error AddLiquidityFailed();
    error InsufficientTokenBalance();
    error NoClaimableFees();
    error UnsupportedDexType();

    // -------------------------------------------------------
    // State
    // -------------------------------------------------------

    address private _tokenRegistry;

    mapping(address => mapping(address => uint256)) private _liquidities;

    // -------------------------------------------------------
    // Constructor (disable initializers for UUPS)
    // -------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -------------------------------------------------------
    // Initializer
    // -------------------------------------------------------

    /// @notice Initialize the LPManager proxy
    /// @param protocolManager_ ProtocolManager proxy address (admin source)
    /// @param tokenRegistry_ TokenRegistry address for adapter lookup
    function initialize(address protocolManager_, address tokenRegistry_) external initializer {
        __AccessManaged_init(protocolManager_);
        _tokenRegistry = tokenRegistry_;
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    /// @inheritdoc ILPManager
    function addLiquidity(
        address token,
        address quoteToken,
        uint256 tokenIn,
        uint256 quoteIn,
        ITokenRegistry.DexType dexType,
        address pair
    ) external restricted returns (uint256 liquidity) {
        if (IERC20(token).balanceOf(address(this)) < tokenIn) revert InsufficientTokenBalance();
        if (IERC20(quoteToken).balanceOf(address(this)) < quoteIn) revert InsufficientTokenBalance();

        if (dexType == ITokenRegistry.DexType.UniswapV2) {
            liquidity = _addLiquidityV2(token, quoteToken, tokenIn, quoteIn, pair);
        } else {
            revert UnsupportedDexType();
        }

        _liquidities[token][msg.sender] += liquidity;

        emit Allocate(token, pair, msg.sender, dexType, tokenIn, quoteIn, liquidity);
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    /// @inheritdoc ILPManager
    function claimFees(address token) external returns (uint256 amount0, uint256 amount1) {
        address pair = ITokenRegistry(_tokenRegistry).getPair(token);
        require(pair != address(0), "Token not registered");

        ITokenRegistry.DexType dexType = ITokenRegistry(_tokenRegistry).getDexType(token);

        if (dexType == ITokenRegistry.DexType.UniswapV2) {
            (amount0, amount1) = _claimFeesV2(pair);
        } else {
            revert UnsupportedDexType();
        }

        emit ClaimFee(token, IProtocolManager(authority()).feeReceiver(), dexType, amount0, amount1);
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    /// @inheritdoc ILPManager
    function getPair(address token) external view returns (address) {
        return ITokenRegistry(_tokenRegistry).getPair(token);
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    /// @inheritdoc ILPManager
    function getLiquidity(address token, address caller) external view returns (uint256) {
        return _liquidities[token][caller];
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    function _addLiquidityV2(address token, address quoteToken, uint256 tokenIn, uint256 quoteIn, address pair)
        internal
        returns (uint256 liquidity)
    {
        IDexAdapter adapter = ITokenRegistry(_tokenRegistry).getAdapter(ITokenRegistry.DexType.UniswapV2);
        require(address(adapter) != address(0), "V2 adapter not set");

        // Sweep any tokens donated directly to the pair before mint. V2 `mint()` credits
        // liquidity based on `balance - reserve`, so pre-donated quote (Token.sol blocks the
        // base-token side) would otherwise skew the initial reserves and launch price.
        INadFunPair(pair).skim(IProtocolManager(authority()).feeReceiver());

        IERC20(token).safeTransfer(address(adapter), tokenIn);
        IERC20(quoteToken).safeTransfer(address(adapter), quoteIn);
        liquidity = adapter.addLiquidity(pair, token, quoteToken, tokenIn, quoteIn, address(this));

        if (liquidity == 0) revert AddLiquidityFailed();
    }

    function _claimFeesV2(address) internal pure returns (uint256, uint256) {
        revert NoClaimableFees();
    }

    // -------------------------------------------------------
    // View helpers
    // -------------------------------------------------------

    /// @notice Returns the fee receiver address (queried from ProtocolManager)
    function feeReceiver() external view returns (address) {
        return IProtocolManager(authority()).feeReceiver();
    }

    // -------------------------------------------------------
    // UUPS
    // -------------------------------------------------------

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    /// @dev Only the admin can authorize upgrades
    function _authorizeUpgrade(address) internal override restricted {}
}
