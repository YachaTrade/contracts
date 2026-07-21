# TokenRegistry

**Path:** `src/core/TokenRegistry.sol`
**Pattern:** UUPS Upgradeable
**Inheritance:** `ITokenRegistry`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

Token metadata registry and DexType-to-adapter mapping. Stores legacy pair plus canonical V3 pool/reverse lookup, quote token, DEX type, and fee tier. Registration is gated by the current authority policy rather than a local allowlist.

---

## State Variables

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_tokens` | `mapping(address => TokenInfo)` | private | Token metadata (pair, pool, quoteToken, dexType, feeTier) |
| `_adapters` | `mapping(DexType => IDexAdapter)` | private | DEX type to adapter contract |
| `_tokensByPool` | `mapping(address => address)` | private | Canonical V3 pool to launch-token reverse lookup |

---

## Functions

### ITokenRegistry

| Function | Access | Description |
|----------|--------|-------------|
| `register(token, pair, quoteToken, dexType)` | restricted | Register token metadata (one-time, no re-registration) |
| `registerV3(token, pool, quoteToken, feeTier)` | restricted | Register canonical V3 metadata after code/reverse-lookup validation |
| `getPair(token)` | view | Get DEX pair address for a token |
| `getPool(token)` | view | Get canonical V3 pool for a token |
| `getTokenByPool(pool)` | view | Reverse-resolve launch token for a canonical V3 pool |
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
| `PoolAlreadyRegistered()` | Canonical pool already maps to another token |
| `InvalidPool()` | Pool address has no deployed code |
| `ZeroAddress()` | Required token/pool/quote address is zero |
