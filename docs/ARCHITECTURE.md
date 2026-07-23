# GIWA Launchpad — Architecture Documentation

## Overview

GIWA Launchpad는 Monad에서 동작하는 본딩커브 토큰 런치패드 프로토콜이다. 현재 사용자 런타임은 `GiwaRouter`를 통해 본딩커브와 등록된 canonical Uniswap V3 풀을 연결한다.

> **통합 경계:** canonical V3 라우터, adapter, pool deployer, liquidity actor는 구현되어 있다. 그러나 현재 `script/deploy/normal/Deploy.s.sol`의 BondingCurve 생성/졸업 배선은 여전히 아래에 문서화된 NadFun V2 factory/LPManager 경로를 등록한다. 따라서 기본 스크립트는 end-to-end V3 launch를 만들지 않으며, V2로 졸업한 메타데이터는 GiwaRouter의 졸업 후 경로에서 거부된다.

**핵심 특징:**
- 순수 ERC20 Token (fee-on-transfer 제거, EIP-1167 Minimal Proxy로 배포)
- GiwaRouter + V3SwapAdapter — canonical Uniswap V3 exact-input/exact-output 라우팅, QuoterV2 견적, native quote 지원
- 유지 중인 Custom DEX (NadFunFactory/NadFunPair) — 기존 생성/졸업 및 vault 호환 경로
- FeeCollector — 중앙 수수료 관리 (fee config + 누적 + threshold settlement)
- UUPS 업그레이드 패턴 (BondingCurve, ProtocolManager, TokenRegistry, LPManager, VaultRegistry, FeeCollector)
- Anti-Sniping: ProtocolManager의 `snipingPenaltyTable`(블록 단위 BPS 배열)로 설정 (기본: `[8000, 4000, 2000, 1500, 1000, 1000, 500]` BPS, 블록 7+ → 0)
- 플러그인 가능한 싱글톤 Vault 시스템 (VaultRegistry — authority-restricted 등록, VaultType 기반)
- Migration Attack 방지: 토큰 생성 시 NadFunPair를 즉시 생성하여 선점 공격 차단

---

## Contract Map

