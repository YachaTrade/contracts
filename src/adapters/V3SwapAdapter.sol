// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IV3SwapAdapter} from "../interfaces/IV3SwapAdapter.sol";

/// @notice Fee-free swap entry point for canonical Uniswap V3 pools registered by launch token.
contract V3SwapAdapter is IV3SwapAdapter, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    struct ActiveSwap {
        address pool;
        address payer;
        address tokenIn;
        address tokenOut;
        uint256 amountInMax;
        bytes32 dataHash;
    }

    struct SwapCallbackData {
        address pool;
        address payer;
        address token;
        address tokenIn;
        address tokenOut;
        uint24 feeTier;
        uint256 nonce;
    }

    struct ResolvedPool {
        address pool;
        address tokenOut;
        uint24 feeTier;
        bool zeroForOne;
    }

    struct BalanceSnapshot {
        uint256 payerInput;
        uint256 recipientOutput;
    }

    address private immutable FACTORY;
    address private immutable TOKEN_REGISTRY;

    ActiveSwap private _activeSwap;
    uint256 private _swapNonce;
    bool private _entered;

    constructor(address factoryAddress, address tokenRegistryAddress) {
        if (factoryAddress == address(0) || factoryAddress.code.length == 0) revert InvalidFactory();
        if (tokenRegistryAddress == address(0) || tokenRegistryAddress.code.length == 0) revert InvalidRegistry();
        FACTORY = factoryAddress;
        TOKEN_REGISTRY = tokenRegistryAddress;
    }

    modifier nonReentrant() {
        _enter();
        _;
        _exit();
    }

    function _enter() private {
        if (_entered) revert ReentrantCall();
        _entered = true;
    }

    function _exit() private {
        _entered = false;
    }

    /// @inheritdoc IV3SwapAdapter
    function factory() external view override returns (address) {
        return FACTORY;
    }

    /// @inheritdoc IV3SwapAdapter
    function tokenRegistry() external view override returns (address) {
        return TOKEN_REGISTRY;
    }

    /// @inheritdoc IV3SwapAdapter
    function exactInput(ExactInputParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (params.deadline < block.timestamp) revert ExpiredDeadline();
        if (params.amountIn == 0 || params.amountIn > uint256(type(int256).max)) revert InvalidAmountIn();
        _validateRecipientAndPrice(params.recipient, params.sqrtPriceLimitX96);

        ResolvedPool memory resolved = _resolve(params.token, params.tokenIn);
        (amountIn, amountOut) = _swap(
            params.token,
            params.tokenIn,
            params.amountIn,
            int256(params.amountIn),
            params.recipient,
            params.sqrtPriceLimitX96,
            resolved
        );
        if (amountOut < params.amountOutMin) revert InsufficientOutput(amountOut, params.amountOutMin);
    }

    /// @inheritdoc IV3SwapAdapter
    function exactOutput(ExactOutputParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (params.deadline < block.timestamp) revert ExpiredDeadline();
        if (params.amountOut == 0 || params.amountOut > uint256(type(int256).max)) revert InvalidAmountOut();
        if (params.amountInMax == 0) revert InvalidAmountIn();
        _validateRecipientAndPrice(params.recipient, params.sqrtPriceLimitX96);

        ResolvedPool memory resolved = _resolve(params.token, params.tokenIn);
        (amountIn, amountOut) = _swap(
            params.token,
            params.tokenIn,
            params.amountInMax,
            -int256(params.amountOut),
            params.recipient,
            params.sqrtPriceLimitX96,
            resolved
        );
        if (amountOut != params.amountOut) revert InvalidAmountOut();
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        ActiveSwap memory active = _activeSwap;
        if (active.pool == address(0)) revert NoActiveSwap();
        if (msg.sender != active.pool || keccak256(data) != active.dataHash) revert InvalidCallback();

        SwapCallbackData memory decoded = abi.decode(data, (SwapCallbackData));
        if (
            decoded.pool != active.pool || decoded.payer != active.payer || decoded.tokenIn != active.tokenIn
                || decoded.tokenOut != active.tokenOut || decoded.nonce != _swapNonce
        ) revert InvalidCallback();

        ITokenRegistry registry = ITokenRegistry(TOKEN_REGISTRY);
        ITokenRegistry.TokenInfo memory info = registry.getTokenInfo(decoded.token);
        if (
            info.dexType != ITokenRegistry.DexType.UniswapV3 || info.pair != decoded.pool || info.pool != decoded.pool
                || info.quoteToken == address(0) || info.feeTier != decoded.feeTier
                || registry.getTokenByPool(decoded.pool) != decoded.token
        ) revert InvalidCallback();
        if (decoded.tokenIn != decoded.token && decoded.tokenIn != info.quoteToken) revert InvalidCallback();
        address expectedTokenOut = decoded.tokenIn == decoded.token ? info.quoteToken : decoded.token;
        if (decoded.tokenOut != expectedTokenOut) revert InvalidCallback();

        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        (address expectedToken0, address expectedToken1) =
            decoded.token < info.quoteToken ? (decoded.token, info.quoteToken) : (info.quoteToken, decoded.token);
        address poolToken0 = pool.token0();
        if (
            pool.factory() != FACTORY || poolToken0 != expectedToken0 || pool.token1() != expectedToken1
                || pool.fee() != decoded.feeTier
                || IUniswapV3Factory(FACTORY).getPool(decoded.token, info.quoteToken, decoded.feeTier) != msg.sender
        ) revert InvalidCallback();

        uint256 amountOwed;
        if (decoded.tokenIn == poolToken0) {
            if (amount0Delta <= 0 || amount1Delta > 0) revert InvalidCallback();
            amountOwed = amount0Delta.toUint256();
        } else {
            if (amount1Delta <= 0 || amount0Delta > 0) revert InvalidCallback();
            amountOwed = amount1Delta.toUint256();
        }
        if (amountOwed > active.amountInMax) {
            revert ExcessiveCallbackAmount(amountOwed, active.amountInMax);
        }

        delete _activeSwap;
        IERC20(active.tokenIn).safeTransferFrom(active.payer, msg.sender, amountOwed);
    }

    function _swap(
        address token,
        address tokenIn,
        uint256 amountInMax,
        int256 amountSpecified,
        address recipient,
        uint160 sqrtPriceLimitX96,
        ResolvedPool memory resolved
    ) private returns (uint256 amountIn, uint256 amountOut) {
        BalanceSnapshot memory snapshot = BalanceSnapshot({
            payerInput: IERC20(tokenIn).balanceOf(msg.sender),
            recipientOutput: IERC20(resolved.tokenOut).balanceOf(recipient)
        });
        uint256 nonce = ++_swapNonce;
        bytes memory data = abi.encode(
            SwapCallbackData({
                pool: resolved.pool,
                payer: msg.sender,
                token: token,
                tokenIn: tokenIn,
                tokenOut: resolved.tokenOut,
                feeTier: resolved.feeTier,
                nonce: nonce
            })
        );
        _activeSwap = ActiveSwap({
            pool: resolved.pool,
            payer: msg.sender,
            tokenIn: tokenIn,
            tokenOut: resolved.tokenOut,
            amountInMax: amountInMax,
            dataHash: keccak256(data)
        });

        (int256 amount0Delta, int256 amount1Delta) =
            IUniswapV3Pool(resolved.pool).swap(recipient, resolved.zeroForOne, amountSpecified, sqrtPriceLimitX96, data);
        if (_activeSwap.pool != address(0)) revert CallbackNotConsumed();

        int256 inputDelta = resolved.zeroForOne ? amount0Delta : amount1Delta;
        int256 outputDelta = resolved.zeroForOne ? amount1Delta : amount0Delta;
        if (inputDelta <= 0) revert InvalidAmountIn();
        if (outputDelta >= 0 || outputDelta == type(int256).min) revert InvalidAmountOut();
        amountIn = inputDelta.toUint256();
        amountOut = (-outputDelta).toUint256();
        if (amountIn > amountInMax) revert ExcessiveCallbackAmount(amountIn, amountInMax);

        _requireBalanceDecrease(tokenIn, msg.sender, snapshot.payerInput, amountIn);
        _requireBalanceIncrease(resolved.tokenOut, recipient, snapshot.recipientOutput, amountOut);
    }

    function _resolve(address token, address tokenIn) private view returns (ResolvedPool memory resolved) {
        ITokenRegistry registry = ITokenRegistry(TOKEN_REGISTRY);
        ITokenRegistry.TokenInfo memory info = registry.getTokenInfo(token);
        if (
            info.dexType != ITokenRegistry.DexType.UniswapV3 || info.pair == address(0) || info.pool != info.pair
                || info.pool.code.length == 0 || info.quoteToken == address(0)
        ) revert InvalidPool();
        if (tokenIn != token && tokenIn != info.quoteToken) revert InvalidTokenIn();

        IUniswapV3Pool pool = IUniswapV3Pool(info.pool);
        (address expectedToken0, address expectedToken1) =
            token < info.quoteToken ? (token, info.quoteToken) : (info.quoteToken, token);
        if (
            pool.factory() != FACTORY || pool.token0() != expectedToken0 || pool.token1() != expectedToken1
                || pool.fee() != info.feeTier
                || IUniswapV3Factory(FACTORY).getPool(token, info.quoteToken, info.feeTier) != info.pool
                || registry.getTokenByPool(info.pool) != token
        ) revert InvalidPool();

        resolved = ResolvedPool({
            pool: info.pool,
            tokenOut: tokenIn == token ? info.quoteToken : token,
            feeTier: info.feeTier,
            zeroForOne: tokenIn == expectedToken0
        });
    }

    function _validateRecipientAndPrice(address recipient, uint160 sqrtPriceLimitX96) private pure {
        if (recipient == address(0)) revert InvalidRecipient();
        if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_RATIO || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_RATIO) {
            revert InvalidPriceLimit();
        }
    }

    function _requireBalanceDecrease(address token, address account, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        uint256 currentBalance = IERC20(token).balanceOf(account);
        uint256 requiredBalance = balanceBefore >= amount ? balanceBefore - amount : 0;
        if (balanceBefore < amount || currentBalance != requiredBalance) {
            revert InvalidBalanceDelta(token, account, requiredBalance, currentBalance);
        }
    }

    function _requireBalanceIncrease(address token, address account, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        if (amount > type(uint256).max - balanceBefore) {
            revert InvalidBalanceDelta(token, account, type(uint256).max, IERC20(token).balanceOf(account));
        }
        uint256 requiredBalance = balanceBefore + amount;
        uint256 currentBalance = IERC20(token).balanceOf(account);
        if (currentBalance != requiredBalance) {
            revert InvalidBalanceDelta(token, account, requiredBalance, currentBalance);
        }
    }
}
