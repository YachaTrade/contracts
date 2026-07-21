// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "./IDexAdapter.sol";

//
//
//

/// @notice Stores token metadata and manages DEX adapter registry.
interface ITokenRegistry {
    enum DexType {
        UniswapV2,
        UniswapV3,
        UniswapV4
    }

    struct TokenInfo {
        address pair;
        address pool;
        address quoteToken;
        DexType dexType;
        uint24 feeTier;
    }

    /// @notice Register a token with its pair, quoteToken, and dexType
    function register(address token, address pair, address quoteToken, DexType dexType) external;

    /// @notice Register a token with its canonical Uniswap V3 pool metadata.
    function registerV3(address token, address pool, address quoteToken, uint24 feeTier) external;

    /// @notice Get the DEX pair address for a token
    function getPair(address token) external view returns (address);

    /// @notice Get the canonical Uniswap V3 pool address for a token.
    function getPool(address token) external view returns (address);

    /// @notice Get the launch token registered for a canonical Uniswap V3 pool.
    function getTokenByPool(address pool) external view returns (address);

    /// @notice Get the quote token for a token
    function getQuoteToken(address token) external view returns (address);

    /// @notice Get the DEX type for a token
    function getDexType(address token) external view returns (DexType);

    /// @notice Get full token info
    function getTokenInfo(address token) external view returns (TokenInfo memory);

    /// @notice Check if a token is registered
    function isRegistered(address token) external view returns (bool);

    /// @notice Get the adapter for a DEX type
    function getAdapter(DexType dexType) external view returns (IDexAdapter);

    /// @notice Set the adapter for a DEX type
    function setAdapter(DexType dexType, IDexAdapter adapter) external;
}