```
┌─────────────────────────────────────────────────────────────────┐
│                         CORE LAYER                              │
│  ┌────────────────┐  ┌──────────────────────┐  ┌───────────────┐│
│  │  BondingCurve   │  │ GiwaRouter            │  │ProtocolManager││
│  │  (UUPS Proxy)   │  │ (UUPS Proxy)          │  │ (UUPS)        ││
│  │  상태+로직+클론  │  │ BC + V3 통합 라우터    │  │수수료+creatorFee+   ││
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
│  │V3PoolDeployer │  │V3SwapAdapter │  │Legacy V2 DEX │          │
│  │(pool init)    │  │(swap/callback)│ │(compatibility)│         │
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

#### GiwaRouter (UUPS Proxy)
> `src/router/GiwaRouter.sol`

본딩커브와 canonical Uniswap V3 거래를 통합하는 사용자 진입점이다. 졸업 여부는 `BondingCurve.getCurve()`에서 확인하고, 졸업 후에는 TokenRegistry의 `DexType.UniswapV3`, canonical pool, quote token, fee tier를 검증한 뒤 `V3SwapAdapter`를 호출한다.

| Capability | Functions | Behavior |
|------------|-----------|----------|
| Create | `create`, `createWithNative` | BondingCurve 생성 호출; native는 configured wrapped-native quote만 허용 |
| Exact input | `buy`, `buyWithNative`, `buyWithPermit`, `sell`, `sellToNative`, `sellWithPermit`, `sellToNativeWithPermit` | 최소 출력 검증; V3 price limit 부분 체결 시 call-scoped 미사용 입력 refund |
| Exact output | `exactOutBuy`, `exactOutBuyWithNative`, `exactOutSell`, `exactOutSellToNative` | 최대 입력 검증; graduated V3에서는 정확한 전량 출력을 요구 |
| Quote | `getAmountOut`, `getAmountIn`, `getBondingCurveAmountOut`, `getBondingCurveAmountIn`, `getDexAmountOut`, `getDexAmountIn` | curve 또는 QuoterV2 사용. Quoter-backed 함수는 non-view이므로 클라이언트는 `eth_call`로 호출 |

**V3 quote-side protocol fee:** exact-input buy는 최대 fee를 먼저 제외하고 실제 pool 사용량 비율만큼 fee를 올림 계산한다. exact-input sell은 pool quote output에 fee를 적용한다. exact-output buy는 pool 입력에서 gross quote를 역산하고, exact-output sell은 사용자 net output에서 pool gross output을 역산한다. 실행 시점의 `dexProtocolFeeRate`와 `feeReceiver`를 사용한다.

**Native 안전성:** token quote가 router의 configured wrapped-native와 일치해야 한다. 호출 범위의 routed 금액만 wrap하며, 남은 native를 refund하고 기존 router WNATIVE/native 잔액은 sweep하지 않는다. `receive()`는 WNATIVE `withdraw`만 허용한다.

#### V3SwapAdapter (Singleton)
> `src/adapters/V3SwapAdapter.sol`

Router가 제공한 입력을 canonical V3 pool에서 직접 swap한다. Registry metadata와 factory-derived pool을 재검증하고, swap마다 nonce를 포함한 하나의 활성 callback context를 저장한다. callback은 caller, data hash, token order, fee tier, delta 방향과 `amountInMax`를 검증하며 context를 삭제한 뒤 payer로부터 pool에 입력을 지급한다. swap 종료 시 callback 소비 여부와 payer/recipient balance delta도 검증한다.

---

#### ProtocolManager (UUPS Proxy)
> `src/core/ProtocolManager.sol`

프로토콜 전역 설정을 통합 관리하는 단일 컨트랙트. 수수료 설정, 크리에이터 수수료 허용 목록, 기축 토큰 관리, 스나이핑 페널티 등을 담당한다.

**수수료 관리:**

| Function | Access | Description |
|----------|--------|-------------|
| `feeReceiver()` | view | 프로토콜 수수료 수취인 |
| `curveProtocolFeeRate(quoteToken)` | view | 본딩커브 프로토콜 수수료 (BPS) |
| `deployFee(quoteToken)` | view | quote 토큰별 토큰 배포 수수료 |
| `graduateFee(quoteToken)` | view | quote 토큰별 졸업 수수료 |
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
| `initialize(name, symbol, uri, bondingCurve, pair)` | initializer | 토큰 초기화, 1B를 BondingCurve에 민팅 |
| `burn(amount)` | public | 토큰 소각 |
| `setIsGraduated()` | only BondingCurve | 졸업 상태로 전환 |
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
FeeCollector.settle(pair, minAmountOut)
  └─ CreatorFeeProcessor.processCreatorFee(token, quoteToken, amount)
      └─ 각 vault[i]에 BPS 비율로 분배:
           ├─ transfer(vault[i], amount * bps / BPS)
           └─ vault[i].afterDeposit(token, quoteToken, amount)
```

**BPS 제약:** `sum(vaults[i].bps) = 10,000` (최대 5개 vault)
**Vault callback:** 직접 호출하므로 vault 실패 시 creator-fee processing과 상위 settlement 트랜잭션 전체가 revert한다.

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
5. FeeCollector.collectFee(pair, protocolFee, creatorFee) 호출 — 명시한 구성요소를 수신 balance delta가 충족해야 함
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
| `collectFee(pair, protocolFee, creatorFee)` | pair 또는 BondingCurve | 수신 balance delta가 명시 fee 합계를 충족하는지 검증하고 protocol/creator 몫 처리 |
| `settle(pair, minAmountOut)` | restricted | threshold와 최소 settlement 견적을 검증한 뒤 누적 creator fee 정산 |
| `getFeeConfig(pair)` | view | `FeeConfig { baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate }` 조회 |
| `accumulatedFee(pair)` | view | 누적 creator fee 조회 |
| `isSettleable(pair)` | view | 정산 가능 여부 |
| `settlementThreshold(pair)` | view | pair quoteToken의 정산 임계값 조회 |
| `setCurveProtocolFeeRate(pair, rate)` | restricted | 커브 protocol fee rate 변경 |
| `setDexProtocolFeeRate(pair, rate)` | restricted | DEX protocol fee rate 변경 |

**Settlement 로직:**

Settlement은 본딩 단계와 졸업 후 단계 모두에서 동작한다. `_settling` 플래그는 FeeCollector에 `mapping(address pair => bool)`로 저장되며, 정산 중 BondingCurve는 수수료 0을 반환하여 재귀적 수수료 누적을 방지한다.

