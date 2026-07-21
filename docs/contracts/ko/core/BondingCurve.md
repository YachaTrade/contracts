# BondingCurve

> `src/core/BondingCurve.sol` — UUPS 업그레이드 가능

토큰 전체 수명주기를 관리하는 핵심 상태 컨트랙트: 생성, 본딩 커브 거래, 졸업(DEX 마이그레이션), 안티스나이핑.

## 개요

BondingCurve는 기존 Router + TokenFactory의 기능을 하나의 컨트랙트로 통합합니다. EIP-1167 미니멀 프록시 클론(Token -- fee-on-transfer 없는 일반 ERC20)을 배포하고, 싱글톤 CreatorFeeProcessor(MODULE_CREATOR_FEE_PROCESSOR로 조회)와 연동하며, 본딩 커브 상태를 관리하고, DEX 졸업을 오케스트레이션합니다.

**v1 대비 주요 변경사항:**
- **ERC20 거래**: 모든 본딩 커브 거래가 ERC20 견적 토큰을 사용합니다. BondingCurve는 잔액 감지(balance-detection) 패턴을 사용하며, 호출자는 buy/sell 호출 전에 토큰을 미리 전송해야 합니다. 코어 함수는 명시적 금액 파라미터 없이 잔액 변화량(balance delta)에서 입금액을 감지합니다.
- **ProtocolManager**: 기존 CurveRegistry + FeeManager + AdminModule을 대체합니다. 각 토큰의 본딩 커브 매개변수(virtualReserve, minTokenReserve)는 ProtocolManager의 견적 토큰별 설정에서 가져옵니다.
- **다중 견적 토큰**: 서로 다른 토큰이 서로 다른 견적 토큰(WMON, USDT 등)을 사용할 수 있습니다.
- **가상 리저브 AMM**: reserve + circulatingSupply 대신 virtualQuoteReserve + virtualTokenReserve를 사용합니다.

## 토큰 생성 흐름

**접근 제어:** `create()`는 `ROUTER_ROLE` 필요 — NadFunRouter만 호출 가능. 사용자는 `NadFunRouter.create()` 또는 `NadFunRouter.createWithNative()`를 통해 토큰을 생성한다.

```
NadFunRouter → BondingCurve.create(params)  [ROUTER_ROLE 필요]
  ├─ Balance detection: totalIn = 잔액 - _totalQuoteReserved
  ├─ 파라미터 검증 (quoteToken 허용목록, creatorFeeRate)
  ├─ deployFee(quoteToken)를 safeTransfer로 feeReceiver에 전송
  ├─ Clone: Token (일반 ERC20) → 싱글톤 Vault 설정
  │   → NadFunFactory.createPair(token, quoteToken)
  │   → TokenRegistry.register(token, pair, quoteToken, dexType)
  │   → FeeCollector.setup(pair, token, quoteToken, creatorFeeRate, curveProtocolFee, dexProtocolFee)
  │   → 싱글톤 CreatorFeeProcessor.setup(token, vaults)
  │   → Token.initialize(name, symbol, tokenURI, bondingCurve, pair) (10억 개를 BondingCurve에 민팅)
  ├─ Curve 저장 (virtualQuoteReserve, virtualTokenReserve)
  └─ 잔여 quote 감지 시: _initialBuy (sniping 면제, 프로토콜 수수료만)
```

`create()`는 통합 함수 — deployFee 징수 후 잔여 quote가 감지되면 (balance detection) sniping 면제 초기 매수를 자동 실행한다. 첫 매수는 원자적이므로 슬리피지 보호 불필요.

**`CreateTokenParams.creator` 필드:** NadFunRouter가 `msg.sender`(실제 사용자)를 creator로 전달.

## 매수/매도 (Transfer-then-Check 패턴)

