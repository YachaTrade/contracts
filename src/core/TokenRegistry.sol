// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";

/// @title TokenRegistry
/// @notice Source of truth for token metadata such as pair, quote token, and DEX type.
/// @dev Also stores the adapter mapping used by routers and vaults for DEX-specific interactions.
contract TokenRegistry is ITokenRegistry, UUPSUpgradeable, AccessManagedUpgradeable {
    error AlreadyRegistered();
    error ZeroAddress();

    mapping(address => TokenInfo) private _tokens;
    mapping(DexType => IDexAdapter) private _adapters;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address protocolManager_) external initializer {
        __AccessManaged_init(protocolManager_);
    }

    /// @inheritdoc ITokenRegistry
    function register(address token, address pair, address quoteToken, DexType dexType) external restricted {
        if (_tokens[token].pair != address(0)) revert AlreadyRegistered();
        // Enforce non-zero inputs so the `pair != 0` registration invariant (used by both the
        // AlreadyRegistered guard above and isRegistered()) cannot be bypassed by a pair=0
        // registration that later gets overwritten.
        if (token == address(0) || pair == address(0) || quoteToken == address(0)) revert ZeroAddress();

        _tokens[token] = TokenInfo({pair: pair, quoteToken: quoteToken, dexType: dexType});
    }

    /// @inheritdoc ITokenRegistry
    function getPair(address token) external view returns (address) {
        return _tokens[token].pair;
    }

    /// @inheritdoc ITokenRegistry
    function getQuoteToken(address token) external view returns (address) {
        return _tokens[token].quoteToken;
    }

    /// @inheritdoc ITokenRegistry
    function getDexType(address token) external view returns (DexType) {
        return _tokens[token].dexType;
    }

    /// @inheritdoc ITokenRegistry
    function getTokenInfo(address token) external view returns (TokenInfo memory) {
        return _tokens[token];
    }

    /// @inheritdoc ITokenRegistry
    function isRegistered(address token) external view returns (bool) {
        return _tokens[token].pair != address(0);
    }

    /// @inheritdoc ITokenRegistry
    function getAdapter(DexType dexType) external view returns (IDexAdapter) {
        return _adapters[dexType];
    }

    /// @inheritdoc ITokenRegistry
    function setAdapter(DexType dexType, IDexAdapter adapter) external restricted {
        _adapters[dexType] = adapter;
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}
}
