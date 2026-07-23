# GIWA Launchpad 프로토콜 흐름

## Phase 0: Quote token 설정

ProtocolManager owner는 지원할 quote asset을 한 번에 등록한다.

```text
ProtocolManager.addV3QuoteToken(
  quoteToken,
  virtualReserve,
  virtualTokenReserve,
  minTokenReserve,
  deployFee,
  graduateFee,
  curveProtocolFeeRate,
  dexProtocolFeeRate,
  v3FeeTier,
  lpFeeProtocolShareBps
)
```

전체 설정은 `updateV3QuoteToken()`, V3 수수료 필드만은 `setV3QuoteConfig()`로 변경한다. `removeQuoteToken()`은 quote를 비활성화하고, 전역 anti-sniping table은 별도 setter로 교체한다.

## Phase 1: 토큰 생성

```text
Creator
  └─ YachaRouter.create(params) / createWithNative(params)
       ├─ deadline, quote token, payment, vault selection 검증
       └─ BondingCurve.create(params)
            ├─ deployFee → ProtocolManager.feeReceiver()
            ├─ Token clone 생성 및 초기화
            ├─ V3PoolDeployer.createPool(token, quoteToken)
            │    ├─ 설정된 V3 fee tier 조회
            │    ├─ canonical factory pool 생성 또는 검증
            │    └─ 졸업 목표 sqrt price로 초기화
            ├─ TokenRegistry.registerV3(token, quote, pool, fee)
            ├─ CreatorFeeProcessor.setup(token, vaultSlots)
            ├─ 각 vault.setup(token, data)
            ├─ curve reserve와 생성 block 저장
            └─ 선택적 initial buy
```

Initial buy는 생성 transaction 안에서 실행되며 anti-sniping penalty를 내지 않는다. Native 생성은 선택한 quote token이 WNATIVE일 때만 허용된다.

## Phase 2A: 본딩커브 매수

```text
Trader
  └─ YachaRouter.buy / buyWithNative / buyWithPermit
       ├─ deadline과 minAmountOut 검증
       ├─ quote pull 또는 wrap
       └─ BondingCurve.buy
            ├─ virtual reserve로 token output 계산
            ├─ curveProtocolFeeRate 부과
            ├─ 일반 buy에 snipingPenaltyAt(blocksElapsed) 적용
            ├─ protocol fee + penalty → feeReceiver
            ├─ tracked reserve 갱신
            └─ token output → recipient
```

Router는 실제 token output을 검증하며, native 초과분도 현재 호출에서 들어온 범위만 환불한다.

## Phase 2B: 본딩커브 매도

```text
Trader
  └─ YachaRouter.sell / sellToNative / permit variants
       ├─ deadline과 minAmountOut 검증
       ├─ token pull
       └─ BondingCurve.sell
            ├─ virtual reserve로 quote output 계산
            ├─ curveProtocolFeeRate 부과
            ├─ protocol fee → feeReceiver
            ├─ tracked reserve 갱신
            └─ quote output → recipient 또는 router unwrap 경로
```

Sell에는 anti-sniping penalty가 없다.

## Phase 3: 졸업

`minTokenReserve`에 도달한 curve transaction 안에서 졸업이 원자적으로 실행된다.

```text
BondingCurve
  ├─ curve를 graduated로 표시
  ├─ graduateFee → feeReceiver
  ├─ tracked token + quote asset → LPManager
  └─ LPManager.allocate(params)
       ├─ TokenRegistry metadata와 factory pool 검증
       ├─ contract-v3 tick과 두 position 금액 계산
       ├─ V3LiquidityActor.allocate(...)
       │    ├─ mint callback 인증
       │    ├─ permanent position 0 mint
       │    └─ permanent position 1 mint
       ├─ pool과 position metadata 저장
       └─ 미사용 졸업 asset → feeReceiver
```

Pool은 token 생성 시 이미 생성·초기화된다. 졸업은 영구 유동성을 배치하고 YachaRouter의 registered V3 route를 활성화한다. Position principal 출금 경로는 없다.

## Phase 4: 졸업 후 V3 거래

