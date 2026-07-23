# ProtocolManager

**경로:** `src/core/ProtocolManager.sol`
**패턴:** UUPS proxy
**상속:** `IProtocolManager`, `OwnableUpgradeable`

ProtocolManager는 프로토콜 전역 설정이자 AccessManaged authority다.

## QuoteConfig

지원 quote token마다 독립 설정을 가진다.

| 필드 | 용도 |
| --- | --- |
| `decimals` | 등록 시 기록한 quote-token decimals |
| `virtualReserve` | 초기 virtual quote reserve |
| `virtualTokenReserve` | 초기 virtual launch-token reserve |
| `minTokenReserve` | 졸업 threshold |
| `deployFee` | 고정 생성 수수료 |
| `graduateFee` | 고정 졸업 수수료 |
| `curveProtocolFeeRate` | Curve 거래 protocol fee BPS |
| `dexProtocolFeeRate` | YachaRouter V3 protocol fee BPS |
| `v3FeeTier` | Canonical Uniswap V3 pool fee tier |
| `lpFeeProtocolShareBps` | 수집된 V3 LP fee 중 protocol share |
| `active` | 신규 launch에서 해당 quote 사용 가능 여부 |

`addV3QuoteToken()`과 `updateV3QuoteToken()`은 lifecycle과 V3 설정을 원자적으로 저장한다. `setV3QuoteConfig()`는 V3 tier와 LP split만 변경한다. Quote 제거는 과거 metadata를 삭제하지 않고 inactive로 표시한다.

## 전역 설정

- `feeReceiver`: protocol fee와 미사용 졸업 asset의 현재 수신자
- `snipingPenaltyTable`: block별 buy penalty BPS
- operator permission: 정확한 `(operator, target, selector)` grant

## Authority 동작

`canCall(caller, target, selector)`는 다음 중 하나면 즉시 허용한다.

1. `caller`가 현재 ProtocolManager owner인 경우
2. 정확한 operator permission이 활성화된 경우

Target 전체 또는 wildcard 권한은 추론하지 않는다.

## 관리 함수

| 함수 | 권한 | 용도 |
| --- | --- | --- |
| `setFeeReceiver(receiver)` | owner | Protocol 수신자 변경 |
| `addV3QuoteToken(...)` | owner | 완전한 quote 설정 추가 |
| `updateV3QuoteToken(...)` | owner | Active quote 전체 설정 원자적 변경 |
| `setV3QuoteConfig(quote, tier, share)` | owner | V3 tier와 LP split만 변경 |
| `removeQuoteToken(quote)` | owner | Quote 비활성화 |
| `setSnipingPenaltyTable(table)` | owner | 전체 penalty schedule 교체 |
| `setOperatorPermission(operator, target, selector, allowed)` | owner | 정확한 call edge 하나 grant/revoke |
| `upgradeToAndCall(implementation, data)` | owner | UUPS upgrade |

Fee rate에는 contract cap이 있고 LP share는 10,000 BPS를 넘을 수 없다. V3 fee tier는 nonzero여야 하며 quote 설정은 virtual reserve와 graduation supply도 검증한다.

## 사용처

- BondingCurve는 curve 설정, fee, receiver, anti-sniping penalty를 조회한다.
- YachaRouter는 졸업 후 protocol fee rate와 receiver를 조회한다.
- LPManager는 V3 fee tier, LP split, receiver를 조회한다.
- 모든 AccessManaged module은 ProtocolManager를 authority로 사용한다.
- CreatorFeeProcessor는 `setup()`과 `processCreatorFee()`에서 `canCall()`을 직접 확인한다.