```
settle(pair, minAmountOut):
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

ProtocolManager owner 또는 selector-authorized operator가 관리하는 authority-restricted 싱글톤 vault 레지스트리. VaultType(Custom, Burn, LP, Creator, Gift, Dividend) enum으로 vault 종류를 구분한다.

| Function | Access | Description |
|----------|--------|-------------|
| `register(vault, name, description, vaultType)` | restricted | 새 싱글톤 vault 등록 |
| `setActive(vault, active)` | restricted | vault 활성화/비활성화 |
| `isActive(vault)` | view | 등록 + 활성 상태 확인 |
| `getVaultInfo(vault)` | view | VaultInfo 구조체 조회 |
| `isRegistered(vault)` | view | 등록 여부 확인 |

#### Vault Implementations (Singleton)

각 vault는 zero-argument implementation과 ERC1967 proxy로 구성된 singleton UUPS 배포다. 공통 runtime dependency는 proxy initializer로, 토큰별 설정은 `setup(token, data)`로 구성한다.

| Vault | Pattern | Description |
|-------|---------|-------------|
| `BurnVault` | singleton UUPS proxy | 본딩: GiwaRouter.buy()+burn; 졸업 후: registry adapter 스왑+burn → 0xdead |
| `GiftVault` | singleton UUPS proxy | claimable gift balance; 만료 후 본딩: GiwaRouter.buy()+burn, 졸업 후: registry adapter 스왑+burn → 0xdead |
| `LPVault` | singleton UUPS proxy | 본딩: early return(누적); 졸업 후: 절반 스왑 → addLiquidity → LP 소각 |
| `CreatorFeeVault` | singleton UUPS proxy | `setup()`으로 토큰별 creator를 설정하고 quoteToken 잔액을 누적. creator가 `claim(token)`으로 ERC-20을 인출하며, 등록 quote가 설정된 WNATIVE이면 native currency으로 unwrap 후 수령 |

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
- `GiwaRouter`
- `V3PoolDeployer`
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
  │                        │── Token.initialize(name, symbol, uri, bondingCurve, pair) ──→│ (1B mint → BC)
  │                        │                       │                   │
  │                        │── curves[token] = Curve{                  │
  │                        │     virtualQuoteReserve, virtualTokenReserve,│
  │                        │     creatorFeeRate, graduated: false, pair, ...   │
  │                        │   }                                       │
  │                        │                       │                   │
  │←── emit Create ────────│                       │                   │
```

### Flow 2: Bonding Curve Buy (with Anti-Sniping + Creator fee)

```
User              GiwaRouter               BondingCurve         FeeCollector
  │                      │                      │                   │
  │── buy(BuyParams) ───→│                      │                   │
  │                      │── getAmountOut() → slippage check        │
  │                      │── safeTransferFrom(quote → BC)           │
  │                      │── buy(user, token) ─→│                   │
  │                      │                      │── detect quoteAmt │
  │                      │                      │── protocol+creator → FeeCollector (creator fee 활성 시)
  │                      │                      │   ├─ protocol → feeReceiver
  │                      │                      │   └─ creator 누적
  │                      │                      │── snipingPenalty → feeReceiver
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
  │── excess tokens ────────────────────────────→│ feeReceiver          │
  │                          │                    │                    │
  │── transfer tokens+quote to LPManager          │                    │
  │── LPManager.addLiquidity()                    │                    │
  │                          │── adapter.addLiquidity() ─────────────→│
  │                          │── LP held by LPManager                  │
  │                          │                    │                    │
  │── Token.setIsGraduated()────────────────────→│ graduated = true   │
  │── emit Graduate          │                    │                    │
```

### Flow 4A: Canonical V3 Trade through GiwaRouter

```
User             GiwaRouter          V3SwapAdapter       Canonical V3 Pool
 │                   │                     │                     │
 │── buy/sell ──────→│                     │                     │
 │                   │── resolve curve graduation + registry metadata
 │                   │── compute pool budget / gross-output target
│                   │── exactInput/exactOutput ─→│              │
 │                   │                     │── factory pool check │
 │                   │                     │── swap ─────────────→│
 │                   │                     │←── authenticated callback
 │                   │                     │── delete context, pay pool
 │                   │←── actual pool input/output ─────────────│
 │                   │── reset adapter allowance                 │
 │                   │── compute actual quote-side router fee    │
 │                   │── fee → current feeReceiver; refund/output│
 │←── output/refund ──│                     │                     │
```

Exact-input may partially fill at a non-zero price limit and refunds unused caller input. Exact-output requires full output. The router fee is separate from the V3 pool fee and is charged only through GiwaRouter.

