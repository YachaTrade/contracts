# ICreatorFeeProcessor

**Path:** `src/interfaces/ICreatorFeeProcessor.sol`
**Type:** Interface

CreatorFeeProcessor 싱글톤의 공개 인터페이스. Pull 패턴 기반 스왑-분배 파이프라인 정의.

---

## Structs

### VaultSlot

```solidity
struct VaultSlot {
    address vault;   // 싱글톤 vault 주소
    uint16 bps;      // basis points 배분
}
```

> `sum(vaults[i].bps) == 10000` 필수. 각 vault는 `bps > 0`이고 `vault != address(0)`이어야 함.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `setup(token, vaults)` | — | 토큰별 vault 설정 등록 (onlyAuthorized) |
| `processCreatorFee(token, creatorFeeAmount, protocolFeeAmount)` | — | 크리에이터 수수료 처리: pull → 전량 스왑 → 수수료 → vaults[] |
| `quoteToken()` | `address` | 스왑 대상 토큰 (immutable) |
| `vaultCount(token)` | `uint256` | 해당 토큰의 vault 슬롯 수 |
| `getVault(token, index)` | `(address, uint16)` | 해당 토큰의 인덱스별 vault 주소 및 BPS |

---

## Events

| Event | Parameters |
|-------|------------|
| `CreatorFeeProcessed` | `uint256 creatorFeeAmount, uint256 protocolFeeAmount, uint256 quoteReceived` |
| `VaultDistributed` | `address indexed vault, uint256 amount` |
| `VaultCallbackFailed` | `address indexed vault, uint256 amount, bytes reason` |

## Errors

| Error | Description |
|-------|-------------|
| `InvalidBpsTotal()` | vault BPS 합계 != 10000 |
| `ZeroAddress()` | 필수 주소가 zero |
| `NotAuthorized()` | 호출자가 token이 아님 |
| `TooManyVaults()` | vault가 5개 초과 |
| `NoVaults()` | vault가 0개 |
| `ZeroBps()` | vault의 BPS가 0 |
