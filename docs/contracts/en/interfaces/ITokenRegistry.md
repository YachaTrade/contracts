# ITokenRegistry

**Path:** `src/interfaces/ITokenRegistry.sol`
**Type:** Interface

Token metadata registry interface. Stores token-to-pair/quoteToken/dexType mappings and manages DexType-to-adapter registry.

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
    address pair;       // DEX pair/pool address
    address quoteToken; // Quote token address
    DexType dexType;    // DEX version
}
```

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `register(token, pair, quoteToken, dexType)` | — | Register token metadata (called by BondingCurve) |
| `getPair(token)` | `address` | Get DEX pair address |
| `getQuoteToken(token)` | `address` | Get quote token address |
| `getDexType(token)` | `DexType` | Get DEX type |
| `getTokenInfo(token)` | `TokenInfo` | Get full token info |
| `isRegistered(token)` | `bool` | Whether token is registered |
| `getAdapter(dexType)` | `IDexAdapter` | Get adapter for DEX type |
