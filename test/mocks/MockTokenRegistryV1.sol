// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITokenRegistryV1} from "../../src/integration/interfaces/ITokenRegistryV1.sol";

/// @notice Test-only mock for nadfun V1 TokenRegistry.
/// @dev Mirrors the V1 ABI shape: tokenInfos(token) -> (pool, lpManager, dexDeployer).
///      Registration is considered active when pool != address(0).
contract MockTokenRegistryV1 is ITokenRegistryV1 {
    struct TokenInfo {
        address pool;
        address lpManager;
        address dexDeployer;
    }

    mapping(address => TokenInfo) private _tokens;

    function tokenInfos(address token)
        external
        view
        override
        returns (address pool, address lpManager, address dexDeployer)
    {
        TokenInfo memory info = _tokens[token];
        return (info.pool, info.lpManager, info.dexDeployer);
    }

    /// @notice Test helper: register a token with the given pool address.
    function register(address token, address pool) external {
        _tokens[token] = TokenInfo({pool: pool, lpManager: address(0), dexDeployer: address(0)});
    }

    /// @notice Test helper: register with all fields (for completeness tests).
    function registerFull(address token, address pool, address lpManager, address dexDeployer) external {
        _tokens[token] = TokenInfo({pool: pool, lpManager: lpManager, dexDeployer: dexDeployer});
    }
}
