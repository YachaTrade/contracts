# IVaultRegistry

**Path:** `src/interfaces/IVaultRegistry.sol`
**Type:** Interface

authority-restricted Vault 레지스트리 인터페이스. ProtocolManager owner 또는 selector-authorized operator가 Vault를 등록/활성화/비활성화할 수 있다. Vault 주소를 키로 사용하여 중복 등록을 방지한다.

---

## 열거형

### VaultType

```solidity
enum VaultType { Custom, Burn, LP, Creator, Gift, Dividend }
```

---

## 구조체

### VaultInfo

```solidity
struct VaultInfo {
    string name;        // Vault 이름 (예: "BurnVault")
    string description; // Vault 동작 설명
    address creator;    // 등록자 주소
    bool active;        // 활성 상태 — false이면 새 토큰 생성에 사용 불가
    VaultType vaultType; // Vault 유형
}
```

---

## 함수 시그니처

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `register(vault, name, description, vaultType)` | — | 새 Vault 등록 (implementation은 `restricted`) |
| `setActive(vault, active)` | — | Vault 활성/비활성 전환 (implementation은 `restricted`) |
| `isActive(vault)` | `bool` | 등록되어 있고 활성 상태인지 확인 |
| `getVaultInfo(vault)` | `VaultInfo` | 전체 Vault 정보 조회 |
| `isRegistered(vault)` | `bool` | 등록 여부 (활성/비활성 무관) |
| `getVaultType(vault)` | `VaultType` | Vault의 유형 조회 |

---

## 이벤트

| 이벤트 | 매개변수 |
|--------|----------|
| `Register` | `address indexed vault, string name, address creator, VaultType vaultType` |
| `Deactivate` | `address indexed vault, bool active` |

## 에러

| 에러 | 설명 |
|------|------|
| `InvalidImplementation()` | zero address vault |
| `InvalidMetadata()` | 이름이 비어있음 |
| `AlreadyRegistered()` | 중복 등록 |
| `VaultNotFound()` | 미등록 vault 조회 |