### Flow 4B: Retained Legacy V2 DEX Trade → Fee Collection

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
  │                          │── collectFee(pair, protocolFee, creatorFee) ─→│
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
  │── settle(pair, minAmountOut) ────────────────→│                  │
  │                          │── check threshold  │                  │
  │                          │── _settling[pair] = true              │
  │                          │── creatorFeeAmount → CreatorFeeProcessor ──────────→│
  │                          │                    │── distribute by BPS:
  │                          │                    │   ├── BurnVault → phase-aware buy+burn
  │                          │                    │   ├── LPVault → accumulate or swap+LP
  │                          │                    │   └── CreatorFeeVault → per-token accrual → creator claim
  │                          │                    │                  │
  │                          │── _settling[pair] = false             │
  │                          │── reset accumulated│                  │
```

---

## Runtime Paths and Integration Boundary

The following lifecycle is the retained V2 path still wired by the default deployment script. GiwaRouter is the bonding-phase entry point, but it deliberately does not route the graduated V2 metadata.

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
  Buyer → GiwaRouter.buy() — protocolFee + snipingPenalty + creator fee
  Seller → GiwaRouter.sell() — protocolFee + creator fee
  └─ Creator fee 활성 시 protocol+creator를 FeeCollector.collectFee(pair, protocolFee, creatorFee)로 처리
  └─ Price determined by BondingCurveLibrary constant-product formula
  └─ Anti-Sniping: per-block lookup via ProtocolManager (default: 80%/40%/20%/15%/10%/10%/5% for blocks 0..6, then 0)

Phase 3: Graduation (Automatic)
  virtualTokenReserve == minTokenReserve triggers _graduate()
  └─ graduateFee 차감
  └─ excess 토큰 → feeReceiver
  └─ LPManager.addLiquidity() → NadFunPair에 유동성 추가
  └─ LPManager custody (permanent protocol launch liquidity)
  └─ Token.setIsGraduated()

Phase 4: Legacy DEX Trading (direct NadFunPair / explicit legacy adapter)
  GiwaRouter rejects this graduated V2 metadata
  └─ NadFunPair.swap() deducts fees in swap()
  └─ LP fee (0.25%) stays in reserves
  └─ Protocol fee + Creator fee → FeeCollector
  └─ Creator fee is permanent (no expiration)

Phase 5: Fee Settlement (Restricted)
  Accumulated fee >= settlementThreshold → authorized settler calls FeeCollector.settle(pair, minAmountOut)
  └─ Works in both bonding and post-graduation phases
  └─ _settling flag in FeeCollector prevents recursive fee accumulation
  └─ Protocol fee portion은 collectFee 시점에 즉시 feeReceiver로 전송
  └─ settle(pair, minAmountOut)은 누적 creator fee만 CreatorFeeProcessor.processCreatorFee()로 전달
  └─ CreatorFeeProcessor → vault 분배 (BurnVault, GiftVault, LPVault, CreatorFeeVault 등)

Phase 6: Revenue Distribution (Phase-Aware)
  Each vault handles its own logic after receiving quoteToken:
  └─ BurnVault: bonding → GiwaRouter.buy()+burn; post-grad → registry adapter swap+burn
  └─ GiftVault: claimable until expiry; expired bonding → GiwaRouter.buy()+burn; post-grad → registry adapter swap+burn
  └─ LPVault: bonding → early return (accumulate); post-grad → swap+addLiquidity+burn LP
  └─ CreatorFeeVault: quoteToken을 토큰별 누적; creator가 ERC-20 또는 WNATIVE-unwrapped native로 claim (phase-independent)
```

For a token already registered as `DexType.UniswapV3`, the current runtime path is instead:

```
GiwaRouter → validate graduated curve + V3 registry metadata
           → charge quote-side dexProtocolFeeRate to current feeReceiver
           → V3SwapAdapter → canonical factory pool
```

Completing creation → V3 graduation requires deployment/lifecycle wiring that deploys and authorizes the V3 pool/liquidity components and registers V3 metadata; the retained `Deploy.s.sol` does not do that today.

---

## Default Deployment Order (Hybrid; V2 lifecycle retained)

