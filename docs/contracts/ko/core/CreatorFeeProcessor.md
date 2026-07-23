# CreatorFeeProcessor

**경로:** `src/core/CreatorFeeProcessor.sol`
**패턴:** Immutable singleton
**권한:** `ProtocolManager.canCall()`

CreatorFeeProcessor는 이미 quote token으로 통일된 creator share를 권한 있는 호출자에게서 pull하고 launch token에 설정된 vault slot로 분배한다.

## 상태

- `protocolManager`: immutable authority
- `_vaults[token]`: 최대 5개의 `(vault, bps)` slot

## 함수

| 함수 | 권한 | 동작 |
| --- | --- | --- |
| `setup(token, vaults)` | ProtocolManager의 정확한 selector permission | Token별 1회 설정, 1~5개 slot, nonzero 항목, 총 10,000 BPS 검증 |
| `processCreatorFee(token, quoteToken, amount)` | ProtocolManager의 정확한 selector permission | 정확한 quote를 pull하고 BPS 분배 후 각 vault의 `afterDeposit` 호출 |
| `vaultCount(token)` | Public view | 설정된 slot 수 |
| `getVaults(token)` | Public view | 전체 slot 목록 |

기본 배포에서는 BondingCurve가 `setup()`, LPManager가 `processCreatorFee()` 권한을 가진다.

## 분배 흐름

```text
LPManager
  ├─ creator quote만큼 approve
  └─ CreatorFeeProcessor.processCreatorFee
       ├─ 정확한 quote amount transferFrom
       ├─ 각 vault에 BPS share 전송
       ├─ vault.afterDeposit(token, quoteToken, amount)
       └─ Processor 종료 balance == 진입 balance 확인
```

마지막 slot이 나눗셈 rounding remainder를 받는다. 모든 pull/push는 sender와 receiver balance delta를 확인하며, transfer 또는 vault callback 실패 시 전체 분배가 revert된다.
