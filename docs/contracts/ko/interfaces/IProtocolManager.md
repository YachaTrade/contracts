# IProtocolManager

**Path:** `src/interfaces/IProtocolManager.sol`
**Type:** Interface

프로토콜 전역 설정 관리 인터페이스. 전역 수수료, 크리에이터 수수료 설정, 안티스나이핑 매개변수, quote 토큰 화이트리스트, AccessManaged 모듈용 operator 권한을 중앙에서 관리한다.

---

## 구조체

### QuoteConfig

```solidity
struct QuoteConfig {
    uint8 decimals;              // 토큰 소수점 (6=USDT, 18=WMON)
    uint256 virtualReserve;      // 초기 가상 quote 리저브
    uint256 virtualTokenReserve; // 초기 가상 토큰 리저브
    uint256 minTokenReserve;     // 졸업 임계값 (최소 virtualTokenReserve)
    uint256 deployFee;           // 토큰 배포 수수료 (quote 토큰 단위)
    uint256 graduateFee;         // 졸업 수수료 (quote 토큰 단위)
    uint16 curveProtocolFeeRate; // 본딩커브 프로토콜 수수료 (BPS, quote 토큰별)
    uint16 dexProtocolFeeRate;   // DEX 프로토콜 수수료 (BPS, quote 토큰별)
    uint256 settlementThreshold;  // quote 토큰별 크리에이터 수수료 정산 임계값
    uint24 v3FeeTier;             // canonical Uniswap V3 fee tier
    uint16 lpFeeProtocolShareBps; // 수집 V3 LP fee의 protocol share
    bool active;                 // 이 quote로 토큰 생성 허용 여부
}
```

---

## 함수 시그니처

### 수수료 조회

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `feeReceiver()` | `address` | 프로토콜 수수료 수신자 |
| `curveProtocolFeeRate(quoteToken)` | `uint16` | 본딩커브 거래 수수료 (BPS, quote 토큰별) |
| `dexProtocolFeeRate(quoteToken)` | `uint16` | DEX 프로토콜 수수료 (BPS, quote 토큰별) |
| `deployFee(quoteToken)` | `uint256` | 토큰 배포 수수료 (quote 토큰별) |
| `graduateFee(quoteToken)` | `uint256` | 졸업 수수료 (quote 토큰별) |
| `v3FeeTier(quoteToken)` | `uint24` | quote 토큰별 canonical V3 fee tier |
| `lpFeeProtocolShareBps(quoteToken)` | `uint16` | 수집 V3 LP fee의 protocol share |

### 수수료 설정 (관리자 전용)

| 함수 | 설명 |
|------|------|
| `setFeeReceiver(address)` | 수수료 수신자 설정 |
### 크리에이터 수수료 설정

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `isCreatorFeeRateAllowed(rate)` | `bool` | 크리에이터 수수료율이 허용 목록에 있는지 확인 |
| `settlementThreshold(quoteToken)` | `uint256` | quote 토큰별 크리에이터 수수료 정산 임계값 |
| `setAllowedCreatorFeeRates(rates)` | — | 기존 목록을 교체하지 않고 허용 크리에이터 수수료율을 누적 추가 |
| `removeCreatorFeeRate(rate)` | — | 허용 목록에서 크리에이터 수수료율 하나를 제거 |
| `setSettlementThreshold(quoteToken, threshold)` | — | quote 토큰별 정산 임계값 설정 |
| `setV3QuoteConfig(quoteToken, v3FeeTier, lpFeeProtocolShareBps)` | — | canonical V3 fee tier와 LP-fee protocol share 설정 |

### operator 권한 관리

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `setOperatorPermission(operator, target, selector, allowed)` | — | AccessManaged 대상에 selector 단위 operator 권한 부여/회수 |
| `isOperatorAllowed(operator, target, selector)` | `bool` | selector 단위 operator 권한 조회 |

