# NadFun v2 — Architecture Documentation

## Overview

NadFun은 Monad에서 동작하는 본딩커브 토큰 런치패드 프로토콜이다.
토큰 생성 → 본딩커브 거래 → DEX 졸업 → 수수료 징수 → 수익 분배의 전체 생명주기를 관리한다.

**핵심 특징 (v2):**
- 순수 ERC20 Token (fee-on-transfer 제거, EIP-1167 Minimal Proxy로 배포)
- 자체 Custom DEX (NadFunFactory/NadFunPair) — Uniswap V2 fork, pair-level fee
- FeeCollector — 중앙 수수료 관리 (fee config + 누적 + threshold settlement)
- UUPS 업그레이드 패턴 (BondingCurve, ProtocolManager, TokenRegistry, LPManager, VaultRegistry, FeeCollector)
- Anti-Sniping: ProtocolManager의 `snipingPenaltyTable`(블록 단위 BPS 배열)로 설정 (기본: `[8000, 4000, 2000, 1500, 1000, 1000, 500]` BPS, 블록 7+ → 0)
- 플러그인 가능한 싱글톤 Vault 시스템 (VaultRegistry — 관리자 전용 등록, VaultType 기반)
- Migration Attack 방지: 토큰 생성 시 NadFunPair를 즉시 생성하여 선점 공격 차단

---

## Contract Map

```
┌─────────────────────────────────────────────────────────────────┐
│                         CORE LAYER                              │
│  ┌────────────────┐  ┌──────────────────────┐  ┌───────────────┐│
│  │  BondingCurve   │  │ NadFunRouter          │  │ProtocolManager││
│  │  (UUPS Proxy)   │  │ (UUPS Proxy)          │  │ (UUPS)        ││
│  │  상태+로직+클론  │  │ BC + DEX 통합 라우터   │  │수수료+creatorFee+   ││
│  │                 │  │                       │  │기축토큰 통합   ││
│  └────┬───────────┘  └───────────────────────┘  └───────────────┘│
│       │                                                          │
├───────┼──────────────────────────────────────────────────────────┤
│       │              TOKEN LAYER                                 │
│  ┌────▼─────┐  ┌──────────────┐                                │
│  │  Token    │  │CreatorFeeProcessor  │                                │
│  │(순수ERC20)│  │(vault 분배)  │                                │
│  └──────────┘  └──────────────┘                                │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                      DEX LAYER                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │NadFunFactory  │  │ NadFunPair   │  │ FeeCollector │          │
│  │(pair 생성)    │  │(swap+fee)    │  │(fee 관리)    │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                      VAULT LAYER                                 │
│  ┌──────────────┐  ┌──────────┐ ┌────────┐ ┌──────────┐        │
│  │VaultRegistry  │  │BurnVault │ │LPVault │ │CreatorFeeVault  │        │
│  │  (UUPS)       │  │(바이백   │ │(LP추가 │ │(직접     │        │
│  │  템플릿 등록   │  │ 소각)    │ │ +소각) │ │ 전송)    │        │
│  └──────────────┘  └──────────┘ └────────┘ └──────────┘        │
│         ▲ IVault interface (setup + afterDeposit)                │
└──────────────────────────────────────────────────────────────────┘
```

---

## Contracts

### Core Layer

#### BondingCurve (UUPS Proxy)
> `src/core/BondingCurve.sol`

