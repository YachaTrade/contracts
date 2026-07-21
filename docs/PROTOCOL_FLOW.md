# Protocol Flow — GiwaRouter Runtime and Retained Lifecycle

## Overview

```
Token Creation → Bonding Curve Trading → Graduation → DEX Trading → Fee Settlement → Distribution
```

> **Integration boundary:** `GiwaRouter` and `V3SwapAdapter` implement the current canonical Uniswap V3 user runtime. The default deployment script still wires token creation and graduation to the retained NadFun V2 factory/LPManager path, so it is not an end-to-end V3 lifecycle. V2-graduated metadata is rejected by GiwaRouter's graduated path.

---

## Phase 1: Token Creation

**Entry:** `GiwaRouter.create(params)` → `BondingCurve.create(params)` [ROUTER_ROLE required]

```
User ──► GiwaRouter.create() ──► BondingCurve.create()  [ROUTER_ROLE]
              │
              ├── Deploy fee ──► feeReceiver (quote token, if > 0)
              │
              ├── 1. Clone Token (EIP-1167, plain ERC20)
              ├── 2. NadFunFactory.createPair(token, quoteToken)
              │      + TokenRegistry.register(token, pair, quoteToken)
              ├── 3. FeeCollector.setup(pair, token, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)
              ├── 4. Singleton Vault setup (VaultRegistry에서 등록된 싱글톤 vault 주소 조회)
              │      Each VaultAllocation → vault.setup(token, data)
              │
              ├── 5. Initialize:
              │      Singleton CreatorFeeProcessor.setup(token, vaults[]) (MODULE_CREATOR_FEE_PROCESSOR로 주소 조회)
              │      Token.initialize(name, symbol, uri, bondingCurve, pair)
              │      (1B tokens minted → BondingCurve during Token.initialize)
              │
              └── 6. Init curve state:
                    curve.k = virtualQuoteReserve × virtualTokenReserve
                    curve.creatorFeeRate = creatorFeeRate
                    graduated = false
```

**Creator fee rate:** allowlist validation (1%/3%/5% only, ProtocolManager)

**Note:** `snipingPenaltyTable` (per-block BPS array indexed by `block.number - createdAtBlock`) and per-quote settlement thresholds come from `ProtocolManager`. `FeeCollector` stores per-pair fee config, per-pair accumulated creator fees, per-quote tracked balances, and the transient `_settling` flag.

---

## Phase 1B: Create with Initial Buy

`BondingCurve.create()` is a unified function — if extra quote is detected after deployFee(quoteToken), it automatically executes a sniping-free initial buy.

```
User → GiwaRouter.create(params{buyQuoteAmount: X})
       ├── safeTransferFrom(User → BC, deployFee(quoteToken) + buyQuoteAmount)
       └── BC.create(params{creator: User})  [ROUTER_ROLE required]
            ├── balance detection: totalIn = balance - _totalQuoteReserved
            ├── safeTransfer(feeReceiver, deployFee(quoteToken))
            ├── _create(params, creator=User)
            └── remaining quote → _initialBuy(to=User) — NO sniping penalty
```

---

## Phase 2: Bonding Curve Trading

### Buy (Quote → Token)

```
User ──► GiwaRouter.buy()
              │
              ├── quoteToken.transfer(BondingCurve, amount)
              │
              └── BondingCurve.buy(to, token)
                    │
                    ├── 0. Detect quoteAmount from balance delta
                    ├── 1. Protocol + creator fee → FeeCollector when creatorFee > 0
                    │      └── collectFee forwards protocol; accumulates creator fee
                    │      (if creatorFee == 0, protocol fee goes directly to feeReceiver)
                    ├── 2. Anti-sniping penalty ──► feeReceiver
                    ├── 3. Effective amount → curve calculation (x·y=k)
                    ├── 4. _totalQuoteReserved += effectiveQuoteIn
                    ├── 5. Token transfer → user (plain ERC20, no creator fee hook)
                    │
                    └── 6. Graduation check:
                          virtualTokenReserve == minTokenReserve → _graduate()
```

### Sell (Token → Quote)

```
User ──► GiwaRouter.sell()
              │
              ├── token.transfer(BondingCurve, amount)
              │
              └── BondingCurve.sell(to, token)
                    │
                    ├── 0. Detect tokenAmount from balance delta
                    ├── 1. Curve calculation (x·y=k)
                    ├── 2. _totalQuoteReserved -= grossQuoteOut
                    ├── 3. Protocol + creator fee → FeeCollector when creatorFee > 0
                    │      └── collectFee forwards protocol; accumulates creator fee
                    │      (if creatorFee == 0, protocol fee goes directly to feeReceiver)
                    └── 4. Net quoteOut ──► user
```

