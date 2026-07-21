// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {INadFunPair} from "../dex/interfaces/INadFunPair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ──────────────────────────────────────────────────────────────────────
// NadSwapAdapter — NadFunPair (V2 AMM) adapter (thin wrapper)
//
// Stateless adapter delegating AMM views to NadFunPair.getAmountOut/getAmountIn.
// Push pattern: caller transfers tokens to adapter, adapter transfers to pair.
//
// NadFunPair is the single source of truth for fee-aware AMM math.
// This adapter provides the IDexAdapter interface for pluggable DEX support.
// ──────────────────────────────────────────────────────────────────────

/// @title NadSwapAdapter — IDexAdapter for NadFunPair (V2 AMM)
/// @notice Thin wrapper. Delegates AMM views to pair, handles swap execution and liquidity.
contract NadSwapAdapter is IDexAdapter {
    using SafeERC20 for IERC20;

    error NoClaims();
    error TokenMismatch();

    // ─── IDexAdapter: Swap ──────────────────────────────────

    /// @inheritdoc IDexAdapter
    function swap(address pair, address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata data)
        external
        returns (uint256 amountOut)
    {
        address token0 = INadFunPair(pair).token0();
        address token1 = INadFunPair(pair).token1();
        if (!((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0))) {
            revert TokenMismatch();
        }

        IERC20(tokenIn).safeTransfer(pair, amountIn);

        amountOut = INadFunPair(pair).getAmountOut(tokenIn, amountIn);

        if (tokenIn == token0) {
            INadFunPair(pair).swap(0, amountOut, to, data);
        } else {
            INadFunPair(pair).swap(amountOut, 0, to, data);
        }
    }

    // ─── IDexAdapter: Views ─────────────────────────────────

    /// @inheritdoc IDexAdapter
    function getAmountOut(address pair, address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        amountOut = INadFunPair(pair).getAmountOut(tokenIn, amountIn);
    }

    /// @inheritdoc IDexAdapter
    function getAmountIn(address pair, address tokenOut, uint256 amountOut) external view returns (uint256 amountIn) {
        amountIn = INadFunPair(pair).getAmountIn(tokenOut, amountOut);
    }

    // ─── IDexAdapter: Liquidity ─────────────────────────────

    /// @inheritdoc IDexAdapter
    function addLiquidity(address pair, address tokenA, address tokenB, uint256 amountA, uint256 amountB, address to)
        external
        returns (uint256 liquidity)
    {
        IERC20(tokenA).safeTransfer(pair, amountA);
        IERC20(tokenB).safeTransfer(pair, amountB);
        liquidity = INadFunPair(pair).mint(to);
    }

    /// @inheritdoc IDexAdapter
    function removeLiquidity(address pair, uint256 liquidity, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        IERC20(pair).safeTransfer(pair, liquidity);
        (amount0, amount1) = INadFunPair(pair).burn(to);
    }

    // ─── IDexAdapter: Fee Claims ────────────────────────────

    /// @inheritdoc IDexAdapter
    /// @dev NadFunPair V2 has fees embedded in reserves — no separate claiming.
    function claimableFees(address, uint256) external pure returns (uint256, uint256) {
        revert NoClaims();
    }

    /// @inheritdoc IDexAdapter
    /// @dev NadFunPair V2 has fees embedded in reserves — no separate claiming.
    function claimFees(address, uint256, address) external pure returns (uint256, uint256) {
        revert NoClaims();
    }
}
