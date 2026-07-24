# LPManager

**Path:** `src/core/LPManager.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `ILPManager`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

LPManager는 졸업 시 생성한 영구 Uniswap V3 launch position을 관리한다. 직접적인 pool 상호작용은 `V3LiquidityActor`에 위임하고, 수집한 launch-token 수수료는 `V3SwapAdapter`를 통해 등록된 quote token으로 스왑한다. 최종 quote 수수료는 protocol fee receiver와 `CreatorFeeProcessor`에 배분한다.

LP principal을 제거하는 entrypoint는 없다. 과거 adapter 기반 `addLiquidity`, `claimFees`는 항상 revert한다.

---

## State

| Variable | Purpose |
|----------|---------|
| `_tokenRegistry` | token, quote, pool, fee tier의 canonical registry |
| `v3Factory` | canonical Uniswap V3 factory |
| `v3LiquidityActor` | LPManager가 제어하는 직접 V3 position owner |
| `_pools` | launch token별 저장된 pool metadata |
| `_entered` | 재진입 방지 상태 |
| `creatorFeeProcessor` | creator 측 quote 배분 processor |
| `v3SwapAdapter` | launch-token 수수료를 quote로 바꾸는 swap adapter |

---

## Current Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager, tokenRegistry, creatorFeeProcessor, v3SwapAdapter)` | initializer | proxy 설정 및 dependency binding 검증 |
| `setV3LiquidityActor(actor, factory)` | restricted, one-time | canonical V3 actor와 factory 연결 |
| `allocate(params)` | restricted, non-reentrant | 영구 quote/launch-token V3 position 생성 |
| `increaseLiquidity(token, tokenAmount, quoteAmount)` | restricted, non-reentrant | 기존 영구 position에 자산 추가 |
| `collect(tokens)` | restricted, non-reentrant | 중복 없는 token batch의 LP fee 수집, quote 통일, 분할 및 배분 |
| `getPositions(token)` | view | 두 V3 position의 key, range, liquidity 반환 |
| `callStaticGetAccumulatedFees(token)` | view | collect 전 raw quote-token/launch-token 수수료 반환 |
| `calculateBondingTick(params, quoteIsToken0, tickSpacing)` | pure | contract-v3 호환 bonding range boundary 계산 |
| `getPair(token)` | view | 등록된 canonical pool 반환 |
| `feeReceiver()` | view | 현재 ProtocolManager fee receiver 반환 |

`addLiquidity`, `claimFees`는 `LegacyLiquidityDisabled`로 revert한다. `getLiquidity`는 interface 호환 목적으로만 남아 있으며 0을 반환한다.

---

## Graduation Allocation

```text
BondingCurve._graduate()
  -> LPManager.allocate(params)
     -> canonical pool 및 contract-v3 tick math 검증
     -> 호출 범위 input만 V3LiquidityActor에 approve
     -> quote-side 영구 position mint
     -> launch-token-side 영구 position mint
     -> donation을 sweep하지 않고 미사용 input 정산
     -> PoolData 저장
     -> Allocate(token, pool, quoteAmount, tokenAmount, timestamp) emit
```

---

## Fee Collection

```text
LPManager.collect(tokens)
  -> 빈 batch 또는 중복 token 거부
  -> V3LiquidityActor.collectFees(pool)
  -> token/quote balance delta 정확성 검증
  -> launch-token 수수료 전량을 quote로 swap
  -> quoteAmount = directQuoteFee + swappedQuote
  -> ProtocolManager에서 quote별 protocol 비율 조회
  -> protocol 지분을 feeReceiver로 전송
  -> 나머지를 CreatorFeeProcessor를 통해 배분
  -> LPManager 잔액이 진입 시점 snapshot으로 복구됐는지 검증
  -> Collect(token, pool, quoteAmount, timestamp) emit
```

`Collect.quoteAmount`는 해당 호출이 실제 배분한 최종 quote 기준 총액이다. 스왑 전 raw 수수료는 `callStaticGetAccumulatedFees`로 계속 조회할 수 있다.

---

## Events

```solidity
event Allocate(
    address indexed token,
    address indexed pool,
    uint256 quoteAmount,
    uint256 tokenAmount,
    uint256 timestamp
);

event Collect(
    address indexed token,
    address indexed pool,
    uint256 quoteAmount,
    uint256 timestamp
);
```

---

## Errors

| Error | Description |
|-------|-------------|
| `InvalidFactory()` | actor, adapter 또는 canonical factory binding 오류 |
| `InvalidPool()` | 저장된 pool이 없거나 registry의 live metadata 불일치 |
| `InvalidConfig()` | dependency 또는 quote config 오류 |
| `InvalidBatch()` | collect batch가 비어 있음 |
| `DuplicateToken(token)` | collect batch에 동일 token 중복 |
| `UnauthorizedCaller()` | 재진입 실행 시도 |
| `BalanceDelta()` | 외부 전송, swap 또는 배분의 balance delta 불일치 |
| `LegacyLiquidityDisabled()` | 제거된 V2/adapter liquidity entrypoint 호출 |