---

## Phase 3: Graduation (Current Default Wiring: Legacy V2)

**Trigger:** `virtualTokenReserve == curve.minTokenReserve` (automatic)

```
BondingCurve._graduate()
    │
    ├── 1. curve.graduated = true
    ├── 2. _totalQuoteReserved release
    ├── 3. Graduate fee ──► feeReceiver
    ├── 4. Excess token → feeReceiver (DEX price = curve price matching)
    │
    ├── 5. LPManager.addLiquidity()
    │       ├── token + quoteToken → LPManager
    │       ├── IDexAdapter.addLiquidity() → NadFunPair.mint()
    │       └── LP tokens held by LPManager as permanent protocol launch liquidity
    │
    └── 6. Token.setIsGraduated()
```

---

## Phase 4A: Canonical V3 Trading through GiwaRouter

This runtime applies when the curve is graduated and TokenRegistry metadata is `DexType.UniswapV3` with a canonical factory pool and registered fee tier.

```
User ──► GiwaRouter.buy()/sell()/exactOutBuy()/exactOutSell()
              │
              ├── resolve graduation from BondingCurve.getCurve()
              ├── validate V3 pool/quote/fee metadata from TokenRegistry
              ├── compute pool budget or gross-output target
              └── V3SwapAdapter.exactInput()/exactOutput()
                    ├── recompute canonical factory pool
                    ├── install one nonce-bound callback context
                    ├── pool.swap() → authenticated callback
                    ├── validate deltas/input cap; delete context; pay pool
                    └── verify callback consumption and balance deltas
              ├── reset adapter allowance
              ├── compute actual quote-side dexProtocolFeeRate
              ├── protocol fee → current feeReceiver
              └── output + call-scoped unused input refund → user
```

- Exact-input may partially fill at a non-zero price limit and refunds unused input.
- Exact-output requires the pool to deliver the full requested output.
- Native routes require the token quote to equal configured wrapped-native; `receive()` accepts native only from wrapped-native withdrawal.
- `getDexAmountOut`/`getDexAmountIn` use QuoterV2 and are non-view Solidity calls; clients should execute them with `eth_call`. Swap execution does not depend on QuoterV2.

## Phase 4B: Retained Legacy V2 DEX Trading

### Trade Flow

```
User ──► explicit legacy adapter / NadFunPair
              │
              └── NadSwapAdapter.swap() ──► NadFunPair.swap()
                    │
                    ├── FeeCollector.getFeeConfig(pair) 조회
                    │
                    ├── LP fee (0.25%) → stays in reserves
                    │
                    ├── Protocol fee + Creator fee → FeeCollector
                    │     fee = quoteAmount × (creatorFeeRate + dexProtocolFeeRate) / BPS
                    │     transfer(feeCollector, fee)
                    │     FeeCollector.collectFee(pair, protocolFee, creatorFee)
                    │
                    ├── k invariant verification
                    │
                    └── remaining tokens/quote → user
```

---

## Phase 5: Fee Settlement & Distribution

**Trigger:** `FeeCollector.accumulatedFee(pair) >= settlementThreshold`

This retained creator-fee settlement path works in both bonding and legacy post-graduation phases. Canonical V3 GiwaRouter protocol fees are sent directly to the current feeReceiver and do not enter this creator-fee pipeline. The `_settling` flag is stored in FeeCollector as `mapping(address pair => bool)`, and BondingCurve returns 0 fees during settling to prevent recursive fee accumulation.

```
FeeCollector.settle(pair, minAmountOut)  [restricted authorized settler]
    │
    ├── 1. Check accumulated creator fee >= settlementThreshold
    ├── 2. Set _settling[pair] = true (fee-free mode for vault operations)
    ├── 3. Creator fee ──► CreatorFeeProcessor.processCreatorFee(token, quoteToken, creatorFeeAmount)
    │       │
    │       └── Distribute to singleton vaults by BPS:
    │             for each vault[i]:
    │               ├── amount = creatorFeeAmount × vault[i].bps / BPS
    │               ├── transfer(vault[i], amount)
    │               └── vault[i].afterDeposit(token, quoteToken, amount)
    │                   (failure reverts the entire distribution/settlement transaction)
    │
    └── 4. Set _settling[pair] = false
```

