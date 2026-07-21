// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVaultRegistry} from "../interfaces/IVaultRegistry.sol";
import {IVault} from "../interfaces/IVault.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

//
//
//

/// @notice Admin registers singleton vaults. Admin can deactivate.
contract VaultRegistry is IVaultRegistry, UUPSUpgradeable, AccessManagedUpgradeable {
    mapping(address => VaultInfo) private _vaults;
    mapping(address => bool) private _registered;

    function initialize(address protocolManager_) external initializer {
        __AccessManaged_init(protocolManager_);
    }

    /// @inheritdoc IVaultRegistry
    //
    function register(address vault, string calldata name, string calldata description, VaultType vaultType)
        external
        restricted
    {
        if (vault == address(0)) revert InvalidImplementation();
        if (!ERC165Checker.supportsInterface(vault, type(IVault).interfaceId)) revert InvalidImplementation();
        if (bytes(name).length == 0) revert InvalidMetadata();
        if (_registered[vault]) revert AlreadyRegistered();

        _registered[vault] = true;
        _vaults[vault] =
            VaultInfo({name: name, description: description, creator: msg.sender, active: true, vaultType: vaultType});

        emit Register(vault, name, msg.sender, vaultType);
    }

    /// @inheritdoc IVaultRegistry
    function setActive(address vault, bool active) external restricted {
        if (!_registered[vault]) revert VaultNotFound();
        _vaults[vault].active = active;
        emit Deactivate(vault, active);
    }

    /// @inheritdoc IVaultRegistry
    function isActive(address vault) external view returns (bool) {
        return _registered[vault] && _vaults[vault].active;
    }

    /// @inheritdoc IVaultRegistry
    function getVaultInfo(address vault) external view returns (VaultInfo memory) {
        if (!_registered[vault]) revert VaultNotFound();
        return _vaults[vault];
    }

    /// @inheritdoc IVaultRegistry
    function isRegistered(address vault) external view returns (bool) {
        return _registered[vault];
    }

    /// @inheritdoc IVaultRegistry
    function getVaultType(address vault) external view returns (VaultType) {
        if (!_registered[vault]) revert VaultNotFound();
        return _vaults[vault].vaultType;
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}
}
