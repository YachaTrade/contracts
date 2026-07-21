// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only mock for the nadfun V1 BondingCurve (contract-v3).
/// @dev Mirrors the V1 ABI shape consumed by the DividendVault V1 admission gate:
///      createdAt(token) -> uint256 — set at create(), NEVER cleared (graduate() deletes
///      curves[token] only), so it doubles as the V1 membership signal.
///      isGraduated(token) -> bool — one-way true at graduation.
contract MockBondingCurveV1 {
    mapping(address => uint256) public createdAt;
    mapping(address => bool) public isGraduated;

    /// @notice Test helper: mark a token as created on the V1 curve (pre-graduation state).
    function createToken(address token) external {
        createdAt[token] = block.number;
    }

    /// @notice Test helper: graduate a token. createdAt stays set — mirrors real V1 behavior.
    function graduate(address token) external {
        isGraduated[token] = true;
    }
}
