# LPVault

**Path:** `src/vault/LPVault.sol`
**Pattern:** UUPS Proxy (Singleton)
**Inheritance:** `IVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

Liquidity injection vault. Deployed once as a singleton and shared across all tokens. Receives quoteToken from CreatorFeeProcessor. During bonding phase, accumulates quoteToken per-token and defers processing. Post-graduation, swaps half to token, adds liquidity to DEX, and burns LP tokens by sending to `0xdead`. Continuously deepens trading liquidity.

---

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BURN_ADDRESS` | `address(0xdead)` | LP tokens sent here are permanently locked |

---

## State (set via initialize)

| Variable | Type | Purpose |
|----------|------|---------|
| `tokenRegistry` | `ITokenRegistry` | TokenRegistry for pair/adapter lookup |
| `creatorFeeProcessor` | `address` | Authorization for afterDeposit calls |

## Per-Token Storage

| Variable | Type | Purpose |
|----------|------|---------|
| `_accumulatedQuote` | `mapping(address token => uint256)` | Per-token accumulated quoteToken balance during bonding phase |

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager_, tokenRegistry_, creatorFeeProcessor_)` | external (initializer) | UUPS initializer |
| `setup(token, data)` | external | No-op. Required by IVault interface but nothing to configure |
| `afterDeposit(token, quoteToken, amount)` | creatorFeeProcessor only | Pre-graduation: accumulate per-token. Post-graduation: swap half + addLiquidity + burn LP |
| `accumulatedQuote(token)` | view | Returns per-token accumulated quoteToken during bonding phase |

---

## Key Logic: afterDeposit

```
CreatorFeeProcessor -> transfer(quoteToken, vault, amount)
CreatorFeeProcessor -> try vault.afterDeposit(token, quoteToken, amount)

Pre-graduation (bonding phase):
  |-- _accumulatedQuote[token] += amount
  +-- return (defer processing)

Post-graduation:
  |-- totalQuote = _accumulatedQuote[token] + amount
  |-- _accumulatedQuote[token] = 0
  |-- halfQuote = totalQuote / 2 (for liquidity)
  |-- swapQuote = totalQuote - halfQuote (for swap, handles odd amounts)
  |-- TokenRegistry -> pair info + adapter
  |-- transfer swapQuote to adapter
  |-- adapter.swap(quoteToken -> token)
  |-- tokenReceived == 0: return
  |-- transfer tokenReceived + halfQuote to adapter
  |-- adapter.addLiquidity(pair, token, quoteToken, ..., BURN_ADDRESS)
  |-- LP minted directly to 0xdead (permanently locked)
  +-- emit Inject
```

LPVault is a singleton shared by many tokens. It tracks per-token accumulated balances (not `balanceOf(this)`) to avoid comingling funds across tokens. Swap and addLiquidity failures cause revert. CreatorFeeProcessor's try/catch around afterDeposit protects the pipeline.

---

## Errors

| Error | Description |
|-------|-------------|
| `NotAuthorized()` | Caller is not creatorFeeProcessor |

## Events

| Event | Parameters |
|-------|------------|
| `Inject` | `address indexed token, uint256 quoteUsed, uint256 tokenUsed, uint256 lpBurned` |