**매수:**
```
Router → quoteToken을 BondingCurve로 전송
Router → BondingCurve.buy(to, token)
  ├─ 잔액 감지: quoteAmount = quoteToken.balanceOf(this) - 이전 잔액
  ├─ settling 체크: FeeCollector.isSettling(pair) → true이면 fee 0 반환 (vault 바이백 시 재귀 방지)
  ├─ 프로토콜 수수료: protocolFeeAmount = quoteAmount * protocolFee / 10000
  ├─ 안티스나이핑 페널티를 (quoteAmount - protocolFee)에 적용
  ├─ BondingCurveLibrary.getAmountOut(effectiveQuoteIn, k, virtualQuoteReserve, virtualTokenReserve)
  ├─ virtualQuoteReserve += effectiveQuoteIn, virtualTokenReserve -= tokensOut 업데이트
  ├─ 구매 상한 확인: tokensOut > availableTokens (virtualTokenReserve - minTokenReserve)이면:
  │     ├─ tokensOut = availableTokens으로 클램핑
  │     ├─ requiredQuote = getAmountIn(availableTokens, k, reserves)
  │     └─ excessQuote = effectiveQuoteIn - requiredQuote → 수수료에 합산
  ├─ protocolFee + snipingFee + excessQuote → feeReceiver로 전송
  ├─ tokensOut → to로 전송
  └─ virtualTokenReserve == minTokenReserve이면 → _graduate()
```

동일한 구매 상한 로직이 `_initialBuy` (토큰 생성 시 초기 매수)에도 적용됨. 단, 스나이핑 페널티는 미적용. 초과 effective quote는 프로토콜 수수료에 합산되어 feeReceiver에게 전송.

**매도:**
```
Router → token을 BondingCurve로 전송
Router → BondingCurve.sell(to, token)
  ├─ 잔액 감지: tokenAmount = token.balanceOf(this) - virtualTokenReserve
  ├─ BondingCurveLibrary.getAmountOut(tokenAmount, k, virtualTokenReserve, virtualQuoteReserve)
  ├─ virtualTokenReserve += tokenAmount, virtualQuoteReserve -= grossQuoteOut 업데이트
  ├─ 프로토콜 수수료: protocolFeeAmount = grossQuoteOut * protocolFee / 10000
  ├─ protocolFee → feeReceiver로 전송
  └─ quoteOut → to로 전송
```

## 졸업 (Graduation)

`virtualTokenReserve == minTokenReserve`일 때 자동으로 트리거됩니다:

1. `curve.graduated = true`
2. `Token.setIsGraduated()` — 단순 boolean 플래그 설정 (상태 머신 없음)
3. 견적 잔액에서 `graduateFee(quoteToken)` 차감
4. DEX 상장가를 본딩 커브 가격에 맞추기 위한 `graduatingTokenAmount` 계산
5. 남는 토큰(초과분)을 `feeReceiver`에게 전송
6. `graduatingTokenAmount` + `quoteBalance`를 LPManager로 전송
7. `LPManager.addLiquidity()` — DexAdapter를 통해 DEX에 유동성 추가

## 안티스나이핑

```
elapsed       = block.number - curve.createdAtBlock
penaltyTable  = ProtocolManager.snipingPenaltyTable()  // BPS 배열, 인덱스 = elapsed

penaltyBps    = elapsed < penaltyTable.length ? penaltyTable[elapsed] : 0
penaltyQuote  = quoteAmount * penaltyBps / 10000
effectiveQuoteIn = quoteAmount - protocolFee - penaltyQuote - creatorFee
penaltyQuote → feeReceiver (견적 토큰으로)
```

블록 번호 기반 룩업 테이블 — `block.timestamp` 대신 `block.number`를 사용해 검증자의 타임스탬프 미세 조작에 면역. 기본 곡선 (블록 인덱스 → BPS): `[8000, 4000, 2000, 1500, 1000, 1000, 500]`, 블록 7부터 0%. ProtocolManager의 `setSnipingPenaltyTable(uint256[])`로 컨트랙트 업그레이드 없이 곡선 자체를 갱신할 수 있다. 같은 블록 내 매수도 인덱스 0(최대 페널티)으로 처리. 페널티는 토큰 출력이 아닌 견적 입력에 적용된다.

## Curve 구조체

```solidity
struct Curve {
    address token;                  // Token 클론 (일반 ERC20)
    address creator;                // 토큰 생성자
    address quoteToken;             // 견적 토큰 (예: WMON, USDT)
    uint256 virtualQuoteReserve;    // AMM 견적 리저브 (가상 + 실제)
    uint256 virtualTokenReserve;    // AMM 토큰 리저브 (가상 + 실제)
    uint64 createdAtBlock;          // 생성 블록 번호 (안티스나이핑 인덱스 기준)
    bool graduated;                 // DEX 마이그레이션 완료 여부
    CurveVersion version;           // 생성 시점의 컨트랙트 버전
    ITokenRegistry.DexType dexType; // V2 또는 V3
    address pair;                   // DEX 페어 주소
}
```