프로토콜의 핵심 상태 컨트랙트. 토큰 생성, 본딩커브 거래, 졸업, Anti-Sniping을 관리한다.
v2에서는 Token(순수 ERC20) 클론 배포, NadFunFactory를 통한 pair 생성, FeeCollector를 통한 creator fee 전송을 처리한다.

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(admin, tokenImpl_, protocolManager_)` | initializer | 프록시 초기화 |
| `create(params)` | public payable, notHalted, nonReentrant | Token 클론 + NadFunFactory.createPair() + FeeCollector.setup() + CreatorFeeProcessor.setup() + Vault 설정 + Curve 등록 |
| `buy(to, token)` | public, notHalted, nonReentrant | 본딩커브 매수 (balance-detection) + 프로토콜 수수료 + Anti-Sniping + creator fee → FeeCollector |
| `sell(to, token)` | public, notHalted, nonReentrant | 본딩커브 매도 (balance-detection) + 프로토콜 수수료 + creator fee → FeeCollector |
| `setModule(moduleId, module)` | DEFAULT_ADMIN_ROLE | 모듈 등록/업데이트 |
| `halt(halted)` | GUARDIAN_ROLE | 프로토콜 긴급 정지 |
| `getCurve(token)` | view | 토큰별 커브 상태 조회 (Curve 구조체) |
| `getQuoteToken(token)` | view | 토큰의 기축 토큰 주소 조회 |
| `isHalted()` | view | 프로토콜 정지 상태 조회 |
| `getAmountOut(token, amountIn, isBuy)` | view | 주어진 입력에 대한 출력 수량 (creator fee 포함) |
| `getAmountIn(token, amountOut, isBuy)` | view | 원하는 출력에 필요한 입력 수량 (creator fee 포함) |
| `getSnipingPenalty(token)` | view | 현재 Anti-Sniping 패널티 (BPS) |

**핵심 상태:**
- `curves[address]` → Curve (virtualQuoteReserve, virtualTokenReserve, graduated, pair, creatorFeeRate 등)
- `curve.k` → constant product k (virtualQuoteReserve * virtualTokenReserve, 커브 생성 시 결정)
- `curve.minTokenReserve` → 졸업 임계값 (최소 virtualTokenReserve)
- `curve.creatorFeeRate` → 크리에이터 수수료율 (FeeCollector에도 등록, curve-phase creator fee 계산에 사용)
- `_modules[bytes32]` → 모듈 주소 레지스트리

**모듈 레지스트리:**
| Module ID | 상수 | 용도 |
|-----------|------|------|
| `keccak256("TOKEN_REGISTRY")` | `MODULE_TOKEN_REGISTRY` | 토큰 메타데이터 등록 |
| `keccak256("LP_MANAGER")` | `MODULE_LP_MANAGER` | 유동성 추가 + LP 영구 잠금 |
| `keccak256("VAULT_REGISTRY")` | `MODULE_VAULT_REGISTRY` | Vault 구현체 레지스트리 |
| `keccak256("CREATOR_FEE_PROCESSOR")` | `MODULE_CREATOR_FEE_PROCESSOR` | 싱글톤 CreatorFeeProcessor 주소 |
| `keccak256("FEE_COLLECTOR")` | `MODULE_FEE_COLLECTOR` | 중앙 수수료 관리 |
| `keccak256("FACTORY")` | `MODULE_FACTORY` | NadFunFactory 주소 |

**버전 관리 전략 (CurveVersion):**

BondingCurve는 `CurveVersion` enum을 통해 커브 버전을 관리한다. 토큰 생성 시 `curve.version`에 현재 `VERSION` 상수값이 기록되며, 이 값은 이후 변경되지 않는다.

- **CurveVersion enum**: `V1`(constant product AMM)부터 시작. 새 버전은 enum 끝에 추가한다.
- **토큰 생성 시 버전 기록**: `_initCurve()`에서 `curve.version = VERSION`으로 현재 버전을 영구 기록한다.
- **기존 토큰 하위 호환**: 기존 V1 토큰은 `curve.version == V1`이므로, buy/sell/graduate에서 V1 로직으로 계속 동작한다.

**Anti-Sniping (ProtocolManager 설정 가능):**
```
elapsedBlocks = block.number - curve.createdAtBlock
table         = ProtocolManager.snipingPenaltyTable()  // BPS 배열, 인덱스 = elapsedBlocks
penaltyBps    = elapsedBlocks < table.length ? table[elapsedBlocks] : 0
penaltyQuote  = quoteAmount * penaltyBps / 10000
effectiveQuoteIn = quoteAmount - protocolFee - penaltyQuote - creatorFee

virtualQuoteReserve += effectiveQuoteIn
virtualTokenReserve -= tokensOut
penaltyQuote → feeReceiver (quote 토큰으로)

