# BurnVault

**Path:** `src/vault/BurnVault.sol`
**Pattern:** UUPS Proxy (Singleton)
**Inheritance:** `IVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

Buyback and burn vault. Deployed once as a singleton UUPS proxy and shared across all tokens. Receives quoteToken from CreatorFeeProcessor, buys token, and sends to `0xdead` for permanent burn. Supports both bonding phase (via GiwaRouter, which caps/refunds clamped buys) and post-graduation (via the registered DEX adapter).

---

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BURN_ADDRESS` | `address(0xdead)` | Permanent burn address (no known private key) |

---

## State (set via initialize)

| Variable | Type | Purpose |
|----------|------|---------|
| `tokenRegistry` | `ITokenRegistry` | TokenRegistry for pair/adapter lookup |
| `creatorFeeProcessor` | `address` | Authorization for afterDeposit calls |
| `bondingCurve` | `IBondingCurve` | BondingCurve for pre-graduation buybacks |

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager_, tokenRegistry_, creatorFeeProcessor_, bondingCurve_, router_)` | external (initializer) | UUPS initializer |
| `setup(token, data)` | external | No-op. Required by IVault interface but nothing to configure |
| `afterDeposit(token, quoteToken, amount)` | creatorFeeProcessor only | Buy token and send to 0xdead. Pre-graduation: GiwaRouter.buy; post-graduation: registered adapter swap |

---

## Key Logic: afterDeposit

```
CreatorFeeProcessor -> transfer(quoteToken, vault, amount)
CreatorFeeProcessor -> vault.afterDeposit(token, quoteToken, amount)
  |-- totalQuote = balanceOf(this)  (uses full balance, not just amount param)
  |-- if totalQuote == 0: return
  |-- if isGraduated:
  |     |-- TokenRegistry.getTokenInfo(token) -> pair, dexType
  |     |-- TokenRegistry.getAdapter(dexType) -> adapter
  |     |-- transfer quoteToken to adapter
  |     +-- adapter.swap(pair, quoteToken, token, totalQuote, this, "")
  |-- else (bonding phase):
  |     |-- approve router
  |     +-- GiwaRouter.buy({amountIn: totalQuote, amountOutMin: 1})
  |-- transfer token -> 0xdead
  +-- emit Burn
```

`afterDeposit` records pending quote, then invokes `executePendingBuyback` through a self-call inside `try/catch`. A swap/buy failure rolls back that self-call but is caught; pending quote remains for a later retry and the outer creator-fee settlement can complete.

---

## Errors

| Error | Description |
|-------|-------------|
| `NotAuthorized()` | Caller is not creatorFeeProcessor |

## Events

| Event | Parameters |
|-------|------------|
| `Burn` | `address indexed token, uint256 quoteIn, uint256 tokenBurned` |
