// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Test-only copy of the contract-v3 DexDeployer initialization-price formula.
contract ContractV3MathReference {
    error OverFlow();

    function calculateSqrtPrice(uint256 amount0, uint256 amount1) external pure returns (uint160 sqrtPriceX96) {
        uint256 ratioX128 = FullMath.mulDiv(amount1, uint256(1) << 128, amount0);
        uint256 sqrtRatioX64 = Math.sqrt(ratioX128);
        uint256 encoded = sqrtRatioX64 << 32;
        if (encoded > type(uint160).max) revert OverFlow();
        return uint160(encoded);
    }
}