---

## Phase 6: Revenue Distribution

### Singleton Vaults (Composable, Phase-Aware)

Each singleton vault handles its own logic after receiving quoteToken from CreatorFeeProcessor.
Vault behavior differs based on whether the token has graduated:

```
BurnVault:
  Bonding phase:        quoteToken → GiwaRouter.buy() + burn → 0xdead
  Post-graduation:      quoteToken → registered adapter swap + burn → 0xdead

GiftVault:
  Bonding phase:        quoteToken → GiwaRouter.buy() + burn → 0xdead
  Post-graduation:      quoteToken → registered adapter swap + burn → 0xdead

LPVault:
  Bonding phase:        early return (accumulate, no action)
  Post-graduation:      quoteToken → swap half to token → addLiquidity → LP → 0xdead

CreatorFeeVault:        quoteToken → per-token accrual → creator claim as ERC-20 or WMON-unwrapped native (phase-independent)
```

---

## Fee Summary

| Fee | Amount | When | Recipient |
|-----|--------|------|-----------|
| Deploy Fee | per-quote config | Token creation | feeReceiver |
| Curve Protocol Fee | curveProtocolFeeRate | Bonding curve buy/sell | feeReceiver (from quote) |
| Anti-sniping Penalty | Per-block lookup (default: 80/40/20/15/10/10/5% for blocks 0..6, then 0) | Bonding curve buy | feeReceiver |
| Graduate Fee | per-quote config | Graduation | feeReceiver |
| Creator fee (Curve) | 1%/3%/5% | Bonding curve buy/sell | FeeCollector (from quote) |
| LP Fee | 0.25% | NadFunPair swap | Stays in reserves |
| Protocol Fee (DEX) | dexProtocolFeeRate | NadFunPair swap | forwarded immediately by FeeCollector |
| Creator fee (DEX) | 1%/3%/5% | NadFunPair swap | FeeCollector → CreatorFeeProcessor → Vaults |
| GiwaRouter V3 Protocol Fee | dexProtocolFeeRate on quote side | canonical V3 route | current feeReceiver |
| Uniswap V3 Pool Fee | registered pool fee tier | canonical V3 pool swap | pool liquidity position accounting |

---

## Contract Interaction Map

```
User → GiwaRouter
  ├─ pre-graduation → BondingCurve
  │    ├─ anti-sniping penalty → feeReceiver
  │    ├─ protocol + creator fee → FeeCollector (when creator fee enabled)
  │    │    ├─ protocol fee → feeReceiver
  │    │    └─ creator fee → CreatorFeeProcessor → singleton vaults
  │    └─ default graduation → LPManager → retained NadFunPair metadata
  │         └─ GiwaRouter rejects this V2 metadata after graduation
  │
  └─ graduated + registered UniswapV3
       └─ V3SwapAdapter → canonical factory pool
            ├─ authenticated callback pays exact pool input
            └─ GiwaRouter quote-side protocol fee → current feeReceiver

ProtocolManager supplies per-quote curve/V3 fee configuration and selector-scoped authority.
TokenRegistry supplies the graduated pool, quote token, DEX type, and V3 fee tier.
```

---

## Key Invariants

1. **x·y=k**: `virtualQuoteReserve × virtualTokenReserve ≥ curve.k`
2. **Reserve isolation**: `_totalQuoteReserved` prevents cross-curve theft
3. **Graduation irreversible**: `graduated = true` → curve trading blocked
4. **Permanent graduation LP**: LPManager holds launch LP with no remove-liquidity entrypoint
5. **NadFunPair k invariant**: After fee deduction, `k` must not decrease
6. **Explicit fee accounting**: `collectFee(pair, protocolFee, creatorFee)` requires the received balance delta to cover both declared components; any excess is paid to the protocol receiver
7. **Creator fee rate allowlist**: Token creation accepts only rates currently configured by the ProtocolManager owner (the default policy is 1%/3%/5%)
8. **Creator fee is permanent**: No expiration — fees collected indefinitely
9. **Token pair transfer guard**: Transfers to pair address blocked before graduation (prevents reserve corruption from direct token transfers during bonding phase)
10. **Canonical V3 callback**: only the registry/factory-derived active pool and nonce-bound callback data may consume the swap context
11. **Exact-output completeness**: graduated V3 exact-output must deliver the full requested output; partial fill reverts
12. **Call-scoped refunds**: V3 ERC-20/native refunds cannot sweep balances that existed before the call
