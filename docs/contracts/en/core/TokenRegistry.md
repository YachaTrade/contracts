# TokenRegistry

**Path:** `src/core/TokenRegistry.sol`
**Pattern:** UUPS Upgradeable
**Inheritance:** `ITokenRegistry`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

Token metadata registry and DexType-to-adapter mapping. Stores per-token DEX pair, quote token, and DEX type. Registration is gated by the current authority policy rather than a local allowlist.

---

## State Variables

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_tokens` | `mapping(address => TokenInfo)` | private | Token address to metadata (pair, quoteToken, dexType) |
| `_adapters` | `mapping(DexType => IDexAdapter)` | private | DEX type to adapter contract |

---

## Functions

### ITokenRegistry

| Function | Access | Description |
|----------|--------|-------------|
| `register(token, pair, quoteToken, dexType)` | restricted | Register token metadata (one-time, no re-registration) |
| `getPair(token)` | view | Get DEX pair address for a token |
| `getQuoteToken(token)` | view | Get quote token address |
| `getDexType(token)` | view | Get DEX type (V2, V3, V4) |
| `getTokenInfo(token)` | view | Get full TokenInfo struct |
| `isRegistered(token)` | view | Whether token is registered (pair != address(0)) |
| `getAdapter(dexType)` | view | Get adapter contract for a DEX type |

### Admin

| Function | Access | Description |
|----------|--------|-------------|
| `setAdapter(dexType, adapter)` | restricted | Set adapter for a DEX type |
| `_authorizeUpgrade(address)` | restricted | UUPS upgrade authorization |

---

## Errors

| Error | Description |
|-------|-------------|
| `AlreadyRegistered()` | Token is already registered |
