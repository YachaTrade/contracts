# CreatorFeeProcessor

**Path:** `src/core/CreatorFeeProcessor.sol`
**Pattern:** 싱글톤
**Inheritance:** `ICreatorFeeProcessor`

싱글톤 크리에이터 수수료 분배 파이프라인 (V2). FeeCollector에서 이미 quoteToken으로 정산된 수수료를 받아 등록된 Vault들에 BPS 비율로 분배.

모든 토큰이 하나의 싱글톤 인스턴스를 공유. 공통 상태(bondingCurve, feeCollector)는 constructor immutable로 초기화.
토큰별 vault 설정은 `mapping(token => VaultSlot[])`으로 저장되며 `setup(token, vaults)` 호출로 등록.

**V1 대비 변경사항:**
- baseToken -> quoteToken 스왑 로직 제거 (FeeCollector가 이미 quoteToken 보유)
- ITokenRegistry, IDexAdapter, IProtocolManager 의존성 제거
- protocolFeeAmount 처리 제거 (FeeCollector가 프로토콜 수수료 분리 담당)
- feeCollector immutable 추가 (processCreatorFee 호출 권한 제어)

**Pull 패턴:** FeeCollector가 `approve()` 후 `processCreatorFee()` 호출 -> CreatorFeeProcessor가 `transferFrom`으로 정확한 금액만 pull. CreatorFeeProcessor에 잔액 축적 없음 (cross-token contamination 방지).

**배포 순서:** BondingCurve 먼저 배포 -> CreatorFeeProcessor(constructor에 BC + FeeCollector 주소) -> setModule(MODULE_CREATOR_FEE_PROCESSOR, processor).

---

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BPS` | `10_000` | Basis points 기준 |
| `MAX_VAULTS` | `5` | 최대 vault 슬롯 수 |

---

## State Variables

### Immutable (constructor로 설정)

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `bondingCurve` | `address` | public immutable | BondingCurve 주소 (setup 호출 권한) |
| `feeCollector` | `address` | public immutable | FeeCollector 주소 (processCreatorFee 호출 권한) |

### 토큰별 스토리지

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_vaults` | `mapping(address => VaultSlot[])` | private | 토큰별 vault 주소 + BPS 쌍 |

### VaultSlot (구조체)

```solidity
struct VaultSlot {
    address vault;   // 싱글톤 vault 주소
    uint16 bps;      // basis points 배분
}
```

> `sum(vaults[i].bps) == 10000` (setup 시 검증)
>
> 각 vault 슬롯은 `bps > 0`이고 `vault != address(0)`이어야 함.

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `constructor(bondingCurve, feeCollector)` | -- | immutable 공통 상태 설정 |
| `setup(token, vaults)` | external (onlyBondingCurve) | 토큰별 vault 설정 등록 + BPS 합계 검증 |
| `processCreatorFee(token, quoteToken, amount)` | external (onlyFeeCollector) | FeeCollector에서 quoteToken pull 후 vault들에 BPS 분배 |
| `vaultCount(token)` | view | 해당 토큰의 vault 슬롯 수 |
| `getVaults(token)` | view | 해당 토큰의 전체 vault 슬롯 |

---

## Key Logic: processCreatorFee 흐름

```
FeeCollector.settle(pair, minAmountOut)
  -> approve(creatorFeeProcessor, amount)
  -> CreatorFeeProcessor.processCreatorFee(token, quoteToken, amount)

1. Pull: transferFrom(feeCollector, this, amount) <- pull 패턴

2. quoteToken을 BPS 기준으로 vault들에 분배 (mapping[token]에서 조회)
   각 vault[i]에 대해:
     |- amount = creatorFeeQuote * vault[i].bps / BPS (마지막은 나머지)
     |- safeTransfer(vault[i].vault, amount)
     +- vault[i].afterDeposit(token, quoteToken, amount)
```

각 vault가 자체 로직(소각, LP, 배당, 직접 전송 등)을 처리한다. callback은 직접 호출되므로 vault 하나가 실패하면 전체 분배와 caller의 settlement 트랜잭션이 revert한다.

### Pull 패턴

FeeCollector가 `approve(creatorFeeProcessor, amount)` 호출 후 `processCreatorFee()` 호출. CreatorFeeProcessor가 `transferFrom`으로 정확한 금액만 pull. 싱글톤에 잔액이 축적되지 않아 cross-token contamination 방지.

---

## Events

| Event | Parameters |
|-------|------------|
| `Setup` | `address indexed token, VaultSlot[] vaults` |
| `Distribute` | `address indexed token, address indexed vault, uint256 amount` |
| `CallbackFail` | `address indexed vault, uint256 amount, bytes reason` |

## Errors

| Error | Description |
|-------|-------------|
| `InvalidBpsTotal()` | vault BPS 합계 != 10000 |
| `ZeroAddress()` | 필수 주소가 zero |
| `NotAuthorized()` | 호출자가 bondingCurve(setup) 또는 feeCollector(processCreatorFee)가 아님 |
| `TooManyVaults()` | vault가 5개 초과 |
| `NoVaults()` | vault가 0개 |
| `ZeroBps()` | vault의 BPS가 0 |
| `AlreadyConfigured()` | 이 토큰에 이미 vault가 설정됨 |
