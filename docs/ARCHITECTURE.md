# GIWA Launchpad 아키텍처

## 개요

GIWA Launchpad는 가상 준비금 본딩커브에서 토큰을 출시한 뒤 canonical Uniswap V3 pool로 졸업시키는 V3 전용 프로토콜이다. 졸업 유동성은 프로토콜이 영구 보유하며, V3 LP fee만 수집해 protocol과 creator에게 분배한다.

```text
Creator / Trader
      │
      ▼
 YachaRouter
      ├──────── pre-graduation ───────► BondingCurve
      │                                      │
      │                                      ├─ V3PoolDeployer
      │                                      ├─ TokenRegistry
      │                                      └─ LPManager
      │                                             │
      │                                             ▼
      │                                      V3LiquidityActor
      │                                             │
      └──────── post-graduation ─────► V3SwapAdapter│
                                             │      │
                                             ▼      ▼
                                      canonical Uniswap V3 pool

 LPManager.collect()
      ├─ token fee ──swap──► quote
      ├─ protocol share ──► ProtocolManager.feeReceiver()
      └─ creator share ───► CreatorFeeProcessor ─► CreatorFeeVault
```

## 핵심 설계 원칙

- 토큰마다 TokenRegistry에 등록된 canonical V3 pool은 하나다.
- 지원 quote token과 lifecycle 수수료는 ProtocolManager가 quote별로 관리한다.
- creator 거래 수수료는 없다. Creator 수익은 수집된 V3 LP fee의 creator share에서만 발생한다.
- 졸업 유동성 원금에는 출금 경로가 없다.
- token으로 수집된 LP fee는 quote로 완전히 변환된 후 분배한다.
- 접근 권한은 owner 또는 `(operator, target, selector)` 단위로 제한한다.
- 외부 swap/mint callback은 factory와 registry로 canonical pool을 재검증한다.
- ERC-20 이동은 실제 balance delta로 검증해 transfer tax와 잘못된 회계를 거부한다.

## 컴포넌트

### ProtocolManager

`ProtocolManager`는 UUPS proxy이자 프로토콜 전역 authority다.

quote token별 `QuoteConfig`:

- `virtualReserve`
- `virtualTokenReserve`
- `minTokenReserve`
- `deployFee`
- `graduateFee`
- `curveProtocolFeeRate`
- `dexProtocolFeeRate`
- `v3FeeTier`
- `lpFeeProtocolShareBps`
- `active`

추가 전역 설정:

- 현재 `feeReceiver`
- 블록별 anti-sniping BPS table
- `(operator, target, selector)` permission

ProtocolManager owner는 AccessManaged target을 직접 호출할 수 있다. 비소유자는 `setOperatorPermission()`으로 명시적으로 허용된 selector만 호출할 수 있다.

### BondingCurve

`BondingCurve`는 UUPS proxy이며 다음 lifecycle을 담당한다.

- deterministic Token clone 생성
- 실제 및 가상 준비금 회계
- curve buy/sell
- 일반 buy의 anti-sniping penalty
- 졸업 조건 판정
- pool 생성, registry 등록, creator vault setup
- LPManager를 통한 졸업 유동성 배치

역할:

- `DEFAULT_ADMIN_ROLE`: module 설정, role 관리, upgrade
- `GUARDIAN_ROLE`: `halt()` 제어
- `ROUTER_ROLE`: `create()`, `buy()`, `sell()` 호출

현재 canonical YachaRouter만 생성과 졸업 전 거래에 사용하는 router다.

### TokenRegistry

`TokenRegistry`는 launch token metadata의 source of truth다.

- token과 quote token
- canonical pool
- V3 fee tier
- DEX type
- 등록 여부와 역방향 pool lookup

YachaRouter, LPManager, V3PoolDeployer, V3SwapAdapter는 registry metadata와 factory pool을 함께 검증한다.

### V3PoolDeployer

`V3PoolDeployer`는 configured factory에서 canonical pool을 생성하거나 기존 pool을 검증한다. Pool은 본딩커브의 졸업 목표 가격에 맞춰 초기화된다.

### LPManager

`LPManager`는 UUPS proxy이며 V3 liquidity accounting의 중심이다.

주요 함수:

| 함수 | 권한 | 역할 |
| --- | --- | --- |
| `setV3LiquidityActor(actor, factory)` | restricted | actor와 factory 최초 설정 |
| `allocate(params)` | restricted | 졸업 자산으로 두 영구 position 생성 |
| `increaseLiquidity(token, tokenAmount, quoteAmount)` | restricted | 기존 두 position에 자산 추가 |
| `collect(tokens)` | restricted | LP fee 수집, quote 변환, protocol/creator 분배 |
| `callStaticGetAccumulatedFees(token)` | view | 현재 수집 가능한 token/quote fee 조회 |

`allocate()`와 `increaseLiquidity()`는 contract-v3의 tick/range 수학과 동일한 두-position 방식을 사용한다. Position NFT 또는 principal을 외부로 빼는 함수는 없다.

`collect()`는 다음 순서로 실행한다.

1. 저장된 pool과 TokenRegistry/factory metadata 일치 여부를 검증한다.
2. V3LiquidityActor에서 두 position의 fee를 LPManager로 수집한다.
3. token fee 전량을 canonical pool에서 quote로 exact-input swap한다.
4. 직접 수집한 quote fee와 swap 결과를 합산한다.
5. quote별 `lpFeeProtocolShareBps`만큼 `feeReceiver`로 전송한다.
6. 나머지 quote에 대해 CreatorFeeProcessor allowance를 설정하고 `processCreatorFee()`를 호출한다.
7. 임시 allowance를 0으로 초기화하고 entry balance가 보존됐는지 검증한다.

