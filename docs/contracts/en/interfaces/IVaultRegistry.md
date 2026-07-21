# IVaultRegistry

**Path:** `src/interfaces/IVaultRegistry.sol`
**Type:** Interface

Authority-restricted vault registry interface. The ProtocolManager owner or selector-authorized operators can register and activate/deactivate vault singleton addresses. Keyed by vault address to prevent duplicate registrations.

---

## Enums

### VaultType

```solidity
enum VaultType { Custom, Burn, LP, Creator, Gift, Dividend }
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
| `register(vault, name, description, vaultType)` | — | Register new vault (implementation is `restricted`) |
| `setActive(vault, active)` | — | Activate/deactivate vault (implementation is `restricted`) |
| `isActive(vault)` | `bool` | Whether vault is registered and active |
| `getVaultInfo(vault)` | `VaultInfo` | Full vault info |
| `isRegistered(vault)` | `bool` | Whether vault is registered (regardless of active status) |
| `getVaultType(vault)` | `VaultType` | Get the VaultType of a registered vault |

---

## Events

| Event | Parameters |
|-------|------------|
| `Register` | `address indexed vault, string name, address creator, VaultType vaultType` |
| `Deactivate` | `address indexed vault, bool active` |

## Errors

| Error | Description |
|-------|-------------|
| `InvalidImplementation()` | Zero address vault |
| `InvalidMetadata()` | Empty name |
| `AlreadyRegistered()` | Duplicate registration |
| `VaultNotFound()` | Unregistered vault queried |
