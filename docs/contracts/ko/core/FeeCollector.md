# FeeCollector

**Path:** `src/core/FeeCollector.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IFeeCollector`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

중앙 수수료 관리 컨트랙트. 거래 수수료를 수집하고, 활성 프로토콜 수수료 몫은 즉시 feeReceiver로 보내며, 크리에이터 수수료만 페어별로 누적한 뒤 CreatorFeeProcessor로 정산한다.

---

## 구조체

`IFeeCollector.FeeConfig`를 저장과 반환 타입 모두에서 그대로 재사용한다. 별도의 내부 전용 구조체(`FeeConfigInternal`)는 제거되었다.

| 구조체 | 필드 | 설명 |
|--------|------|------|
| `FeeConfig` | `baseToken (address)`, `quoteToken (address)`, `creatorFeeRate (uint16)`, `curveProtocolFeeRate (uint16)`, `dexProtocolFeeRate (uint16)` | 페어별 수수료 설정 — 저장 + 외부 반환 공용 |

---

## 상태 변수

| 변수 | 타입 | 설명 |
|------|------|------|
| `_creatorFeeProcessor` | `ICreatorFeeProcessorV2` | CreatorFeeProcessor settlement용 로컬 최소 인터페이스 |
| `_bondingCurve` | `address` | setup() 호출 권한 (BondingCurve만) |
| `_configs` | `mapping(address => FeeConfig)` | 페어별 수수료 설정 (통합된 `IFeeCollector.FeeConfig` 사용) |
| `_accumulatedFees` | `mapping(address => uint256)` | 페어별 누적 크리에이터 수수료 |
| `_trackedBalance` | `mapping(address => uint256)` | quoteToken별 추적 잔액 (balance delta 계산용) |
| `_settling` | `mapping(address => bool)` | 페어별 정산 중 플래그 (settle 중 재귀 fee 수집 방지) |

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `initialize(protocolManager, creatorFeeProcessor, bondingCurve, router)` | initializer | authority, core 주소, GiwaRouter settlement 견적 배선 |
| `setup(pair, baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)` | external | 페어별 수수료 설정 등록 (BondingCurve만 호출 가능) |
| `getFeeConfig(pair)` | view | 페어의 수수료 설정 전체 조회 |
| `collectFee(pair, protocolFee, creatorFee)` | external | caller와 수신 balance delta를 검증하고 protocol fee + 초과분은 feeReceiver로, creator fee는 누적으로 처리 |
| `settle(pair, minAmountOut)` | restricted | threshold와 GiwaRouter settlement 최소 견적을 검증한 뒤 누적 creator fee 정산 |
| `accumulatedFee(pair)` | view | 페어의 현재 누적 크리에이터 수수료 |
| `settlementThreshold(pair)` | view | pair quoteToken의 정산 임계값 (ProtocolManager에서 조회) |
| `isSettleable(pair)` | view | 정산 가능 여부 |
| `isSettling(pair)` | view | 페어가 정산 중인지 여부 |
| `setCurveProtocolFeeRate(pair, rate)` | restricted | 페어의 커브 프로토콜 수수료율 변경 |
| `setDexProtocolFeeRate(pair, rate)` | restricted | 페어의 DEX 프로토콜 수수료율 변경 |

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
| `InvalidRates()` | creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate가 모두 0 |
| `NotAuthorized()` | pair 또는 bondingCurve가 아닌 호출자 |
| `PairLocked()` | pair가 lock-guarded 작업 중 |

---

## 핵심 흐름

### 수수료 수집 (collectFee)

```
NadFunPair._collectFee() → quoteToken을 FeeCollector로 전송
  → FeeCollector.collectFee(pair, protocolFee, creatorFee)
     ├─ auth: msg.sender == pair || msg.sender == bondingCurve
     ├─ feeReceived = currentBalance - _trackedBalance[quoteToken]
     ├─ feeReceived >= protocolFee + creatorFee 검증
     ├─ protocolFee + 초과 수신분 → 현재 feeReceiver
     ├─ 명시된 creatorFee → _accumulatedFees에 누적
     └─ _trackedBalance[quoteToken] 갱신
```

### 정산 (settle)

```
FeeCollector.settle(pair, minAmountOut)  [authorized settler only, restricted]
  ├─ accumulatedFees < threshold → return (no-op)
  └─ accumulatedFees >= threshold
     ├─ _settling[pair] = true, non-zero minAmountOut이면 GiwaRouter 견적 검증
     ├─ _accumulatedFees[pair] = 0 및 tracked balance 감소 (CEI 패턴)
     ├─ CreatorFeeProcessor.processCreatorFee(baseToken, quoteToken, amount)
     └─ _settling[pair] = false
```

졸업 여부와 무관하게 본딩 phase에서도 정산 가능. `_settling` 플래그는 FeeCollector가 직접 관리하며, settle 중 vault가 BondingCurve.buy() 또는 NadFunPair.swap()을 호출할 때 재귀적 fee 수집을 방지한다. BondingCurve의 `_calculateFees`와 `_getTotalFeeRate`도 settling 상태를 확인하여 0 fee를 반환한다.
