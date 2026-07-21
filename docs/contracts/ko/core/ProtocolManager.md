# ProtocolManager

> `src/core/ProtocolManager.sol` — UUPS Proxy, OwnableUpgradeable

프로토콜 설정을 통합 관리하는 단일 컨트랙트. 전역 수수료, 크리에이터 수수료 설정, 기축 토큰 레지스트리, 그리고 AccessManaged 모듈용 operator 권한 정책을 한 곳에서 관리한다.

## 역할

| 영역 | 관리 항목 |
|------|----------|
| **수수료** | curveProtocolFeeRate, dexProtocolFeeRate, feeReceiver, giftSigner |
| **Quote별 수수료** | deployFee, graduateFee (quote 토큰별, QuoteConfig에 저장) |
| **크리에이터 수수료 설정** | allowedCreatorFeeRates (1%/3%/5%), settlementThreshold |
| **기축 토큰** | 토큰별 설정: virtualReserve, virtualTokenReserve, minTokenReserve, decimals |
| **Authority 정책** | target + selector 단위 operator 권한 |

## 상태

```
수수료:
  _giftSigner           address    (Legacy) 구 EIP-712 claim 플로우용 백엔드 signer. 현재 GiftVault는 이 값을 사용하지 않음 (claim은 AccessManaged `restricted`로 변경). 하위호환을 위해 남아있으며 추후 제거 예정
  _feeReceiver          address    수수료 수취인
  (deployFee와 graduateFee는 이제 quote 토큰별로 관리 — QuoteConfig 참조)

크리에이터 수수료 설정:
  _allowedCreatorFeeRates      mapping(uint16 => bool)   허용 크리에이터 수수료율 목록 (예: 100/300/500)
  settlementThreshold는 QuoteConfig 안에 quote 토큰별로 저장

스나이핑 설정:
  _snipingPenaltyTable  uint256[]  블록 단위 페널티 테이블 (BPS).
                                   index = block.number - createdAtBlock. 길이를 벗어나면 페널티 0.

기축 토큰 레지스트리:
  _configs              mapping(address => QuoteConfig)  기축 토큰별 본딩커브 파라미터

operator 권한:
  _operatorPermissions  mapping(target => operator => selector => bool)
```

## QuoteConfig 구조체

```solidity
struct QuoteConfig {
    uint8 decimals;              // ERC20 소수점 (자동 감지)
    uint256 virtualReserve;      // 본딩커브 초기 가상 quote 리저브
    uint256 virtualTokenReserve; // 본딩커브 초기 가상 token 리저브
    uint256 minTokenReserve;     // 졸업 임계값 (virtualTokenReserve가 이 값에 도달 시 졸업)
    uint256 deployFee;           // 토큰 배포 수수료 (quote 토큰 단위)
    uint256 graduateFee;         // 졸업 수수료 (quote 토큰 단위)
    uint16 curveProtocolFeeRate; // 본딩커브 프로토콜 수수료율 (BPS)
    uint16 dexProtocolFeeRate;   // DEX 프로토콜 수수료율 (BPS)
    uint256 settlementThreshold;  // 정산 트리거 최소 크리에이터 수수료
    bool active;                 // 이 기축 토큰의 활성 여부
}
```

## 함수

### 수수료 관리

| 함수 | 권한 | 설명 |
|------|------|------|
| `feeReceiver()` | view | 수수료 수취인 주소 반환 |
| `curveProtocolFeeRate(address)` | view | 특정 quote 토큰의 본딩커브 프로토콜 수수료율 (BPS) |
| `dexProtocolFeeRate(address)` | view | 특정 quote 토큰의 DEX 프로토콜 수수료율 (BPS) |
| `deployFee(address quoteToken)` | view | 특정 quote 토큰의 배포 수수료 |
| `graduateFee(address quoteToken)` | view | 특정 quote 토큰의 졸업 수수료 |
| `giftSigner()` | view | (Legacy) 구 EIP-712 claim 플로우용 signer. 현재 GiftVault는 참조하지 않음. 추후 제거 예정 |
| `setGiftSigner(address)` | onlyOwner | (Legacy) 현재 GiftVault claim 권한과 무관 |
| `setFeeReceiver(address)` | onlyOwner | 수수료 수취인 설정 |
### 크리에이터 수수료 설정

| 함수 | 권한 | 설명 |
|------|------|------|
| `isCreatorFeeRateAllowed(uint16)` | view | 크리에이터 수수료율이 허용 목록에 있는지 확인 |
| `settlementThreshold(address quoteToken)` | view | quote 토큰별 정산 최소 축적량 |
| `setAllowedCreatorFeeRates(uint16[])` | onlyOwner | 허용 크리에이터 수수료율 추가 (누적) |
| `removeCreatorFeeRate(uint16)` | onlyOwner | 허용 크리에이터 수수료율 제거 |
| `setSettlementThreshold(address quoteToken, uint256 threshold)` | onlyOwner | quote 토큰별 정산 임계값 설정 |

### 스나이핑 페널티 설정