// 기본 곡선 (BPS): [8000, 4000, 2000, 1500, 1000, 1000, 500], 블록 7+ → 0
```

**클론/설정 순서 (v2):**
1. Token 클론 배포 (EIP-1167, 순수 ERC20)
2. NadFunFactory.createPair(token, quoteToken) → pair 주소
3. TokenRegistry.register(token, pair, quoteToken, dexType)
4. FeeCollector.setup(pair, token, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)
5. 싱글톤 Vault 설정 (VaultRegistry에서 등록된 싱글톤 vault 주소 조회 → vault.setup(token, data) 호출)
6. 싱글톤 CreatorFeeProcessor.setup(token, VaultSlot[]) — MODULE_CREATOR_FEE_PROCESSOR로 주소 조회
7. Token.initialize(name, symbol, uri, bondingCurve, pair) — 1B 토큰 mint → BondingCurve
8. Curve 상태 초기화 (virtualReserve, k값, minTokenReserve, creatorFeeRate 등)

**CREATE2 Salt 파생:**
```
tokenSalt     = keccak256(salt, "token")
```

---

#### NadFunRouter (UUPS Proxy)
> `src/router/NadFunRouter.sol`

본딩커브 + DEX 거래를 통합 처리하는 라우터. 졸업 전에는 `BondingCurve.buy/sell()`을 직접 호출하고, 졸업 후에는 `ITokenRegistry`를 통해 `IDexAdapter`로 DEX 스왑을 라우팅한다.

---

#### NadFunRouter02 (UUPS Proxy)
> `src/router/NadFunRouter02.sol`

졸업한 NadFunPair를 위한 독립형 UniswapV2Router02 호환 페리퍼리. `NadFunRouter`와 기능을 통합할 경우 EIP-170 24KB 컨트랙트 크기 제한을 초과하기 때문에 별도 컨트랙트로 분리되었다. `NadFunRouter`는 변경 없이 유지된다.

**스왑 수수료 인식:** `getAmountsOut`/`getAmountsIn`은 홉별로 `NadFunPair.getAmountOut`/`getAmountIn`에 위임한다. 이는 NadFunPair의 k 불변식 검사가 LP 수수료(0.25%) 외에 프로토콜 수수료 + 크리에이터 수수료(매수/매도 비대칭)도 반영하기 때문이다. 3-파라미터 `getAmountOut`/`getAmountIn` 순수 뷰는 LP 수수료만 적용하며, 종단간 라우팅 견적에는 적합하지 않다.

**독립 배포:** 기존 컨트랙트 업그레이드 없이 신규 UUPS 프록시로 배포된다. 멀티시그나 기존 컨트랙트 변경 없이 누구나 배포 가능. `script/DeployRouter02.s.sol` 참조.

**Bonding Curve 거래 (졸업 전):**

| Function | Description |
|----------|-------------|
| `buy(BuyParams)` | ERC20 ExactIn 매수 + 슬리피지 검증 |
| `buyWithNative(BuyWithNativeParams)` payable | MON → WMON 래핑 후 ExactIn 매수 |
| `buyWithPermit(BuyWithPermitParams)` | permit 서명 후 ExactIn 매수 |
| `sell(SellParams)` | ERC20 ExactIn 매도 + 슬리피지 검증 |
| `sellToNative(SellToNativeParams)` | 매도 후 네이티브 통화로 언래핑 |
| `sellWithPermit(SellWithPermitParams)` | permit 서명 후 매도 |
| `exactOutBuy(ExactOutBuyParams)` | ERC20 ExactOut 매수 + 잔액 환불 |
| `exactOutBuyWithNative(ExactOutBuyWithNativeParams)` payable | MON ExactOut 매수 + 잔액 환불 |
| `exactOutSell(ExactOutSellParams)` | ExactOut 매도 (creator fee 역산 포함) |
| `getAmountOut(token, amountIn, isBuy)` view | 모든 수수료(프로토콜+스나이핑+크리에이터 수수료) 포함 출력 수량 |
| `getAmountIn(token, amountOut, isBuy)` view | 모든 수수료 포함 필요 입력 수량 |

**DEX 거래 (졸업 후):**

| Function | Description |
|----------|-------------|
| `dexBuy(DexBuyParams)` | 졸업 후 DEX 매수 (IDexAdapter 경유) |
| `dexBuyWithNative(DexBuyWithNativeParams)` payable | MON → WMON 래핑 후 DEX 매수 |
| `dexSell(DexSellParams)` | 졸업 후 DEX 매도 (IDexAdapter 경유) |
| `dexSellToNative(DexSellToNativeParams)` | DEX 매도 후 네이티브 통화로 언래핑 |

---

#### ProtocolManager (UUPS Proxy)
> `src/core/ProtocolManager.sol`

프로토콜 전역 설정을 통합 관리하는 단일 컨트랙트. 수수료 설정, 크리에이터 수수료 허용 목록, 기축 토큰 관리, 스나이핑 페널티 등을 담당한다.

**수수료 관리:**

| Function | Access | Description |
|----------|--------|-------------|
| `feeReceiver()` | view | 프로토콜 수수료 수취인 |
| `curveProtocolFeeRate(quoteToken)` | view | 본딩커브 프로토콜 수수료 (BPS) |
| `deployFee()` | view | 토큰 배포 수수료 |
| `graduateFee()` | view | 졸업 수수료 |
| `setFeeReceiver(receiver)` | onlyOwner | 수수료 수취인 변경 |

**크리에이터 수수료 설정:**

| Function | Access | Description |
|----------|--------|-------------|
| `isCreatorFeeRateAllowed(rate)` | view | 크리에이터 수수료 비율 허용 여부 |
| `setAllowedCreatorFeeRates(rates)` | onlyOwner | 크리에이터 수수료 비율 허용 목록 설정 |
| `removeCreatorFeeRate(rate)` | onlyOwner | 크리에이터 수수료 비율 제거 |
| `snipingPenaltyTable()` | view | 블록 단위 안티스나이핑 페널티 배열 (BPS) |
| `snipingPenaltyAt(uint256)` | view | 특정 elapsed-block 인덱스의 페널티 (BPS) |
| `snipingPenaltyTableLength()` | view | 페널티 테이블 길이 (= 윈도우 블록 수) |
| `setSnipingPenaltyTable(uint256[])` | onlyOwner | 페널티 테이블 교체 (각 entry ≤ 10000 BPS, 빈 배열 → 비활성화) |

**기축 토큰 관리:**

| Function | Access | Description |
|----------|--------|-------------|
| `addQuoteToken(token, virtualReserve, virtualTokenReserve, minTokenReserve, deployFee, graduateFee)` | onlyOwner | 새 기축 토큰 등록 |
| `removeQuoteToken(token)` | onlyOwner | 기축 토큰 비활성화 |
| `updateQuoteToken(token, ...)` | onlyOwner | 기축 토큰 파라미터 업데이트 |
| `isAllowed(token)` | view | 기축 토큰 허용 여부 |
| `getConfig(token)` | view | QuoteConfig 구조체 조회 |

---

### Token Layer

#### Token (순수 ERC20 + Burnable + Permit)
> `src/token/Token.sol`

ERC20Upgradeable 기반 순수 토큰. fee-on-transfer 없음. EIP-1167 Minimal Proxy로 토큰마다 하나 배포.

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(name, symbol, uri, pair)` | initializer | 토큰 초기화, 1B 민팅 |
| `burn(amount)` | public | 토큰 소각 |
| `setIsGraduated()` | owner only | 졸업 상태로 전환 |
| `isGraduated()` | view | 졸업 여부 조회 |

**Pair 전송 가드:**
`Token.initialize()`에서 pair 주소를 받으며, 졸업 전에는 pair 주소로의 토큰 전송이 차단된다 (`TransferToPairBeforeGraduation` 에러). 이는 본딩 단계에서 직접 토큰 전송으로 인한 pair 리저브 오염을 방지한다.

