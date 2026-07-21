# VaultRegistry

**Path:** `src/vault/VaultRegistry.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IVaultRegistry`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

관리자 전용 vault 레지스트리. 현재 authority가 허용한 restricted 호출자만 vault를 등록/비활성화할 수 있다. vault 주소를 키로 사용하여 중복 등록을 방지하고, VaultType으로 유형을 관리한다.

---

## State Variables

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_vaults` | `mapping(address => VaultInfo)` | private | vault 주소 -> VaultInfo 매핑 |
| `_registered` | `mapping(address => bool)` | private | vault 주소 -> 등록 여부 (빠른 존재 확인) |

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
enum VaultType { Custom, Burn, LP, Creator, Gift }
```

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager)` | external, initializer | authority 설정 |
| `register(vault, name, description, vaultType)` | restricted | 새 vault 등록 |
| `setActive(vault, active)` | restricted | vault 활성화/비활성화 |
| `isActive(vault)` | view | 등록되어 있고 활성 상태인지 확인 |
| `getVaultInfo(vault)` | view | 전체 VaultInfo 구조체 조회 |
| `isRegistered(vault)` | view | 등록 여부 확인 (활성/비활성 무관) |
| `getVaultType(vault)` | view | vault의 VaultType 조회 |

---

## Key Logic: 등록

```
관리자 -> VaultRegistry.register(vault, name, description, vaultType)
  ├─ require(msg.sender == owner)           // onlyOwner
  ├─ require(vault != address(0))           // InvalidImplementation
  ├─ require(name이 비어있지 않음)            // InvalidMetadata
  ├─ require(!_registered[vault])           // AlreadyRegistered
  ├─ _registered[vault] = true
  ├─ VaultInfo { name, description, creator=msg.sender, active=true, vaultType } 저장
  └─ emit VaultRegistered(vault, name, msg.sender, vaultType)
```

### 비활성화 (관리자)

```
관리자 -> VaultRegistry.setActive(vault, false)
  ├─ require(_registered[vault])  // VaultNotFound
  ├─ _vaults[vault].active = false
  └─ emit VaultDeactivated(vault, false)
```

---

## Errors

| Error | Description |
|-------|-------------|
| `InvalidImplementation()` | zero address vault |
| `InvalidMetadata()` | 빈 이름 |
| `AlreadyRegistered()` | 이미 등록된 vault 주소 |
| `VaultNotFound()` | 등록되지 않은 vault 주소 |

## Events

| Event | Parameters |
|-------|------------|
| `VaultRegistered` | `address indexed vault, string name, address creator, VaultType vaultType` |
| `VaultDeactivated` | `address indexed vault, bool active` |