| 함수 | 권한 | 설명 |
|------|------|------|
| `snipingPenaltyTable()` | view | 블록 단위 페널티 테이블 전체 (BPS 배열) 반환 |
| `snipingPenaltyAt(uint256 blocksElapsed)` | view | 특정 인덱스의 페널티 (BPS). 길이 밖이면 0 |
| `snipingPenaltyTableLength()` | view | 테이블 길이 (= 스나이핑 윈도우 블록 수) |
| `getSnipingPenalty(uint256 createdAtBlock)` | view | 현재 적용 페널티 (BPS). `block.number - createdAtBlock`을 인덱스로 사용 |
| `setSnipingPenaltyTable(uint256[] calldata)` | onlyOwner | 테이블 교체. 각 entry ≤ 10000 BPS. 빈 배열은 스나이핑 비활성화 |

### 팩토리 관리

| 함수 | 권한 | 설명 |
|------|------|------|
| `setFactoryFeeTo(address factory, address feeTo)` | onlyOwner | NadFunFactory의 프로토콜 수수료 수령 주소 설정 |
| `setFactoryImplementation(address factory, address implementation)` | onlyOwner | NadFunFactory의 NadFunPair 구현체 주소 설정 |

### operator 권한 관리

| 함수 | 권한 | 설명 |
|------|------|------|
| `setOperatorPermission(operator, target, selector, allowed)` | onlyOwner | AccessManaged 대상 컨트랙트에 대해 selector 단위 operator 권한 부여/회수 |
| `isOperatorAllowed(operator, target, selector)` | view | operator 권한 설정 여부 조회 |

### 기축 토큰 관리

| 함수 | 권한 | 설명 |
|------|------|------|
| `addQuoteToken(address, uint256, uint256, uint256, uint256, uint256, uint16, uint16, uint256)` | onlyOwner | 기축 토큰 등록 (가상 리저브 + 수수료 + curve/dex protocol fee rate + settlementThreshold) |
| `removeQuoteToken(address)` | onlyOwner | 기축 토큰 비활성화 |
| `updateQuoteToken(address, uint256, uint256, uint256, uint256, uint256, uint16, uint16, uint256)` | onlyOwner | 활성 기축 토큰 설정 업데이트 (curve/dex protocol fee rate + settlementThreshold 포함) |
| `isAllowed(address)` | view | 기축 토큰 활성 여부 확인 |
| `getConfig(address)` | view | 전체 QuoteConfig 반환 |
| `getVirtualReserve(address)` | view | 가상 quote 리저브 조회 |
| `getVirtualTokenReserve(address)` | view | 가상 token 리저브 조회 |
| `getMinTokenReserve(address)` | view | 졸업 임계값 조회 |
| `getDecimals(address)` | view | 토큰 소수점 조회 |

## 초기화 기본값

```
allowedCreatorFeeRates: 100 (1%), 300 (3%), 500 (5%)
settlementThreshold: quote 토큰별 설정
snipingPenaltyTable (BPS, index = block.number - createdAtBlock):
  block 0: 8000 (80%)
  block 1: 4000 (40%)
  block 2: 2000 (20%)
  block 3: 1500 (15%)
  block 4: 1000 (10%)
  block 5: 1000 (10%)
  block 6:  500  (5%)
  block 7+:  0  (테이블 길이 밖)
quote별 수수료율: quote token 설정 시 함께 지정
```

## ProtocolManager를 참조하는 컨트랙트

| 컨트랙트 | 사용 항목 |
|----------|----------|
| `BondingCurve` | 모든 수수료, 크리에이터 수수료율 검증, 기축 토큰 설정, feeReceiver |
| `TokenRegistry` | `setOperatorPermission()` / `canCall()` 기반 authority 정책 |
| `LPManager` | `setOperatorPermission()` / `canCall()` 기반 authority 정책 |
| `NadFunRouter` | `feeReceiver()` |
| `FeeCollector` | AccessManaged authority, feeReceiver 조회, quote 토큰별 settlementThreshold 조회 |
| `GiftVault` | `AccessManaged` authority (admin이 신뢰된 오프체인 relayer에게 `setReceiver(token, receiver)` selector의 operator 권한을 부여) |
| `NadFunFactory` | `setFactoryFeeTo()`, `setFactoryImplementation()` — ProtocolManager를 통한 팩토리 관리 |

## 에러

| 에러 | 발생 조건 |
|------|----------|
| `ZeroAddress()` | address(0)으로 기축 토큰 추가 시 |
| `QuoteTokenAlreadyAdded()` | 이미 활성인 기축 토큰 재추가 시 |

## 이벤트

수수료: `FeeReceiverUpdate`, `GiftSignerUpdate`

크리에이터 수수료: `CreatorFeeRatesUpdate`, `SettlementThresholdUpdate`

스나이핑: `SnipingPenaltyTableUpdate(uint256[] penaltyTable)`

기축 토큰: `QuoteTokenAdd`, `QuoteTokenRemove`, `QuoteTokenUpdate`

Authority: `OperatorPermissionUpdated`
