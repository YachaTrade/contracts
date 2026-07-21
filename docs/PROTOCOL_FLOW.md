# Protocol Flow — End-to-End Lifecycle

## Overview

```
Token Creation → Bonding Curve Trading → Graduation → DEX Trading → Fee Settlement → Distribution
```

---

## Phase 1: Token Creation

**Entry:** `NadFunRouter.create(params)` → `BondingCurve.create(params)` [ROUTER_ROLE required]

```
User ──► NadFunRouter.create() ──► BondingCurve.create()  [ROUTER_ROLE]
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
              │      Token.initialize(name, symbol, uri, pair)
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
User → NadFunRouter.create(params{buyQuoteAmount: X})
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
User ──► NadFunRouter.buy()
              │
              ├── quoteToken.transfer(BondingCurve, amount)
              │
              └── BondingCurve.buy(to, token)
                    │
                    ├── 0. Detect quoteAmount from balance delta
                    ├── 1. Protocol fee ──► feeReceiver (quote에서)
                    ├── 2. Anti-sniping penalty ──► feeReceiver
                    ├── 3. Creator fee ──► FeeCollector.collectFee() (quote에서)
                    ├── 4. Effective amount → curve calculation (x·y=k)
                    ├── 5. _totalQuoteReserved += effectiveQuoteIn
                    ├── 6. Token transfer → user (plain ERC20, no creator fee hook)
                    │
                    └── 7. Graduation check:
                          virtualTokenReserve == minTokenReserve → _graduate()
```

### Sell (Token → Quote)

```
User ──► NadFunRouter.sell()
              │
              ├── token.transfer(BondingCurve, amount)
              │
              └── BondingCurve.sell(to, token)
                    │
                    ├── 0. Detect tokenAmount from balance delta
                    ├── 1. Curve calculation (x·y=k)
                    ├── 2. _totalQuoteReserved -= grossQuoteOut
                    ├── 3. Protocol fee ──► feeReceiver
                    ├── 4. Creator fee ──► FeeCollector.collectFee()
                    └── 5. Net quoteOut ──► user
```

---

## Phase 3: Graduation (DEX Migration)

**Trigger:** `virtualTokenReserve == curve.minTokenReserve` (automatic)

```
BondingCurve._graduate()
    │
    ├── 1. curve.graduated = true
    ├── 2. _totalQuoteReserved release
    ├── 3. Graduate fee ──► feeReceiver
    ├── 4. Excess token burn (DEX price = curve price matching)
    │
    ├── 5. LPManager.addLiquidity()
    │       ├── token + quoteToken → LPManager
    │       ├── IDexAdapter.addLiquidity() → NadFunPair.mint()
    │       └── LP tokens held by LPManager as permanent protocol launch liquidity
    │
    └── 6. Token.setIsGraduated()
```

---

## Phase 4: DEX Trading (via NadFunPair)

### Trade Flow

```
User ──► NadFunRouter.buy() / sell()
              │
              ├── Tokens ──► DEX adapter (via TokenRegistry)
              │
              └── adapter.swap() ──► NadFunPair.swap()
                    │
                    ├── FeeCollector.getFeeConfig(pair) 조회
                    │
                    ├── LP fee (0.25%) → stays in reserves
                    │
                    ├── Protocol fee + Creator fee → FeeCollector
                    │     fee = quoteAmount × (creatorFeeRate + dexProtocolFeeRate) / BPS
                    │     transfer(feeCollector, fee)
                    │     FeeCollector.collectFee(pair)  // balance delta, no amount param
                    │
                    ├── k invariant verification
                    │
                    └── remaining tokens/quote → user
```

---

## Phase 5: Fee Settlement & Distribution

**Trigger:** `FeeCollector.accumulatedFee(pair) >= settlementThreshold`

Settlement works in both bonding and post-graduation phases. The `_settling` flag is stored in FeeCollector as `mapping(address pair => bool)`, and BondingCurve returns 0 fees during settling to prevent recursive fee accumulation.

