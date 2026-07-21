# ICreatorFeeProcessor

**Path:** `src/interfaces/ICreatorFeeProcessor.sol`
**Type:** Interface

업그레이드 불가능한 CreatorFeeProcessor 싱글톤의 공개 인터페이스. FeeCollector에서 이미 quote token으로 계산된 크리에이터 수수료를 pull한 뒤 토큰별 vault 설정에 따라 분배한다.

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
| `setup(token, vaults)` | — | 토큰별 vault 배분을 등록. BondingCurve만 호출할 수 있고 토큰당 한 번만 가능 |
| `processCreatorFee(token, quoteToken, amount)` | — | FeeCollector에서 `quoteToken`의 `amount`를 pull하고 BPS로 나눠 전송한 뒤 각 vault의 `afterDeposit` 호출 |
| `vaultCount(token)` | `uint256` | 해당 토큰의 vault 슬롯 수 |
| `getVaults(token)` | `VaultSlot[]` | 해당 토큰에 설정된 모든 vault 슬롯 |

분배는 원자적이다. 전송이나 vault 콜백이 실패하면 전체 트랜잭션이 되돌아간다. CreatorFeeProcessor 자체는 토큰 스왑을 수행하지 않는다.

---

## Events

| Event | Parameters |
|-------|------------|
| `Setup` | `address indexed token, VaultSlot[] vaults` |
| `Distribute` | `address indexed token, address indexed vault, uint256 amount` |
| `CallbackFail` | `address indexed vault, uint256 amount, bytes reason` |

`CallbackFail`은 인터페이스 ABI에 남아 있지만, 현재 구현은 vault를 직접 호출하므로 이 이벤트를 발행하지 않는다.

## Errors

| Error | Description |
|-------|-------------|
| `InvalidBpsTotal()` | vault BPS 합계 != 10000 |
| `ZeroAddress()` | 필수 주소가 zero |
| `NotAuthorized()` | `setup` 호출자가 BondingCurve가 아니거나 `processCreatorFee` 호출자가 FeeCollector가 아님 |
| `TooManyVaults()` | vault가 5개 초과 |
| `NoVaults()` | vault가 0개 |
| `ZeroBps()` | vault의 BPS가 0 |
| `AlreadyConfigured()` | 토큰에 vault 설정이 이미 존재함 |