**v1 대비 변경사항:**
- 4단계 상태 머신 제거 (BondingCurve → Migrating → TaxActive → TaxFree)
- `_update()` 훅에서 creator fee/fee 징수 로직 제거
- settlement 로직 제거 (`_trySettleCreatorFee`, `_accumulatedCreatorFee` 등)
- 졸업 여부만 추적 (`isGraduated`)
- pair 전송 가드 추가 (졸업 전 pair 주소로의 전송 차단)

---

#### CreatorFeeProcessor (싱글톤 — vault 분배)
> `src/core/CreatorFeeProcessor.sol`

FeeCollector에서 quoteToken을 받아 싱글톤 vault들에 BPS 기준으로 분배한다.
v2에서는 swap 로직이 제거됨 — quoteToken을 직접 받아서 분배만 수행.

**`processCreatorFee(token, quoteToken, amount)` 파이프라인 (v2):**
```
FeeCollector.settle()
  └─ CreatorFeeProcessor.processCreatorFee(token, quoteToken, amount)
      └─ 각 vault[i]에 BPS 비율로 분배:
           ├─ transfer(vault[i], amount * bps / BPS)
           └─ try vault[i].afterDeposit(token, quoteToken, amount)
```

**BPS 제약:** `sum(vaults[i].bps) = 10,000` (최대 5개 vault)
**Vault callback:** `try/catch`로 감싸서 vault 실패 시 CreatorFeeProcessor가 중단되지 않음

---

### DEX Layer

#### NadFunFactory (Singleton)
> `src/dex/NadFunFactory.sol`

Uniswap V2 Factory fork. Permissionless pair 생성. CREATE2로 결정적 주소.

| Function | Access | Description |
|----------|--------|-------------|
| `createPair(tokenA, tokenB)` | public | NadFunPair 배포 (CREATE2) |
| `getPair(tokenA, tokenB)` | view | pair 주소 조회 (대칭) |
| `allPairs(index)` | view | 인덱스로 pair 조회 |
| `allPairsLength()` | view | 전체 pair 수 |

#### NadFunPair (Per-pair)
> `src/dex/NadFunPair.sol`

Uniswap V2 Pair fork + pair-level fee. `swap()` 시 `FeeCollector.getFeeConfig(address(this))`로 페어별 수수료 설정을 읽고, quoteToken 기준으로 creator fee + dex protocol fee를 차감한다.

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(factory, token0, token1, feeCollector)` | factory only | pair 초기화 |
| `mint(to)` | public | 유동성 추가, LP 토큰 민팅 |
| `burn(to)` | public | 유동성 제거, LP 토큰 소각 |
| `swap(amount0Out, amount1Out, to, data)` | public | 스왑 + fee 차감 → FeeCollector |
| `skim(to)` | public | 초과 잔액 회수 |
| `sync()` | public | 리저브 강제 갱신 |
**Fee 차감 로직 (swap 내부):**
```
1. FeeCollector.isSettling(pair) 중이면 fee 수집 스킵 (vault swap 시 재귀 방지)
2. FeeCollector.getFeeConfig(address(this)) 조회
3. activeFeeRate = creatorFeeRate + dexProtocolFeeRate
4. quote 기준 swap fee 계산 후 FeeCollector로 전송
5. FeeCollector.collectFee(pair) 호출 — balance delta 기반, amount 파라미터 없음
6. k invariant 검증 (LP_FEE_RATE = 25 bps = 0.25% 반영)
7. k invariant 검증 후 reserve update
```

**Note:** `_settling` 플래그는 NadFunPair에서 FeeCollector로 이동. `setSettling()` 함수 제거됨.

NadFun pair (FeeCollector에 config 있음): LP fee 0.25% + protocol fee + creator fee  
일반 pair (config 없음): LP fee 0.25%만

#### FeeCollector (UUPS Proxy)
> `src/core/FeeCollector.sol`

중앙 수수료 관리. 페어별 `FeeConfig`를 저장하고, quoteToken balance delta로 수수료를 수집한다. 프로토콜 수수료 몫은 즉시 `feeReceiver`로 보내고, 크리에이터 수수료만 누적 후 threshold에서 정산한다.

| Function | Access | Description |
|----------|--------|-------------|
| `setup(pair, baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)` | bondingCurve only | 페어별 fee config 등록 |
| `collectFee(pair)` | public | fee 수집 — msg.sender가 pair 또는 bondingCurve여야 함 |
| `settle(pair)` | restricted | threshold 도달 시 누적 creator fee 정산 |
| `getFeeConfig(pair)` | view | `FeeConfig { baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate }` 조회 |
| `accumulatedFee(pair)` | view | 누적 creator fee 조회 |
| `isSettleable(pair)` | view | 정산 가능 여부 |
| `settlementThreshold(pair)` | view | pair quoteToken의 정산 임계값 조회 |
| `setCurveProtocolFeeRate(pair, rate)` | restricted | 커브 protocol fee rate 변경 |
| `setDexProtocolFeeRate(pair, rate)` | restricted | DEX protocol fee rate 변경 |

**Settlement 로직:**

Settlement은 본딩 단계와 졸업 후 단계 모두에서 동작한다. `_settling` 플래그는 FeeCollector에 `mapping(address pair => bool)`로 저장되며, 정산 중 BondingCurve는 수수료 0을 반환하여 재귀적 수수료 누적을 방지한다.

```
settle(pair):
  creatorFee = accumulatedFee[pair]
  if creatorFee < threshold → return

  accumulatedFee[pair] = 0
  trackedBalance[quoteToken] -= creatorFee
  _settling[pair] = true
  CreatorFeeProcessor.processCreatorFee(baseToken, quoteToken, creatorFee)
  _settling[pair] = false