```
FeeCollector.settle(pair)  [restricted authorized settler]
    │
    ├── 1. Check accumulated creator fee >= settlementThreshold
    ├── 2. Set _settling[pair] = true (fee-free mode for vault operations)
    ├── 3. Creator fee ──► CreatorFeeProcessor.processCreatorFee(token, quoteToken, creatorFeeAmount)
    │       │
    │       └── Distribute to singleton vaults by BPS:
    │             for each vault[i]:
    │               ├── amount = creatorFeeAmount × vault[i].bps / BPS
    │               ├── transfer(vault[i], amount)
    │               └── try vault[i].afterDeposit(token, quoteToken, amount)
    │                   (vault behavior depends on graduation phase — see Phase 6)
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
  Bonding phase:        quoteToken → BondingCurve.buy() + burn → 0xdead
  Post-graduation:      quoteToken → NadSwapAdapter swap + burn → 0xdead

GiftVault:
  Bonding phase:        quoteToken → BondingCurve.buy() + burn → 0xdead
  Post-graduation:      quoteToken → NadSwapAdapter swap + burn → 0xdead

LPVault:
  Bonding phase:        early return (accumulate, no action)
  Post-graduation:      quoteToken → swap half to token → addLiquidity → LP → 0xdead

CreatorFeeVault:        quoteToken → direct transfer to recipient (unchanged, phase-independent)
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

---

## Contract Interaction Map

```
                    ┌─────────────┐
                    │    User     │
                    └──────┬──────┘
                           │
                    ┌──────┴──────┐
                    │ NadFunRouter│
                    │ (create/    │
                    │  buy/sell)  │
                    └──┬──────┬───┘
                       │      │
          ┌────────────┘      └────────────┐
          ▼ (pre-graduation)     (post-graduation) ▼
    ┌─────────────┐              ┌──────────────┐
    │BondingCurve │              │NadSwapAdapter │
    │  (create    │              │  (swap)       │
    │   buy/sell  │              └──────┬────────┘
    │  _graduate) │                     │
    └──┬───┬──────┘                     ▼
       │   │                     ┌──────────────┐
       │   │ creator fee         │NadFunPair    │
       │   │     ┌──────────────►│(swap + fee)  │
       │   └────►│               └──────┬───────┘
       │         │                      │ fee
       │         │                      │
       ▼         ▼                      ▼
    ┌─────────────────────────┐
    │    FeeCollector         │
    │  (config + accumulate   │
    │   + settle)             │
    └────┬───────┬────────────┘
         │       │
         │       ▼
         │  ┌─────────────────┐
         │  │  CreatorFeeProcessor   │
         │  │(vault 분배)     │
         │  └────┬────────────┘
         │       │
         │       └──► Singleton Vaults (by BPS):
         │            ├── BurnVault    → buyback & burn
         │            ├── LPVault      → add liquidity & burn LP
         │            └── CreatorFeeVault     → direct transfer
         │
         └──► feeReceiver (protocol fee)

    ┌────────────────┐  ┌──────────┐  ┌──────────────┐
    │ProtocolManager │  │LPManager │  │NadFunFactory │
    │(fee+creatorFee+quote) │  │(LP lock) │  │(pair deploy) │
    └────────────────┘  └──────────┘  └──────────────┘
```

---

## Key Invariants

1. **x·y=k**: `virtualQuoteReserve × virtualTokenReserve ≥ curve.k`
2. **Reserve isolation**: `_totalQuoteReserved` prevents cross-curve theft
3. **Graduation irreversible**: `graduated = true` → curve trading blocked
4. **Permanent graduation LP**: LPManager holds launch LP with no remove-liquidity entrypoint
5. **NadFunPair k invariant**: After fee deduction, `k` must not decrease
6. **Fee collection split ratio**: `creatorFeeRate / (creatorFeeRate + activeProtocolFeeRate)` is preserved during `collectFee()`
7. **Creator fee rate allowlist**: Only 1%/3%/5% (ProtocolManager)
8. **Creator fee is permanent**: No expiration — fees collected indefinitely
9. **Token pair transfer guard**: Transfers to pair address blocked before graduation (prevents reserve corruption from direct token transfers during bonding phase)
