# LPManager

**Path:** `src/core/LPManager.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `ILPManager`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

LPManager manages the permanent Uniswap V3 launch positions created at graduation. It delegates direct pool interactions to `V3LiquidityActor`, swaps collected launch-token fees into the registered quote token through `V3SwapAdapter`, and distributes the resulting quote amount between the protocol fee receiver and `CreatorFeeProcessor`.

LP principal cannot be removed. The legacy adapter-based `addLiquidity` and `claimFees` entrypoints always revert.

---

## State

| Variable | Purpose |
|----------|---------|
| `_tokenRegistry` | Canonical token, quote, pool, and fee-tier registry |
| `v3Factory` | Canonical Uniswap V3 factory |
| `v3LiquidityActor` | Direct V3 position owner controlled by LPManager |
| `_pools` | Stored pool metadata for each launch token |
| `_entered` | Reentrancy guard |
| `creatorFeeProcessor` | Creator-side quote distribution processor |
| `v3SwapAdapter` | Launch-token fee to quote-token swap adapter |

---

## Current Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager, tokenRegistry, creatorFeeProcessor, v3SwapAdapter)` | initializer | Configure the proxy and validate dependency bindings |
| `setV3LiquidityActor(actor, factory)` | restricted, one-time | Bind the canonical direct V3 actor and factory |
| `allocate(params)` | restricted, non-reentrant | Create the permanent quote and launch-token V3 positions |
| `increaseLiquidity(token, tokenAmount, quoteAmount)` | restricted, non-reentrant | Add assets to the existing permanent positions |
| `collect(tokens)` | restricted, non-reentrant | Collect, normalize, split, and distribute LP fees for a unique token batch |
| `getPositions(token)` | view | Return both stored V3 position keys, ranges, and liquidity |
| `callStaticGetAccumulatedFees(token)` | view | Return raw quote-token and launch-token fees before collection |
| `calculateBondingTick(params, quoteIsToken0, tickSpacing)` | pure | Calculate the contract-v3-compatible bonding range boundary |
| `getPair(token)` | view | Return the registered canonical pool |
| `feeReceiver()` | view | Return the current ProtocolManager fee receiver |

`addLiquidity` and `claimFees` revert with `LegacyLiquidityDisabled`. `getLiquidity` is retained only for interface compatibility and returns zero.

---

## Graduation Allocation

```text
BondingCurve._graduate()
  -> LPManager.allocate(params)
     -> validate the canonical pool and contract-v3 tick math
     -> approve V3LiquidityActor for call-scoped inputs
     -> mint the quote-side permanent position
     -> mint the launch-token-side permanent position
     -> settle unused inputs without sweeping donations
     -> store PoolData
     -> emit Allocate(token, pool, quoteAmount, tokenAmount, timestamp)
```

---

## Fee Collection

```text
LPManager.collect(tokens)
  -> reject empty or duplicate-token batches
  -> V3LiquidityActor.collectFees(pool)
  -> verify exact token and quote balance deltas
  -> swap the complete launch-token fee into quote
  -> quoteAmount = directQuoteFee + swappedQuote
  -> read the quote-specific protocol share from ProtocolManager
  -> transfer the protocol share to feeReceiver
  -> transfer the remainder through CreatorFeeProcessor
  -> verify LPManager balances returned to their entry snapshots
  -> emit Collect(token, pool, quoteAmount, timestamp)
```

`Collect.quoteAmount` is the final quote-denominated total distributed by the call. Raw pre-swap amounts remain available through `callStaticGetAccumulatedFees`.

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
| `InvalidFactory()` | Actor, adapter, or canonical factory binding is invalid |
| `InvalidPool()` | Token has no stored pool or live registry metadata differs |
| `InvalidConfig()` | Dependency or quote configuration is invalid |
| `InvalidBatch()` | Collection batch is empty |
| `DuplicateToken(token)` | Collection batch repeats a token |
| `UnauthorizedCaller()` | Reentrant execution was attempted |
| `BalanceDelta()` | An external transfer, swap, or distribution reported an invalid balance delta |
| `LegacyLiquidityDisabled()` | A removed V2/adapter liquidity entrypoint was called |