```

---

#### TokenRegistry (UUPS Proxy)
> `src/core/TokenRegistry.sol`

토큰 메타데이터(pair, quoteToken, dexType)를 관리한다. 등록 권한은 로컬 allowlist가 아니라 `ProtocolManager.canCall()` 기반 authority 정책으로 제어된다.

| Function | Access | Description |
|----------|--------|-------------|
| `register(token, pair, quoteToken, dexType)` | restricted | 토큰 메타데이터 등록 (1회만) |
| `getPair(token)` | view | 토큰의 페어 주소 조회 |
| `getQuoteToken(token)` | view | 토큰의 기축 토큰 조회 |
| `getDexType(token)` | view | 토큰의 DexType 조회 |
| `getTokenInfo(token)` | view | TokenInfo 구조체 전체 조회 |
| `isRegistered(token)` | view | 등록 여부 (pair != address(0)) |
| `setAdapter(dexType, adapter)` | restricted | DEX adapter 설정 |

---

#### LPManager (UUPS Proxy)
> `src/core/LPManager.sol`

LP 회계 레이어. DexAdapter를 통해 NadFunPair에 유동성을 추가하고, pair 주소는 TokenRegistry를 source of truth로 사용하며 호출자별 유동성 수량만 추적한다.

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager_, tokenRegistry_)` | initializer | 프록시 초기화 |
| `addLiquidity(token, quoteToken, tokenAmount, quoteAmount, dexType, pair)` | restricted | DexAdapter를 통한 유동성 추가 + 회계 추적 |
| `claimFees(token)` | external | LP fee claim (현재 V2 pair는 revert) |
| `getPair(token)` | view | TokenRegistry를 통해 토큰의 pair 주소 조회 |
| `getLiquidity(token, caller)` | view | 호출자의 LP 수량 조회 |

---

### Vault Layer

#### IVault (Vault 추상화)
> `src/interfaces/IVault.sol`

최소 vault 인터페이스. CreatorFeeProcessor가 quoteToken을 전송한 후 `afterDeposit()`을 호출.

| Function | Description |
|----------|-------------|
| `afterDeposit(token, quoteToken, amount)` | CreatorFeeProcessor가 quoteToken 전송 후 호출 |
| `setup(token, data)` | 토큰별 초기 설정 (싱글톤이므로 토큰 생성 시 호출) |

#### VaultRegistry (UUPS Proxy)
> `src/vault/VaultRegistry.sol`

관리자 전용 싱글톤 vault 레지스트리. VaultType(Custom, Burn, LP, Creator, Gift) enum으로 vault 종류를 구분한다.

| Function | Access | Description |
|----------|--------|-------------|
| `register(vault, vaultType, name, description)` | onlyOwner | 새 싱글톤 vault 등록 |
| `setActive(vault, active)` | onlyOwner | vault 활성화/비활성화 |
| `isActive(vault)` | view | 등록 + 활성 상태 확인 |
| `getVaultInfo(vault)` | view | VaultInfo 구조체 조회 |
| `isRegistered(vault)` | view | 등록 여부 확인 |

#### Vault Implementations (Singleton)

각 vault는 싱글톤 인스턴스로 배포되며, immutable constructor로 초기화된다. 토큰별 설정은 `setup(token, data)`로 수행.

| Vault | Constructor | Description |
|-------|------------|-------------|
| `BurnVault` | singleton UUPS | 본딩: NadFunRouter.buy()+burn; 졸업 후: NadSwapAdapter 스왑+burn → 0xdead |
| `GiftVault` | singleton UUPS | claimable gift balance; 만료 후 본딩: NadFunRouter.buy()+burn, 졸업 후: NadSwapAdapter 스왑+burn → 0xdead |
| `LPVault` | `constructor(tokenRegistry)` | 본딩: early return(누적); 졸업 후: 절반 스왑 → addLiquidity → LP 소각 |
| `CreatorFeeVault` | `constructor(authorized)` | `mapping(token→recipient)`, `setup()`으로 토큰별 수령인 설정. 직접 전송 (단계 무관) |

---

## Library

#### BondingCurveLibrary
> `src/libraries/BondingCurveLibrary.sol`

상수곱(constant-product) 본딩커브 수학 라이브러리. 순수 함수로만 구성.

**공식 (Constant-Product AMM):**
```
k = virtualQuoteReserve_init × virtualTokenReserve_init (상수, 커브 생성 시 결정)

getAmountOut(amountIn, k, reserveIn, reserveOut):
  amountOut = reserveOut - ceil(k / (reserveIn + amountIn))

getAmountIn(amountOut, k, reserveIn, reserveOut):
  newReserveIn = ceil(k / (reserveOut - amountOut))
  amountIn = newReserveIn - reserveIn
```

