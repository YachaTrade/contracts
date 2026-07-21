# ITokenRegistry

**Path:** `src/interfaces/ITokenRegistry.sol`
**Type:** Interface

Token metadata registry interface. Stores legacy pair and canonical V3 pool metadata, reverse pool lookup, quote token, DEX type, fee tier, and the retained DexType-to-adapter registry.

---

## Enums

### DexType

```solidity
enum DexType { UniswapV2, UniswapV3, UniswapV4 }
```

---

## Structs

### TokenInfo

```solidity
struct TokenInfo {
    address pair;       // Legacy DEX pair address
    address pool;       // Canonical Uniswap V3 pool
    address quoteToken; // Quote token address
    DexType dexType;    // DEX version
    uint24 feeTier;     // Canonical V3 fee tier
}
```

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `register(token, pair, quoteToken, dexType)` | — | Register token metadata (called by BondingCurve) |
| `registerV3(token, pool, quoteToken, feeTier)` | — | Register canonical V3 metadata and reverse pool mapping |
| `getPair(token)` | `address` | Get DEX pair address |
| `getPool(token)` | `address` | Get canonical V3 pool address |
| `getTokenByPool(pool)` | `address` | Reverse-resolve launch token for a canonical V3 pool |
| `getQuoteToken(token)` | `address` | Get quote token address |
| `getDexType(token)` | `DexType` | Get DEX type |
| `getTokenInfo(token)` | `TokenInfo` | Get full token info |
| `isRegistered(token)` | `bool` | Whether token is registered |
| `getAdapter(dexType)` | `IDexAdapter` | Get adapter for DEX type |
| `setAdapter(dexType, adapter)` | — | Set retained IDexAdapter lane for a DEX type (restricted implementation function) |
