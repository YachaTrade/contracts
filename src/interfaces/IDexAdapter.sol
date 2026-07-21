// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDexAdapter — Pluggable DEX adapter interface
/// @notice Each DEX version (NadSwap V2, V3, V4) implements this interface.
///         Consumers (DexRouter, LPManager, BurnVault, LPVault) interact with
///         DEX pairs/pools exclusively through this abstraction.
///
/// @dev Push pattern: caller transfers tokens to the adapter before calling.
///      The adapter then transfers tokens to the underlying pair/pool.
interface IDexAdapter {
    /// @notice Execute a token swap on a pair/pool
    /// @dev Caller must have transferred amountIn of tokenIn to this adapter before calling
    /// @param data Arbitrary data passed to pair (enables flash swaps via INadFunCallee callback)
    function swap(address pair, address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata data)
        external
        returns (uint256 amountOut);

    /// @notice Get expected output amount for a swap (view)
    function getAmountOut(address pair, address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);

    /// @notice Get required input amount for a desired output (view)
    function getAmountIn(address pair, address tokenOut, uint256 amountOut) external view returns (uint256 amountIn);

    /// @notice Add liquidity to a pair/pool
    /// @dev Caller must have transferred both tokens to this adapter before calling
    function addLiquidity(address pair, address tokenA, address tokenB, uint256 amountA, uint256 amountB, address to)
        external
        returns (uint256 liquidity);

    /// @notice Remove liquidity from a pair/pool
    /// @dev Caller must have transferred LP tokens to this adapter before calling
    function removeLiquidity(address pair, uint256 liquidity, address to)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Get claimable fee amounts for a pair/pool (view)
    function claimableFees(address pair, uint256 liquidity) external view returns (uint256 amount0, uint256 amount1);

    /// @notice Claim accumulated trading fees from a pair/pool
    function claimFees(address pair, uint256 liquidity, address to) external returns (uint256 amount0, uint256 amount1);
}
