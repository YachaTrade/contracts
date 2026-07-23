# GIWA Launchpad Protocol Flow

## Phase 0: Quote configuration

The ProtocolManager owner registers each supported quote asset atomically:

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

The owner may update the complete configuration with `updateV3QuoteToken()`, change only V3 fee fields with `setV3QuoteConfig()`, deactivate the quote with `removeQuoteToken()`, and replace the global per-block anti-sniping table.

## Phase 1: Token creation

```text
Creator
  └─ YachaRouter.create(params) / createWithNative(params)
       ├─ validate deadline, quote token, payment, and vault selection
       └─ BondingCurve.create(params)
            ├─ charge deployFee → ProtocolManager.feeReceiver()
            ├─ clone and initialize Token
            ├─ V3PoolDeployer.createPool(token, quoteToken)
            │    ├─ resolve configured V3 fee tier
            │    ├─ create or validate canonical factory pool
            │    └─ initialize graduation-target sqrt price
            ├─ TokenRegistry.registerV3(token, quote, pool, fee)
            ├─ CreatorFeeProcessor.setup(token, vaultSlots)
            ├─ each vault.setup(token, data)
            ├─ store curve reserves and creation block
            └─ optional initial buy
```

The initial buy is part of the creation transaction and does not pay the anti-sniping penalty. Native creation is allowed only for WNATIVE as the selected quote token.

## Phase 2A: Curve buy

```text
Trader
  └─ YachaRouter.buy / buyWithNative / buyWithPermit
       ├─ validate deadline and minAmountOut
       ├─ pull or wrap quote
       └─ BondingCurve.buy
            ├─ price token output from virtual reserves
            ├─ charge curveProtocolFeeRate
            ├─ apply snipingPenaltyAt(blocksElapsed) for ordinary buys
            ├─ protocol fee + penalty → feeReceiver
            ├─ update tracked reserves
            └─ token output → recipient
```

The router verifies the actual token output and refunds only call-scoped excess native value.

## Phase 2B: Curve sell

```text
Trader
  └─ YachaRouter.sell / sellToNative / permit variants
       ├─ validate deadline and minAmountOut
       ├─ pull token
       └─ BondingCurve.sell
            ├─ price quote output from virtual reserves
            ├─ charge curveProtocolFeeRate
            ├─ protocol fee → feeReceiver
            ├─ update tracked reserves
            └─ quote output → recipient or router unwrap path
```

Sells do not pay an anti-sniping penalty.

## Phase 3: Graduation

The successful curve trade that reaches `minTokenReserve` triggers graduation atomically.

```text
BondingCurve
  ├─ mark curve graduated
  ├─ charge graduateFee → feeReceiver
  ├─ transfer tracked token + quote assets → LPManager
  └─ LPManager.allocate(params)
       ├─ validate TokenRegistry metadata and factory pool
       ├─ calculate contract-v3 ticks and two-position amounts
       ├─ V3LiquidityActor.allocate(...)
       │    ├─ authenticate mint callbacks
       │    ├─ mint permanent position 0
       │    └─ mint permanent position 1
       ├─ store pool and position metadata
       └─ unused graduation assets → feeReceiver
```

The pool was already created and initialized during token creation. Graduation adds the permanent liquidity and enables YachaRouter's registered V3 route. Position principal has no withdrawal path.

## Phase 4: Post-graduation V3 trading

```text
Trader
  └─ YachaRouter exact-input or exact-output function
       ├─ load TokenRegistry metadata
       ├─ require graduated canonical V3 token
       ├─ validate factory pool and fee tier
       ├─ apply dexProtocolFeeRate on the quote side
       │    └─ protocol fee → current feeReceiver
       └─ V3SwapAdapter
            ├─ execute against canonical pool
            ├─ authenticate swap callback
            └─ settle exact token and quote balance deltas
```

Buy fees are charged from quote input. Sell fees are charged from quote output. Exact-output routes gross up the required quote amount so the user-facing output remains exact.

## Phase 5: LP-fee preview and collection

Anyone may read the current collectable fee estimate:

```text
LPManager.callStaticGetAccumulatedFees(token)
  └─ returns pool, quoteToken, tokenFee, quoteFee
```

An authorized collector performs distribution:

```text
LPManager.collect([tokenA, tokenB, ...])
  └─ for each token
       ├─ reject duplicates
       ├─ validate stored pool against registry and factory
       ├─ V3LiquidityActor.collectFees(pool)
       │    └─ fee-only token0/token1 amounts → LPManager
       ├─ classify launch-token fee and direct quote fee
       ├─ V3SwapAdapter.exactInput(token fee → quote)
       │    └─ require the complete token fee to be consumed
       ├─ collectedQuote = direct quote fee + swap output
       ├─ protocolQuote = collectedQuote × lpFeeProtocolShareBps / 10,000
       │    └─ exact transfer → feeReceiver
       └─ creatorQuote = collectedQuote - protocolQuote
            ├─ temporary allowance to CreatorFeeProcessor
            ├─ CreatorFeeProcessor.processCreatorFee(token, quote, amount)
            │    └─ distribute to configured vault slots
            └─ clear allowance
```

The batch is atomic. A failure for any token reverts every collection and distribution in the call. Pre-existing LPManager and Processor balances are not part of the collected amount.

## Fee destinations

| Fee | Source | Destination |
| --- | --- | --- |
| `deployFee` | Token creation | `feeReceiver` |
| `curveProtocolFeeRate` | Curve buy/sell | `feeReceiver` |
| Anti-sniping penalty | Ordinary early curve buy | `feeReceiver` |
| `graduateFee` | Graduation | `feeReceiver` |
| `dexProtocolFeeRate` | YachaRouter V3 trade | `feeReceiver` |
| `v3FeeTier` | Canonical V3 pool swap | Permanent positions until collection |
| Protocol LP share | `LPManager.collect()` | `feeReceiver` |
| Creator LP share | `LPManager.collect()` | CreatorFeeProcessor → CreatorFeeVault |

There is no creator fee on creation or trading.

## Permission flow

```text
ProtocolManager owner
  ├─ manages quote configs and feeReceiver
  ├─ manages exact operator permissions
  └─ may call AccessManaged targets directly

BondingCurve roles
  ├─ DEFAULT_ADMIN_ROLE: modules, roles, upgrade
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

## Atomicity and balance rules

All lifecycle steps use checks-effects-interactions, reentrancy guards where external execution occurs, and exact balance-delta checks.

- Taxed or otherwise nonstandard transfer deltas are rejected.
- Donations are excluded from call-scoped accounting.
- Partial token-fee swaps are rejected.
- Failed vault callbacks revert creator distribution.
- Canonical callback validation prevents arbitrary pool callbacks.
- Temporary ERC-20 allowances are zeroed after use.
- LP fee collection cannot reduce position liquidity.
