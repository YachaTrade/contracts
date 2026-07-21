// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Provides getAmountOut / getAmountIn for bonding curve calculations.
/// @dev Uses Solady FixedPointMathLib.mulDivUp for ceiling division; reverts on overflow.
library BondingCurveLibrary {
    /// @notice Output amount on a constant-product curve
    /// @dev amountOut = reserveOut - ceil(k / (reserveIn + amountIn))
    ///      Uses mulDivUp(k, 1, newReserveIn) for ceiling division; reverts on overflow.
    //
    //
    function getAmountOut(uint256 amountIn, uint256 k, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0 && reserveIn > 0 && reserveOut > 0, "Invalid inputs");

        uint256 newReserveIn = reserveIn + amountIn;

        uint256 newReserveOut = FixedPointMathLib.mulDivUp(k, 1, newReserveIn);

        require(newReserveOut < reserveOut, "Insufficient liquidity");

        amountOut = reserveOut - newReserveOut;
    }

    /// @notice Required input for desired output on the curve
    /// @dev newReserveIn = ceil(k / (reserveOut - amountOut)), amountIn = newReserveIn - reserveIn
    ///      Uses mulDivUp(k, 1, newReserveOut) for ceiling division; reverts on overflow.
    //
    //   1. newReserveOut = reserveOut - amountOut
    //   3. amountIn = newReserveIn - reserveIn
    //
    function getAmountIn(uint256 amountOut, uint256 k, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0 && amountOut < reserveOut, "Insufficient liquidity");

        uint256 newReserveOut = reserveOut - amountOut;

        uint256 newReserveIn = FixedPointMathLib.mulDivUp(k, 1, newReserveOut);

        require(newReserveIn > reserveIn, "No input required");

        amountIn = newReserveIn - reserveIn;
    }
}
