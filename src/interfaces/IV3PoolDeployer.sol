// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Creates and initializes canonical Uniswap V3 launch pools.
interface IV3PoolDeployer {
    error InvalidAuthority();
    error InvalidFactory();
    error InvalidFeeTier();
    error InvalidPool();
    error OverFlow();
    error QuoteTokenNotAllowed();

    /// @notice The canonical Uniswap V3 factory used for pool creation.
    function factory() external view returns (address);

    /// @notice Create and initialize the canonical pool for a token and configured quote token.
    function createPool(address token, address quoteToken) external returns (address pool);
}