**반올림 규칙:**
- `getAmountOut` → 내림 (사용자에게 불리 → 프로토콜 보호)
- `getAmountIn` → 올림 (사용자에게 불리 → 프로토콜 보호)

#### Math / UQ112x112
> `src/libraries/Math.sol`, `src/libraries/UQ112x112.sol`

Uniswap V2에서 사용하는 수학 유틸리티. `min`, `sqrt` (Math), 112-bit 고정소수점 (UQ112x112).

---

## Access Control

현재 권한 모델은 두 축이다.

- `BondingCurve`: `AccessControlUpgradeable`
  - `DEFAULT_ADMIN_ROLE`: `setModule`, `_authorizeUpgrade`
  - `GUARDIAN_ROLE`: `halt`
  - `ROUTER_ROLE`: `create`
- 그 외 주요 업그레이더블 모듈: `AccessManagedUpgradeable`
  - authority는 `ProtocolManager`
  - `ProtocolManager.canCall(caller, target, selector)`가 `owner` 또는 selector 단위 operator permission을 평가

**AccessManaged 대상 컨트랙트**
- `TokenRegistry`
- `LPManager`
- `FeeCollector`
- `NadFunRouter`
- `VaultRegistry`
- `BurnVault`
- `LPVault`
- `CreatorFeeVault`
- `GiftVault`

**대표적인 selector-scoped operator 권한**
- `BondingCurve -> TokenRegistry.register`
- `BondingCurve -> LPManager.addLiquidity`

즉 예전의 `setAuthorizedCaller` 로컬 allowlist는 제거되었고, 운영 컨트랙트 권한도 `ProtocolManager.setOperatorPermission()`으로 중앙 관리한다.

---

## Interaction Flows

### Flow 1: Token Creation (+ NadFunPair 즉시 생성)

```
Creator                BondingCurve            NadFunFactory/Registry    Clones/Vaults
  │                        │                       │                   │
  │── create(params) ─────→│                       │                   │
  │                        │── ProtocolManager.isAllowed(quoteToken)     │
  │                        │── ProtocolManager.getConfig() → reserves    │
  │                        │── ProtocolManager.isCreatorFeeRateAllowed(creatorFeeRate) │
  │                        │── deployFee → feeReceiver (if > 0)         │
  │                        │                       │                   │
  │                        │── clone Token (EIP-1167) ────────────────→│
  │                        │── NadFunFactory.createPair(token, quote) ──→│
  │                        │←── pair address ───────│                   │
  │                        │── TokenRegistry.register(token, pair, quote)│
  │                        │── FeeCollector.setup(pair, token, quote, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)
  │                        │                       │                   │
  │                        │── 싱글톤 vault setup (via VaultRegistry) ──→│ setup
  │                        │── 싱글톤 CreatorFeeProcessor.setup(token, VaultSlot[]) →│
  │                        │── Token.initialize(name, symbol, uri, pair) ──→│ (1B mint → BC)
  │                        │                       │                   │
  │                        │── curves[token] = Curve{                  │
  │                        │     virtualQuoteReserve, virtualTokenReserve,│
  │                        │     creatorFeeRate, graduated: false, pair, ...   │
  │                        │   }                                       │
  │                        │                       │                   │
  │←── emit TokenCreated ──│                       │                   │
```

### Flow 2: Bonding Curve Buy (with Anti-Sniping + Creator fee)

```
User              NadFunRouter              BondingCurve         FeeCollector
  │                      │                      │                   │
  │── buy(BuyParams) ───→│                      │                   │
  │                      │── getAmountOut() → slippage check        │
  │                      │── safeTransferFrom(quote → BC)           │
  │                      │── buy(user, token) ─→│                   │
  │                      │                      │── detect quoteAmt │
  │                      │                      │── protocolFee → feeReceiver
  │                      │                      │── snipingPenalty → feeReceiver
  │                      │                      │── creator fee → FeeCollector.collectFee()
  │                      │                      │   │──────────────→│
  │                      │                      │── remaining → AMM │
  │                      │                      │── tokensOut → user│
  │                      │                      │                   │
  │                      │                      │── graduation check│
  │←── tokensOut ────────│                      │                   │
```

### Flow 3: Graduation (Auto-trigger)

```
BondingCurve             LPManager              Token                NadFunPair
  │                          │                    │                    │
  │── curve.graduated = true │                    │                    │
  │── graduateFee → feeReceiver                   │                    │
  │── excess tokens burn ───────────────────────→│ burn()              │
  │                          │                    │                    │
  │── transfer tokens+quote to LPManager          │                    │
  │── LPManager.addLiquidity()                    │                    │
  │                          │── adapter.addLiquidity() ─────────────→│
  │                          │── LP held by LPManager                  │
  │                          │                    │                    │
  │── Token.setIsGraduated()────────────────────→│ graduated = true   │
  │── emit TokenGraduated    │                    │                    │
```

### Flow 4: DEX Trade → Fee Collection

```
Trader                  NadFunPair              FeeCollector
  │                          │                    │
  │── swap(amount0Out, ...) →│                    │
  │                          │                    │
  │                          │── getFeeRate(token)─→│
  │                          │←── totalFeeRate ────│
  │                          │                    │
  │                          │── fee 계산 (quoteToken)
  │                          │── transfer(feeCollector, fee) ────→│
  │                          │── collectFee(pair) ────────────────→│  // balance delta
  │                          │                    │── accumulated += fee
  │                          │── k invariant check│
  │                          │── tokensOut → user │
  │←── tokensOut ────────────│                    │
```

