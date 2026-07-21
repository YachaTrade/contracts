# IFeeCollector

**Path:** `src/interfaces/IFeeCollector.sol`
**Type:** Interface

FeeCollector 인터페이스. DEX 거래 수수료의 수집, 정산, 관리 함수를 정의.

---

## 구조체

| 구조체 | 필드 | 설명 |
|--------|------|------|
| `FeeConfig` | `baseToken (address)`, `quoteToken (address)`, `creatorFeeRate (uint16)`, `curveProtocolFeeRate (uint16)`, `dexProtocolFeeRate (uint16)` | 페어별 수수료 설정 (BPS). FeeCollector 저장소와 `getFeeConfig()` 반환 타입 모두에서 사용되는 단일 구조체. |

---

## 함수 시그니처

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `setup(pair, baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)` | — | 페어별 수수료 설정 등록 (BondingCurve 호출) |
| `getFeeConfig(pair)` | `FeeConfig` | 페어의 수수료 설정 전체 조회. Pair는 `address(this)`로 호출하고 caller에 맞는 feeRate를 로컬에서 계산. |
| `collectFee(pair)` | — | 수수료 수집 — balance delta 방식 (호출 전 quoteToken 전송 필요, msg.sender는 pair 또는 bondingCurve) |
| `settle(pair)` | — | 누적 크리에이터 수수료 정산 (authorized settler only, restricted). 본딩 phase에서도 동작 |
| `accumulatedFee(pair)` | `uint256` | 페어의 누적 크리에이터 수수료 |
| `settlementThreshold(pair)` | `uint256` | pair quoteToken의 정산 임계값 |
| `isSettleable(pair)` | `bool` | 정산 가능 여부 |
| `isSettling(pair)` | `bool` | 페어가 정산 중인지 여부 |
| `setCurveProtocolFeeRate(pair, rate)` | — | 커브 프로토콜 수수료율 변경 (admin) |
| `setDexProtocolFeeRate(pair, rate)` | — | DEX 프로토콜 수수료율 변경 (admin) |

---

## 이벤트

| 이벤트 | 설명 |
|--------|------|
| `Setup(token, pair, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)` | 수수료 설정 등록 시 |
| `Collect(token, pair, amount)` | 수수료 수집 시 |
| `Settle(token, pair, totalFee, creatorFee)` | 정산 실행 시 |

---

## 에러

| 에러 | 설명 |
|------|------|
| `AlreadyConfigured()` | 이미 설정된 페어 |
| `NotConfigured()` | 미설정 페어 |
| `ZeroAddress()` | zero address 입력 |
| `InvalidRates()` | 수수료율 모두 0 |
| `NotAuthorized()` | 권한 없는 호출자 |
| `PairLocked()` | pair가 lock-guarded 작업 중 |
