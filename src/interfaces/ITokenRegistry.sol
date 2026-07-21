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
        address quoteToken;
        DexType dexType;
    }

    /// @notice Register a token with its pair, quoteToken, and dexType
    function register(address token, address pair, address quoteToken, DexType dexType) external;

    /// @notice Get the DEX pair address for a token
    function getPair(address token) external view returns (address);

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