```
1. Token implementation (EIP-1167 clone template)

2. ProtocolManager UUPS proxy
   ├── initialize(deployer, feeReceiver)
   └── addQuoteToken(...) for wrappedNative and LV_MON

3. TokenRegistry UUPS proxy
   └── initialize(protocolManager)

4. LPManager UUPS proxy
   └── initialize(protocolManager, tokenRegistry)

5. BondingCurve UUPS proxy
   └── initialize(deployer, tokenImplementation, protocolManager)

6. Canonical V3 execution and quote dependencies
   ├── V3SwapAdapter(canonicalV3Factory, tokenRegistry)
   └── QuoterV2(canonicalV3Factory, wrappedNative)

7. GiwaRouter UUPS proxy
   └── initialize(protocolManager, bondingCurve, tokenRegistry, wrappedNative, v3SwapAdapter, quoterV2)

8. CreatorFeeProcessor + FeeCollector
   ├── predict FeeCollector address to break the constructor dependency cycle
   ├── CreatorFeeProcessor(bondingCurve, predictedFeeCollector)
   └── FeeCollector.initialize(protocolManager, creatorFeeProcessor, bondingCurve, giwaRouter)

9. Retained NadFunFactory/NadFunPair implementation and factory fee receiver

10. Retained zero-argument NadSwapAdapter
    └── TokenRegistry.setAdapter(DexType.UniswapV2, nadSwapAdapter)

11. VaultRegistry UUPS proxy
    └── initialize(protocolManager)

12. BurnVault, LPVault, CreatorFeeVault, optional GiftVault
    └── each is deployed as a zero-argument implementation + ERC1967 proxy and initialized with its runtime dependencies

13. BondingCurve module registration
    ├── TOKEN_REGISTRY, LP_MANAGER, VAULT_REGISTRY
    ├── CREATOR_FEE_PROCESSOR, FEE_COLLECTOR
    └── FACTORY = retained NadFunFactory

14. Selector-scoped operator permissions

15. Grant BondingCurve.ROUTER_ROLE to GiwaRouter

16. Rotate BondingCurve roles and ProtocolManager ownership to multisig

Remaining production V3 lifecycle work:
   ├── deploy/authorize V3PoolDeployer and V3LiquidityActor as appropriate
   ├── configure ProtocolManager.setV3QuoteConfig(quoteToken, feeTier, lpFeeProtocolShareBps)
   └── replace BondingCurve MODULE_FACTORY + LPManager V2-only graduation wiring
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
| Vault callback atomicity | CreatorFeeProcessor | Direct `vault.afterDeposit()` calls make any vault failure revert the full distribution and settlement transaction. |
| VaultRegistry deactivation | VaultRegistry | An authority-approved caller can deactivate a vulnerable vault via `setActive(vault, false)`. |
| Creator fee rate allowlist | ProtocolManager | `isCreatorFeeRateAllowed(rate)` — only pre-approved rates accepted. |
| ERC-165 validation | VaultRegistry | Vault registration validates `IVault` support via `supportsInterface()`. |
| Canonical callback binding | V3SwapAdapter | Registry/factory pool, token order, fee tier, nonce/data hash, delta direction, and input cap must match the active swap. |
| Context deletion before payment | V3SwapAdapter | Active callback state is deleted before the external token pull that pays the pool. |
| Call-scoped native accounting | GiwaRouter | Only configured wrapped-native quotes are accepted; wrap/unwrap/refund amounts cannot sweep pre-existing router balances. |
| Allowance cleanup | GiwaRouter | Adapter allowances are reset to zero after every canonical V3 execution. |

### Known Limitations

| # | Issue | Status | Notes |
|---|-------|--------|-------|
| 1 | Creator fee is permanent (no expiration) | By design | v1 had creatorFeeExpirationTime; v2 removes it. Creator fee runs indefinitely. |
| 2 | Default deployment retains V2 creation/graduation wiring | Open integration work | The deployed GiwaRouter V3 runtime is not an end-to-end V3 launch until lifecycle wiring and V3 quote config are completed. |

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
| RouterV2Test | varies | Retained V2 LPManager regression |
| GiwaRouterTest / GiwaRouterV3SwapTest | varies | Curve dispatch, four V3 fee flows, quoting, slippage, partial fill, refunds, donations |
| GiwaRouterNativeV3Test | varies | WNATIVE-only native routing and call-scoped refund isolation |
| V3SwapAdapterTest | varies | Canonical pool/callback/context/delta/reentrancy checks |
| CreatorFeeProcessorV2Test | varies | quoteToken distribution to vaults |
| BurnVaultV2Test | varies | Buyback & burn via NadFunPair |
| LPVaultV2Test | varies | LP addition via NadFunPair |
| VaultRegistryTest | varies | Registration, deactivation, ERC-165 |
| QuoteReserveAttackTest | 5 | Cross-curve reserve theft |
| BondingCurveAttackTest | 4 | Attack vectors #2-5 |
| ModuleAttackTest | 4 | Double LP, extreme fees, creator fee rate allowlist |
| VaultAttackTest | 5 | Vault callback failures, deactivated types |
