// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVaultRegistry
/// @notice Registry interface for singleton vault contracts used during token creation.

/// @notice Stores vault metadata with VaultType classification.
///         Admin registers and can deactivate vaults.
interface IVaultRegistry {
    // Append-only: ordinals are storage/ABI commitments for the deployed VaultRegistry UUPS proxy.
    enum VaultType {
        Custom,
        Burn,
        LP,
        Creator,
        Gift,
        Dividend
    }

    struct VaultInfo {
        string name;
        string description;
        address creator;
        bool active;
        VaultType vaultType;
    }

    event Register(address indexed vault, string name, address creator, VaultType vaultType);
    event Deactivate(address indexed vault, bool active);

    error InvalidImplementation();
    error InvalidMetadata();
    error AlreadyRegistered();
    error VaultNotFound();

    /// @notice Register a new singleton vault. Admin only.
    /// @param vault The singleton vault contract address
    /// @param name Human-readable name (e.g., "BurnVault")
    /// @param description Short description of vault behavior
    /// @param vaultType The vault's behavior classification
    function register(address vault, string calldata name, string calldata description, VaultType vaultType) external;

    /// @notice Activate or deactivate a vault. Admin only.
    /// @param vault The vault to modify
    /// @param active Whether the vault should be active
    function setActive(address vault, bool active) external;

    /// @notice Check if a vault is registered and active.
    /// @param vault The vault to query
    /// @return Whether the vault is active
    function isActive(address vault) external view returns (bool);

    /// @notice Get full info for a vault.
    /// @param vault The vault to query
    /// @return info The VaultInfo struct
    function getVaultInfo(address vault) external view returns (VaultInfo memory info);

    /// @notice Check if a vault is registered.
    /// @param vault The vault to query
    /// @return Whether the vault is registered
    function isRegistered(address vault) external view returns (bool);

    /// @notice Get the VaultType of a registered vault.
    /// @param vault The vault to query
    /// @return The VaultType enum value
    function getVaultType(address vault) external view returns (VaultType);
}
