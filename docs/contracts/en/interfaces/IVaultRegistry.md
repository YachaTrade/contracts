# IVaultRegistry

**Path:** `src/interfaces/IVaultRegistry.sol`
**Type:** Interface

Admin-only vault registry interface. Only the owner can register vault singleton addresses with a designated VaultType. Admin can deactivate vulnerable vault types. Keyed by vault address to prevent duplicate registrations.

---

## Enums

### VaultType

```solidity
enum VaultType { Custom, Burn, LP, Creator, Gift }
```

---

## Structs

### VaultInfo

```solidity
struct VaultInfo {
    string name;        // Vault name (e.g., "BurnVault")
    string description; // Vault behavior description
    address creator;    // Registrant address
    bool active;        // Active status — false prevents use in new token creation
    VaultType vaultType; // Categorization of vault behavior
}
```

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `register(vault, name, description, vaultType)` | — | Register new vault (onlyOwner) |
| `setActive(vault, active)` | — | Activate/deactivate vault (onlyOwner) |
| `isActive(vault)` | `bool` | Whether vault is registered and active |
| `getVaultInfo(vault)` | `VaultInfo` | Full vault info |
| `isRegistered(vault)` | `bool` | Whether vault is registered (regardless of active status) |
| `getVaultType(vault)` | `VaultType` | Get the VaultType of a registered vault |

---

## Events

| Event | Parameters |
|-------|------------|
| `VaultRegistered` | `address indexed vault, string name, address creator, VaultType vaultType` |
| `VaultDeactivated` | `address indexed vault, bool active` |

## Errors

| Error | Description |
|-------|-------------|
| `InvalidImplementation()` | Zero address vault |
| `InvalidMetadata()` | Empty name |
| `AlreadyRegistered()` | Duplicate registration |
| `VaultNotFound()` | Unregistered vault queried |
