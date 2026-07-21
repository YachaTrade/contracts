// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICapricornCLSwapCallbackLike {
    function capricornCLSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IUniswapV3SwapCallbackLike {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IPancakeV3SwapCallbackLike {
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Capricorn CL (Uniswap V3 fork) pool mock: fixed-rate exact-input swap + swap callback.
///         CallbackMode lets adapter tests exercise hostile/nonstandard pools: missing callback,
///         double callback, corrupt deltas, mid-swap reentrancy, and partial fills (fillBps).
contract MockCapricornPool {
    enum CallbackMode {
        Capricorn, // capricornCLSwapCallback (default)
        UniswapV3, // uniswapV3SwapCallback (standard V3 fork selector)
        PancakeV3, // pancakeV3SwapCallback (Pancake V3 fork selector)
        None, // return without calling back
        Double, // call the callback twice
        BothPositive, // report both deltas positive (corrupt pool)
        Reenter // attempt a reentrant adapter.swap before the real callback
    }

    address public token0;
    address public token1;
    /// @dev amountOut = consumedIn * rateNumerator / rateDenominator
    uint256 public rateNumerator = 1;
    uint256 public rateDenominator = 1;
    /// @dev Portion of amountSpecified actually consumed; < 10000 simulates a partial fill
    ///      (liquidity exhausted), > 10000 simulates a greedy pool over-charging the input.
    uint256 public fillBps = 10_000;
    CallbackMode public callbackMode = CallbackMode.Capricorn;

    /// @dev Reenter mode: raw calldata fired at msg.sender (the adapter) before the real callback.
    bytes public reenterCall;
    bool public reenterReverted;
    bytes public reenterRevertData;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setRate(uint256 numerator, uint256 denominator) external {
        rateNumerator = numerator;
        rateDenominator = denominator;
    }

    function setFillBps(uint256 newFillBps) external {
        fillBps = newFillBps;
    }

    function setCallbackMode(CallbackMode mode) external {
        callbackMode = mode;
    }

    function setReenterCall(bytes calldata call_) external {
        reenterCall = call_;
    }

    /// @dev Uniswap V3 exact-input semantics: positive delta = owed to the pool (input side),
    ///      negative delta = paid out by the pool (output side).
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "MockCapricornPool: exact-input only");

        if (callbackMode == CallbackMode.Reenter) {
            (bool ok, bytes memory returnData) = msg.sender.call(reenterCall);
            reenterReverted = !ok;
            reenterRevertData = returnData;
        }

        uint256 consumedIn = (uint256(amountSpecified) * fillBps) / 10_000;
        uint256 amountOut = (consumedIn * rateNumerator) / rateDenominator;
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);

        if (callbackMode == CallbackMode.BothPositive) {
            (amount0, amount1) = (int256(consumedIn), int256(consumedIn));
        } else {
            (amount0, amount1) =
                zeroForOne ? (int256(consumedIn), -int256(amountOut)) : (-int256(amountOut), int256(consumedIn));
        }

        IERC20(tokenOut).transfer(recipient, amountOut);

        if (callbackMode == CallbackMode.None) return (amount0, amount1);

        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));

        if (callbackMode == CallbackMode.UniswapV3) {
            IUniswapV3SwapCallbackLike(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        } else if (callbackMode == CallbackMode.PancakeV3) {
            IPancakeV3SwapCallbackLike(msg.sender).pancakeV3SwapCallback(amount0, amount1, data);
        } else {
            ICapricornCLSwapCallbackLike(msg.sender).capricornCLSwapCallback(amount0, amount1, data);
            if (callbackMode == CallbackMode.Double) {
                ICapricornCLSwapCallbackLike(msg.sender).capricornCLSwapCallback(amount0, amount1, data);
            }
        }

        if (callbackMode != CallbackMode.BothPositive) {
            require(
                IERC20(tokenIn).balanceOf(address(this)) >= balanceBefore + consumedIn,
                "MockCapricornPool: input not paid"
            );
        }
    }
}
