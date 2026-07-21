// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @title UniswapV3ExternalAdapter - IDexAdapter for an external Capricorn CL / Uniswap V3 pool.
/// @notice Stateless at rest. Push pattern: caller transfers tokenIn to the adapter, then the
///         adapter pays the caller-supplied pool from the swap callback and refunds unspent input.
/// @dev Trust boundary: this adapter does not verify the pool factory. `_expectedPool` only proves
///      the callback came from the pool currently executing this swap. Pool authenticity is the
///      caller's responsibility through trusted route resolution and restricted admin configuration.
contract UniswapV3ExternalAdapter is IDexAdapter {
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;

    error NoPair();
    error NotSupported();
    error TokenMismatch();
    error SwapInProgress();
    error NoCallback();
    error NotExpectedPool();
    error InvalidDelta();
    error ExcessiveInput();

    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    address private _expectedPool;

    /// @inheritdoc IDexAdapter
    function swap(address pool, address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata)
        external
        returns (uint256 amountOut)
    {
        if (_expectedPool != address(0)) revert SwapInProgress();
        if (pool == address(0)) revert NoPair();

        bool zeroForOne;
        {
            address token0 = IUniswapV3PoolLike(pool).token0();
            address token1 = IUniswapV3PoolLike(pool).token1();
            if (!((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0))) {
                revert TokenMismatch();
            }
            zeroForOne = tokenIn == token0;
        }

        _expectedPool = pool;
        bytes memory data = abi.encode(tokenIn, amountIn, zeroForOne);
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
        (int256 amount0, int256 amount1) =
            IUniswapV3PoolLike(pool).swap(to, zeroForOne, amountIn.toInt256(), sqrtPriceLimitX96, data);
        if (_expectedPool != address(0)) revert NoCallback();

        amountOut = (-(zeroForOne ? amount1 : amount0)).toUint256();

        uint256 refund = IERC20(tokenIn).balanceOf(address(this));
        if (refund != 0) IERC20(tokenIn).safeTransfer(msg.sender, refund);
    }

    /// @notice Pays a Capricorn CL pool the positive swap delta owed by this adapter.
    function capricornCLSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _swapCallback(amount0Delta, amount1Delta, data);
    }

    /// @notice Pays a standard Uniswap V3-style pool the positive swap delta owed by this adapter.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _swapCallback(amount0Delta, amount1Delta, data);
    }

    /// @notice Pays a Pancake V3-style pool the positive swap delta owed by this adapter.
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _swapCallback(amount0Delta, amount1Delta, data);
    }

    // Rule-of-three exception: both callback selectors share this security-critical validation.
    function _swapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) private {
        if (msg.sender != _expectedPool) revert NotExpectedPool();
        _expectedPool = address(0);

        bool amount0Positive = amount0Delta > 0;
        bool amount1Positive = amount1Delta > 0;
        if (amount0Positive == amount1Positive) revert InvalidDelta();

        (address tokenIn, uint256 amountIn, bool zeroForOne) = abi.decode(data, (address, uint256, bool));
        uint256 owed = amount0Positive ? amount0Delta.toUint256() : amount1Delta.toUint256();
        if (owed > amountIn) revert ExcessiveInput();

        // The owed (positive) delta must sit on tokenIn's side. zeroForOne was computed and
        // encoded by swap() itself — no need to re-ask the pool for token0 here.
        if (amount0Positive != zeroForOne) revert InvalidDelta();

        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }

    // Unused IDexAdapter members. V3 has no direct on-chain view quote; DividendVault only calls swap.

    /// @inheritdoc IDexAdapter
    function getAmountOut(address, address, uint256) external pure returns (uint256) {
        revert NotSupported();
    }

    /// @inheritdoc IDexAdapter
    function getAmountIn(address, address, uint256) external pure returns (uint256) {
        revert NotSupported();
    }

    /// @inheritdoc IDexAdapter
    function addLiquidity(address, address, address, uint256, uint256, address) external pure returns (uint256) {
        revert NotSupported();
    }

    /// @inheritdoc IDexAdapter
    function removeLiquidity(address, uint256, address) external pure returns (uint256, uint256) {
        revert NotSupported();
    }

    /// @inheritdoc IDexAdapter
    function claimableFees(address, uint256) external pure returns (uint256, uint256) {
        revert NotSupported();
    }

    /// @inheritdoc IDexAdapter
    function claimFees(address, uint256, address) external pure returns (uint256, uint256) {
        revert NotSupported();
    }
}