### Flow 5: Fee Settlement → Vault Distribution

Settlement works in both bonding and post-graduation phases.

```
Authorized settler      FeeCollector            CreatorFeeProcessor         Vaults
  │                          │                    │                  │
  │── settle(pair) ─────────→│                    │                  │
  │                          │── check threshold  │                  │
  │                          │── _settling[pair] = true              │
  │                          │── creatorFeeAmount → CreatorFeeProcessor ──────────→│
  │                          │                    │── distribute by BPS:
  │                          │                    │   ├── BurnVault → phase-aware buy+burn
  │                          │                    │   ├── LPVault → accumulate or swap+LP
  │                          │                    │   └── CreatorFeeVault → transfer
  │                          │                    │                  │
  │                          │── _settling[pair] = false             │
  │                          │── reset accumulated│                  │
```

---

## Complete Lifecycle (End-to-End)

```
Phase 1: Token Creation (+ NadFunPair 선점 생성)
  Creator → BondingCurve.create(params)
  └─ Token 클론 배포 (순수 ERC20, EIP-1167)
  └─ NadFunFactory.createPair() — NadFunPair 즉시 생성 (migration attack 방지)
  └─ FeeCollector.setup(pair, token, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)
  └─ CreatorFeeProcessor.setup(token, VaultSlot[])
  └─ Vault setup (via VaultRegistry)
  └─ TokenRegistry.register(token, pair, quoteToken, dexType)
  └─ BondingCurve holds all minted tokens (1B)

Phase 2: Bonding Curve Trading (with Anti-Sniping)
  Buyer → NadFunRouter.buy() — protocolFee + snipingPenalty + creator fee
  Seller → NadFunRouter.sell() — protocolFee + creator fee
  └─ Creator fee sent to FeeCollector.collectFee()
  └─ Price determined by BondingCurveLibrary constant-product formula
  └─ Anti-Sniping: per-block lookup via ProtocolManager (default: 80%/40%/20%/15%/10%/10%/5% for blocks 0..6, then 0)

Phase 3: Graduation (Automatic)
  virtualTokenReserve == minTokenReserve triggers _graduate()
  └─ graduateFee 차감
  └─ excess 토큰 burn
  └─ LPManager.addLiquidity() → NadFunPair에 유동성 추가
  └─ LPManager custody (permanent protocol launch liquidity)
  └─ Token.setIsGraduated()

Phase 4: DEX Trading (via NadFunPair)
  Traders use NadFunPair (via NadFunRouter)
  └─ NadFunPair.swap() deducts fees in swap()
  └─ LP fee (0.25%) stays in reserves
  └─ Protocol fee + Creator fee → FeeCollector
  └─ Creator fee is permanent (no expiration)

Phase 5: Fee Settlement (Restricted)
  Accumulated fee >= settlementThreshold → authorized settler calls FeeCollector.settle()
  └─ Works in both bonding and post-graduation phases
  └─ _settling flag in FeeCollector prevents recursive fee accumulation
  └─ Protocol fee portion은 collectFee 시점에 즉시 feeReceiver로 전송
  └─ settle()은 누적 creator fee만 CreatorFeeProcessor.processCreatorFee()로 전달
  └─ CreatorFeeProcessor → vault 분배 (BurnVault, GiftVault, LPVault, CreatorFeeVault 등)

Phase 6: Revenue Distribution (Phase-Aware)
  Each vault handles its own logic after receiving quoteToken:
  └─ BurnVault: bonding → NadFunRouter.buy()+burn; post-grad → adapter swap+burn
  └─ GiftVault: claimable until expiry; expired bonding → NadFunRouter.buy()+burn; post-grad → adapter swap+burn
  └─ LPVault: bonding → early return (accumulate); post-grad → swap+addLiquidity+burn LP
  └─ CreatorFeeVault: direct transfer to recipient (phase-independent)
```

---

## Deployment Order