### V3LiquidityActor

`V3LiquidityActor`는 LPManager만 호출할 수 있는 immutable singleton이다.

- 두 permanent position 보유
- canonical mint callback 인증
- allocation과 increase 실행
- position fee만 LPManager로 전달

Fee 수집은 position liquidity를 감소시키지 않는다.

### V3SwapAdapter

`V3SwapAdapter`는 immutable singleton이다.

- canonical registered pool에서 직접 swap
- exact-input, exact-output 지원
- swap callback에서 factory와 registry 검증
- 호출 단위 balance delta 확인

### YachaRouter

`YachaRouter`는 UUPS user entry point다.

- token create와 initial buy
- 졸업 전 curve buy/sell
- 졸업 후 V3 exact-input/exact-output
- ERC-2612 permit
- native wrap/unwrap
- deadline, slippage, refund
- lifecycle-aware quote

Router는 TokenRegistry metadata를 기준으로 curve 또는 V3 경로를 선택한다. Native route는 해당 token의 quote token이 router의 WNATIVE와 일치할 때만 허용한다.

### CreatorFeeProcessor와 CreatorFeeVault

`CreatorFeeProcessor`는 ProtocolManager의 selector permission을 사용하는 immutable singleton이다.

- BondingCurve가 token별 vault slot과 BPS를 한 번 설정한다.
- LPManager가 creator share를 quote token으로 전달한다.
- Processor는 quote를 각 vault로 전송하고 `afterDeposit()`을 호출한다.
- 입력과 분배 후 Processor의 기존 잔액이 보존되어야 한다.

기본 배포는 `CreatorFeeVault` 하나를 10,000 BPS로 등록한다. Vault는 token별 creator와 quote balance를 기록하며, creator가 claim할 때 WNATIVE quote는 native asset으로 unwrap한다.

### Lens

`Lens`는 현재 YachaRouter, BondingCurve, TokenRegistry를 연결하는 immutable frontend facade다. Router 교체 시 Lens도 새 router 주소로 재배포한다.

`TokenInfoLens`는 token version과 quote-token metadata를 외부 integration에 제공한다.

## Token lifecycle

### 생성

```text
Creator
  └─ YachaRouter.create/createWithNative
       └─ BondingCurve.create
            ├─ Token clone
            ├─ V3PoolDeployer.createPool
            ├─ TokenRegistry.registerV3
            ├─ CreatorFeeProcessor.setup
            ├─ CreatorFeeVault.setup
            └─ deployFee → feeReceiver
```

### 본딩커브 거래

```text
Trader
  └─ YachaRouter.buy/sell
       └─ BondingCurve.buy/sell
            ├─ virtual reserve pricing
            ├─ curve protocol fee
            ├─ optional buy sniping penalty
            ├─ fee → feeReceiver
            └─ reserve update and asset transfer
```

### 졸업

```text
BondingCurve threshold reached
  ├─ graduateFee → feeReceiver
  ├─ token + quote → LPManager
  └─ LPManager.allocate
       └─ V3LiquidityActor
            ├─ position 0 mint
            └─ position 1 mint
```

### 졸업 후 거래

```text
Trader
  └─ YachaRouter
       ├─ router protocol fee on quote side → feeReceiver
       └─ V3SwapAdapter → canonical pool
```

### LP fee 분배

```text
Authorized collector
  └─ LPManager.collect
       ├─ collect position fees
       ├─ launch token → quote swap
       ├─ protocol share → feeReceiver
       └─ creator share → CreatorFeeProcessor
                               └─ CreatorFeeVault
```

## 업그레이드와 router 교체

UUPS implementation 업그레이드는 proxy storage layout을 유지하고 authority permission을 통과해야 한다.

Router를 새 proxy로 교체할 때:

1. 이전 router에서 읽은 5개 dependency가 새 router와 정확히 일치하는지 확인한다.
2. 새 implementation과 proxy를 배포한다.
3. 새 router에 `ROUTER_ROLE`을 부여한다.
4. Lens와 외부 integration을 새 주소로 전환한다.
5. 새 role이 활성화된 뒤 이전 router role을 회수한다.

이전 router의 permissionless 졸업 후 V3 함수는 role 회수만으로 정지되지 않는다. Canonical integration 주소 관리는 별도로 필요하다.

## 주요 보안 불변식

| 영역 | 불변식 |
| --- | --- |
| Registry | 등록 pool, quote, fee tier, factory pool이 일치 |
| Curve | tracked reserve와 실제 호출 balance delta가 일치 |
| Router | call-scoped asset만 사용하고 기존 donation을 sweep하지 않음 |
| Callbacks | 예상 canonical pool만 callback 가능 |
| Graduation | threshold 이후 한 번만 실행 |
| Liquidity | position principal 감소 또는 인출 불가 |
| Collection | token fee 전량 quote 변환, batch atomicity |
| Distribution | per-quote BPS와 실제 recipient balance delta 일치 |
| Allowance | 외부 호출 후 임시 allowance 0 |
| Upgrade | initializer 잠금, storage 호환성, restricted authorization |

## 배포

전체 신규 배포는 `script/deploy/normal/Deploy.s.sol`을 사용한다. 현재 GIWA Sepolia 주소와 트랜잭션, 검증 상태는 루트 [README.md](../README.md)를 기준으로 한다.