### Factory 관리

| 함수 | 설명 |
|------|------|
| `setFactoryFeeTo(factory, feeTo)` | 유지 중인 NadFunFactory fee receiver 설정 |
| `setFactoryImplementation(factory, implementation)` | 유지 중인 NadFunPair implementation 설정 |

### 안티스나이핑 설정

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `snipingPenaltyTable()` | `uint256[]` | 블록 단위 패널티 테이블 (BPS) 전체 반환 |
| `snipingPenaltyAt(uint256 blocksElapsed)` | `uint256` | 인덱스에 해당하는 패널티 (BPS). 길이 밖 → 0 |
| `snipingPenaltyTableLength()` | `uint256` | 테이블 길이 (= 스나이핑 윈도우 블록 수) |
| `getSnipingPenalty(uint256 createdAtBlock)` | `uint256` | 현재 적용 패널티. `block.number - createdAtBlock` 인덱스 |
| `setSnipingPenaltyTable(uint256[] calldata table)` | — | 테이블 교체. 각 entry ≤ 10000 BPS. 빈 배열 → 비활성화 |

### Quote 토큰 관리

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `addQuoteToken(token, virtualReserve, virtualTokenReserve, minTokenReserve, deployFee, graduateFee, curveProtocolFeeRate, dexProtocolFeeRate, settlementThreshold)` | — | 새 quote 토큰 등록 |
| `removeQuoteToken(token)` | — | quote 토큰 비활성화 |
| `updateQuoteToken(token, virtualReserve, virtualTokenReserve, minTokenReserve, deployFee, graduateFee, curveProtocolFeeRate, dexProtocolFeeRate, settlementThreshold)` | — | quote 토큰 설정 업데이트 |
| `isAllowed(token)` | `bool` | quote 토큰 활성 여부 |
| `getConfig(token)` | `QuoteConfig` | quote 토큰 전체 설정 |
| `getVirtualReserve(token)` | `uint256` | 가상 quote 리저브 |
| `getVirtualTokenReserve(token)` | `uint256` | 가상 토큰 리저브 |
| `getMinTokenReserve(token)` | `uint256` | 졸업 임계값 |
| `getDecimals(token)` | `uint8` | 토큰 소수점 |

---

## 이벤트

| 이벤트 | 설명 |
|--------|------|
| `FeeReceiverUpdate(address)` | 수수료 수신자 변경 |
| `CreatorFeeRatesUpdate(uint16[])` | 크리에이터 수수료율 화이트리스트 변경 |
| `SettlementThresholdUpdate(address, uint256)` | quote 토큰별 정산 임계값 변경 |
| `V3QuoteConfigUpdate(address, uint24, uint16)` | quote 토큰 V3 fee tier / LP-fee share 변경 |
| `SnipingPenaltyTableUpdate(uint256[] penaltyTable)` | 블록 단위 스나이핑 패널티 테이블 교체 |
| `QuoteTokenAdd(address, uint256, uint256, uint256, uint256, uint256, uint16, uint16, uint256)` | 새 quote 토큰 등록 |
| `QuoteTokenRemove(address)` | quote 토큰 비활성화 |
| `QuoteTokenUpdate(address, uint256, uint256, uint256, uint256, uint256, uint16, uint16, uint256)` | quote 토큰 설정 업데이트 |
| `OperatorPermissionUpdated(address, address, bytes4, bool)` | selector 단위 operator 권한 변경 |

## 에러

| 에러 | 설명 |
|------|------|
| `QuoteTokenNotAllowed()` | 미등록 quote 토큰 사용 |
| `QuoteTokenAlreadyAdded()` | 중복 quote 토큰 등록 |
| `InvalidFeeTier()` | 유효하지 않은 V3 fee tier |
| `InvalidLpFeeShare()` | V3 LP-fee protocol share가 BPS 초과 |
| `ZeroAddress()` | zero address 전달 |