```
1. Implementation contracts
   ├── Token impl (클론용 원본, 순수 ERC20)
   ├── BurnVault (싱글톤, constructor(tokenRegistry))
   ├── LPVault (싱글톤, constructor(tokenRegistry))
   └── CreatorFeeVault (싱글톤, constructor(authorized))

2. NadFunFactory (singleton, 프록시 없음)

3. TokenRegistry (UUPS proxy)
   └── initialize(protocolManager)

4. ProtocolManager (UUPS proxy)
   └── initialize(admin, feeReceiver)
   └── addQuoteToken(wmon, virtualReserve, virtualTokenReserve, minTokenReserve, deployFee, graduateFee)

5. LPManager (UUPS proxy)
   └── initialize(protocolManager, tokenRegistry)

6. FeeCollector (UUPS proxy)
   └── initialize(protocolManager, creatorFeeProcessor, feeReceiver, threshold, bondingCurve)

7. BondingCurve (UUPS proxy)
   └── initialize(admin, tokenImpl, protocolManager)

8. CreatorFeeProcessor (싱글톤)
   └── constructor(bondingCurve)

9. NadFunRouter (UUPS proxy)
   └── initialize(bondingCurve, tokenRegistry, protocolManager, wrappedNative)

10. BondingCurve 모듈 등록
    └── setModule(MODULE_TOKEN_REGISTRY, tokenRegistry)
    └── setModule(MODULE_LP_MANAGER, lpManager)
    └── setModule(MODULE_CREATOR_FEE_PROCESSOR, creatorFeeProcessor)
    └── setModule(MODULE_FEE_COLLECTOR, feeCollector)
    └── setModule(MODULE_FACTORY, nadFunFactory)

11. operator 권한 설정
    └── ProtocolManager.setOperatorPermission(bondingCurve, tokenRegistry, register.selector, true)
    └── ProtocolManager.setOperatorPermission(bondingCurve, lpManager, addLiquidity.selector, true)
    └── ProtocolManager.setOperatorPermission(bondingCurve, lpManager, removeLiquidity.selector, true)

12. VaultRegistry (UUPS proxy)
    └── initialize(admin)
    └── register(burnVault, VaultType.Burn, "BurnVault", "Buyback and burn")
    └── register(lpVault, VaultType.LP, "LPVault", "LP injection")
    └── register(creatorFeeVault, VaultType.Creator, "CreatorFeeVault", "Direct transfer")
    └── register(giftVault, VaultType.Gift, "GiftVault", "Gift with expiry")

13. BondingCurve에 VaultRegistry 모듈 등록
    └── setModule(MODULE_VAULT_REGISTRY, vaultRegistry)
```

---

## Security

### Defense Mechanisms

| Mechanism | Contract | Description |
|-----------|----------|-------------|
| `_totalQuoteReserved` | BondingCurve | Per-quote-token accounting prevents cross-curve reserve theft. |
| `nonReentrant` | BondingCurve | OpenZeppelin ReentrancyGuard on `buy()`, `sell()`, and `create()`. |
| Anti-Sniping Penalty | BondingCurve | Per-block lookup table on ProtocolManager (`snipingPenaltyTable`). Default: 80%/40%/20%/15%/10%/10%/5% for the first 7 blocks after creation, then 0%. |
| `AlreadyGraduated` | BondingCurve | `graduated` flag checked on every `buy()`/`sell()`. |
| NadFunPair fee enforcement | NadFunPair | Fees deducted atomically in `swap()`, verified by k invariant check. No bypass via direct transfer. |
| Pair transfer guard | Token | Transfers to pair address blocked before graduation. Prevents reserve corruption from direct token transfers during bonding phase. |
| Restricted settlement | FeeCollector | Only authorized settlers can trigger `settle()` when threshold is met. This removes public timing of fee-waived vault swaps while still preventing unbounded fee accumulation. |
| Fee caps | ProtocolManager | Protocol fees individually capped to prevent excessive extraction. |
| Vault callback isolation | CreatorFeeProcessor | `try/catch` around `vault.afterDeposit()` — vault failure does not revert distribution. |
| VaultRegistry deactivation | VaultRegistry | Admin can deactivate vulnerable vault types via `setActive(implementation, false)`. |
| Creator fee rate allowlist | ProtocolManager | `isCreatorFeeRateAllowed(rate)` — only pre-approved rates accepted. |
| ERC-165 validation | VaultRegistry | Vault registration validates `IVault` support via `supportsInterface()`. |

### Known Limitations

| # | Issue | Status | Notes |
|---|-------|--------|-------|
| 1 | Creator fee is permanent (no expiration) | By design | v1 had creatorFeeExpirationTime; v2 removes it. Creator fee runs indefinitely. |

### Attack Test Suite

Attack vectors verified across test files:

| File | Vectors | Tests |
|------|---------|-------|
| `test/core/QuoteReserveAttack.t.sol` | Cross-curve reserve theft | 5 |
| `test/core/BondingCurveAttack.t.sol` | Direct buy, flash loan, reentrancy, post-graduation | 4 |
| `test/vault/VaultAttack.t.sol` | Deactivated vault, reverting vault | 5 |
| `test/modules/ModuleAttack.t.sol` | Double liquidity, extreme fees, creator fee rate allowlist | 4 |

---

## Test Coverage

Test count changes frequently; use `forge test` as the source of truth.

| Suite | Tests | Coverage Area |
|-------|-------|---------------|
| NadFunPairTest | varies | Mint, burn, swap, skim, sync (vanilla V2) |
| NadFunPairFeeTest | varies | Fee deduction, FeeCollector integration |
| NadFunFactoryTest | varies | Pair creation, CREATE2, dedup |
| FeeCollectorTest | varies | Setup, collection, settlement, split |
| BondingCurveV2Test | varies | Token + NadFunFactory + creator fee to FeeCollector |
| BondingCurveTest | varies | Buy/sell, reserve, anti-sniping |
| RouterV2Test | varies | NadFunRouter (BC + DEX) + LPManager |
| CreatorFeeProcessorV2Test | varies | quoteToken distribution to vaults |
| BurnVaultV2Test | varies | Buyback & burn via NadFunPair |
| LPVaultV2Test | varies | LP addition via NadFunPair |
| VaultRegistryTest | varies | Registration, deactivation, ERC-165 |
| QuoteReserveAttackTest | 5 | Cross-curve reserve theft |
| BondingCurveAttackTest | 4 | Attack vectors #2-5 |
| ModuleAttackTest | 4 | Double LP, extreme fees, creator fee rate allowlist |
| VaultAttackTest | 5 | Vault callback failures, deactivated types |
