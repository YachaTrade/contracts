# VaultRegistry

**Path:** `src/vault/VaultRegistry.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IVaultRegistry`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

Authority-restricted vault registry. The ProtocolManager owner or selector-authorized operators can register vault singleton addresses with a designated VaultType and activate/deactivate entries. Keyed by vault address (no duplicate registrations).

---

## State Variables

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_vaults` | `mapping(address => VaultInfo)` | private | Vault address to VaultInfo mapping |
| `_registered` | `mapping(address => bool)` | private | Fast existence check for vault addresses |

### VaultInfo (Struct)

```solidity
struct VaultInfo {
    string name;
    string description;
    address creator;
    bool active;
    VaultType vaultType;
}
```

### VaultType (Enum)

```solidity
enum VaultType { Custom, Burn, LP, Creator, Gift, Dividend }
```

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager)` | external, initializer | Set authority |
| `register(vault, name, description, vaultType)` | restricted | Register a new vault address with its type |
| `setActive(vault, active)` | restricted | Activate or deactivate a vault |
| `isActive(vault)` | view | Check if vault is registered and active |
| `getVaultInfo(vault)` | view | Get full VaultInfo struct |
| `isRegistered(vault)` | view | Check if vault is registered (regardless of active status) |
| `getVaultType(vault)` | view | Get the VaultType of a registered vault |

---

## Key Logic: Registration

```
Authorized caller -> VaultRegistry.register(vault, name, description, vaultType)
  |-- require(vault != address(0))        // InvalidImplementation
  |-- require(name is not empty)           // InvalidMetadata
  |-- require(!_registered[vault])         // AlreadyRegistered
  |-- _registered[vault] = true
  |-- store VaultInfo { name, description, creator=msg.sender, active=true, vaultType }
  +-- emit Register(vault, name, msg.sender, vaultType)
```

### Activation / Deactivation

```
Authorized caller -> VaultRegistry.setActive(vault, false)
  |-- require(_registered[vault])  // VaultNotFound
  |-- _vaults[vault].active = false
  +-- emit Deactivate(vault, false)
```

---

## Errors

| Error | Description |
|-------|-------------|
| `InvalidImplementation()` | Zero address vault |
| `InvalidMetadata()` | Empty name |
| `AlreadyRegistered()` | Vault already registered |
| `VaultNotFound()` | Vault not registered |

## Events

| Event | Parameters |
|-------|------------|
| `Register` | `address indexed vault, string name, address creator, VaultType vaultType` |
| `Deactivate` | `address indexed vault, bool active` |