Curve 구조체 필드 (별도 매핑이 아닌 구조체 필드):
- `curve.k` — 상수곱 k = virtualQuoteReserve_init * virtualTokenReserve_init
- `curve.initialTokenReserve` — 초기 virtualTokenReserve (졸업 체크 및 실제 quote 잔액 계산용)
- `curve.minTokenReserve` — 졸업 임계값 (최소 virtualTokenReserve)
- `curve.initialQuoteReserve` — 초기 virtualQuoteReserve

## 버전 관리 전략

BondingCurve는 `CurveVersion` enum과 `VERSION` 상수를 통해 커브 버전을 관리하며, 하위 호환이 보장되는 UUPS 업그레이드를 지원합니다.

**동작 원리:**

- **CurveVersion enum**: `V1`(constant product AMM: `x * y = k`)부터 시작합니다. 새 버전은 enum 끝에 추가합니다.
- **생성 시 버전 기록**: 토큰 생성 시 `curve.version = VERSION`으로 현재 컨트랙트 버전을 영구 기록합니다.
- **UUPS 업그레이드**: 새 구현체에서 `VERSION = V2`로 변경하면, 업그레이드 이후 생성되는 토큰만 V2 버전이 됩니다. 기존 V1 토큰은 `curve.version == V1`을 유지합니다.
- **버전별 분기**: `buy()`, `sell()`, `_graduate()`에서 `curve.version`을 기반으로 각 버전에 맞는 로직을 실행합니다.
- **V2 AMM 도입 시**: `CurveV2` struct와 `curvesV2` 매핑을 추가하여 기존 V1 데이터와 스토리지 슬롯 충돌 없이 새 AMM 구조를 관리합니다.
- **V1 커브 불변성**: V1 커브의 AMM 구조(reserve, k값)는 변경 불가합니다. 생애주기 전체에 걸쳐 V1 로직으로 동작합니다.

```
// 업그레이드 후 분기 예시:
if (curve.version == CurveVersion.V1) _buyV1(...)
else if (curve.version == CurveVersion.V2) _buyV2(...)
```

## 관리자 함수

| 함수 | 접근 권한 | 설명 |
|------|-----------|------|
| `setModule(moduleId, module)` | DEFAULT_ADMIN_ROLE | 모듈 등록/업데이트 |
| `halt(halted)` | GUARDIAN_ROLE | 긴급 일시정지 |
| `_authorizeUpgrade` | DEFAULT_ADMIN_ROLE | UUPS 업그레이드 |

## 모듈 레지스트리

| 모듈 ID | 상수 | 용도 |
|---------|------|------|
| `keccak256("LP_MANAGER")` | `MODULE_LP_MANAGER` | 유동성 관리 |
| `keccak256("TOKEN_REGISTRY")` | `MODULE_TOKEN_REGISTRY` | 토큰 메타데이터 + DEX 어댑터 레지스트리 |
| `keccak256("VAULT_REGISTRY")` | `MODULE_VAULT_REGISTRY` | Vault 구현체 레지스트리 |
| `keccak256("CREATOR_FEE_PROCESSOR")` | `MODULE_CREATOR_FEE_PROCESSOR` | 싱글톤 CreatorFeeProcessor 주소 |
| `keccak256("FEE_COLLECTOR")` | `MODULE_FEE_COLLECTOR` | 수수료 수집 및 정산 |
| `keccak256("FACTORY")` | `MODULE_FACTORY` | DEX 페어 생성용 NadFunFactory |

## 조회 함수

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `getCurve(token)` | `Curve memory` | 전체 커브 상태 |
| `getQuoteToken(token)` | `address` | 토큰의 견적 토큰 |
| `isHalted()` | `bool` | 프로토콜 일시정지 상태 |
| `getAmountOut(token, amountIn, isBuy)` | `uint256` | 주어진 입력에 대한 출력량 |
| `getAmountIn(token, amountOut, isBuy)` | `uint256` | 원하는 출력에 필요한 입력량 |
| `getSnipingPenalty(token)` | `uint256 penaltyBps` | 현재 안티스나이핑 페널티 |