```text
Trader
  └─ YachaRouter exact-input 또는 exact-output 함수
       ├─ TokenRegistry metadata 조회
       ├─ graduated canonical V3 token 확인
       ├─ factory pool과 fee tier 검증
       ├─ quote side에 dexProtocolFeeRate 적용
       │    └─ protocol fee → 현재 feeReceiver
       └─ V3SwapAdapter
            ├─ canonical pool에서 실행
            ├─ swap callback 인증
            └─ token/quote balance delta 정산
```

Buy fee는 quote input에서, sell fee는 quote output에서 부과된다. Exact-output 경로는 필요한 quote를 역산해 사용자가 지정한 output을 정확히 맞춘다.

## Phase 5: LP fee 조회와 수집

누구나 현재 수집 가능 fee를 조회할 수 있다.

```text
LPManager.callStaticGetAccumulatedFees(token)
  └─ pool, quoteToken, tokenFee, quoteFee 반환
```

권한 있는 collector가 분배를 실행한다.

```text
LPManager.collect([tokenA, tokenB, ...])
  └─ token별 반복
       ├─ duplicate 거부
       ├─ 저장 pool과 registry/factory 검증
       ├─ V3LiquidityActor.collectFees(pool)
       │    └─ 두 position의 fee-only token0/token1 → LPManager
       ├─ launch-token fee와 direct quote fee 분류
       ├─ V3SwapAdapter.exactInput(token fee → quote)
       │    └─ token fee 전량 사용 확인
       ├─ collectedQuote = direct quote fee + swap output
       ├─ protocolQuote = collectedQuote × lpFeeProtocolShareBps / 10,000
       │    └─ exact transfer → feeReceiver
       └─ creatorQuote = collectedQuote - protocolQuote
            ├─ CreatorFeeProcessor 임시 allowance 설정
            ├─ CreatorFeeProcessor.processCreatorFee(token, quote, amount)
            │    └─ 설정된 vault slot에 분배
            └─ allowance 제거
```

Batch 전체가 원자적이다. 한 token이라도 실패하면 해당 호출의 모든 수집과 분배가 revert된다. LPManager와 Processor의 기존 잔액은 수집액에 포함되지 않는다.

## 수수료 도착지

| 수수료 | 발생 지점 | 도착지 |
| --- | --- | --- |
| `deployFee` | 토큰 생성 | `feeReceiver` |
| `curveProtocolFeeRate` | 커브 buy/sell | `feeReceiver` |
| Anti-sniping penalty | 생성 직후 일반 curve buy | `feeReceiver` |
| `graduateFee` | 졸업 | `feeReceiver` |
| `dexProtocolFeeRate` | YachaRouter V3 거래 | `feeReceiver` |
| `v3FeeTier` | Canonical V3 pool swap | 수집 전까지 permanent position |
| Protocol LP share | `LPManager.collect()` | `feeReceiver` |
| Creator LP share | `LPManager.collect()` | CreatorFeeProcessor → CreatorFeeVault |

생성 및 거래에는 creator fee가 없다.

## 권한 흐름

```text
ProtocolManager owner
  ├─ quote config와 feeReceiver 관리
  ├─ selector별 operator permission 관리
  └─ AccessManaged target 직접 호출 가능

BondingCurve roles
  ├─ DEFAULT_ADMIN_ROLE: module, role, upgrade
  ├─ GUARDIAN_ROLE: halt
  └─ ROUTER_ROLE: create, buy, sell

Selector-authorized edges
  ├─ BondingCurve → V3PoolDeployer.createPool
  ├─ BondingCurve → TokenRegistry.registerV3
  ├─ BondingCurve → LPManager.allocate
  ├─ BondingCurve → CreatorFeeProcessor.setup
  ├─ LPManager → CreatorFeeProcessor.processCreatorFee
  └─ collector → LPManager.collect
```

## 원자성과 balance 규칙

외부 실행이 있는 lifecycle 단계는 checks-effects-interactions, reentrancy guard, 실제 balance delta 검증을 사용한다.

- Transfer delta가 다른 token은 거부한다.
- 기존 donation은 현재 호출 회계에서 제외한다.
- Token fee가 일부만 swap되면 revert한다.
- Vault callback 실패 시 creator 분배 전체가 revert된다.
- Canonical callback 검증으로 임의 pool callback을 차단한다.
- 임시 ERC-20 allowance는 사용 후 0으로 만든다.
- LP fee 수집은 position liquidity를 감소시킬 수 없다.
