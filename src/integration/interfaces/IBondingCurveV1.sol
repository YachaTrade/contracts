// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for the nadfun V1 BondingCurve admission checks.
interface IBondingCurveV1 {
    /// @notice Block number recorded at V1 create() and never cleared.
    /// @dev V1 graduate() deletes curves[token] only, so createdAt(token) != 0 doubles as V1 membership.
    function createdAt(address token) external view returns (uint256);

    /// @notice Whether a V1 token has graduated.
    /// @dev Graduation is one-way: once true, it remains true.
    function isGraduated(address token) external view returns (bool);
}
