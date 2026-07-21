# IBondingCurve

**Path:** `src/interfaces/IBondingCurve.sol`
**Type:** Interface

Public interface for the BondingCurve contract. Defines structs, events, errors, and function signatures.

---

## Enums

```solidity
enum CurveVersion {
    V1  // Initial version: bonding curve + Anti-Sniping
}
```

---

## Structs

### Curve — Per-token bonding curve state

| Field | Type | Purpose |
|-------|------|---------|
| `token` | `address` | Token address |
| `creator` | `address` | Token creator |
| `quoteToken` | `address` | Quote token address |
| `virtualQuoteReserve` | `uint256` | Virtual quote reserve |
| `virtualTokenReserve` | `uint256` | Virtual token reserve |
| `createdAtBlock` | `uint64` | Creation block number (anti-sniping index = `block.number - createdAtBlock`) |
| `graduated` | `bool` | Whether graduated |
| `version` | `CurveVersion` | V1 |
| `dexType` | `ITokenRegistry.DexType` | DEX type (V2/V3/V4) |
| `pair` | `address` | DEX pair address |

### VaultAllocation — Vault allocation for token creation

| Field | Type | Purpose |
|-------|------|---------|
| `implementation` | `address` | Vault implementation address (registered in VaultRegistry) |
| `bps` | `uint16` | Basis points allocation (> 0) |
| `initData` | `bytes` | Vault-specific initialization data |

### CreateTokenParams — Token creation parameters

| Field | Type | Purpose |
|-------|------|---------|
| `name` | `string` | Token name |
| `symbol` | `string` | Token symbol |
| `quoteToken` | `address` | Quote token address |
| `creatorFeeRate` | `uint16` | Creator fee rate (BPS) |
| `vaults` | `VaultAllocation[]` | Vault allocations (max 5, bps sum = 10000) |
| `salt` | `bytes32` | CREATE2 salt |
| `dexType` | `ITokenRegistry.DexType` | DEX type selection (V2/V3/V4) |

> `sum(vaults[i].bps) == 10000` is required. Maximum 5 vaults.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `create(CreateTokenParams)` payable | `address token` | Create token + activate bonding curve |
| `buy(to, token)` | `uint256 tokensOut` | Bonding curve buy (balance-detection) |
| `sell(to, token)` | `uint256 quoteOut` | Bonding curve sell (balance-detection) |
| `getCurve(token)` | `Curve memory` | Query curve information |
| `getQuoteToken(token)` | `address` | Query quote token address |
| `isHalted()` | `bool` | Check halt status |
| `getAmountOut(token, amountIn, isBuy)` | `uint256 amountOut` | Calculate output amount |
| `getAmountIn(token, amountOut, isBuy)` | `uint256 amountIn` | Calculate input amount |
| `getSnipingPenalty(token)` | `uint256 penaltyBps` | Query anti-sniping penalty |
| `setModule(moduleId, module)` | — | Register/replace module |
| `halt(halted)` | — | Emergency halt/resume |

---

## Events

| Event | Parameters |
|-------|------------|
| `TokenCreated` | `address indexed token, address indexed creator, string name` |
| `TokenBuy` | `address indexed token, address indexed buyer, uint256 quoteIn, uint256 tokensOut` |
| `TokenSell` | `address indexed token, address indexed seller, uint256 tokensIn, uint256 quoteOut` |
| `TokenGraduated` | `address indexed token, address indexed pair` |
| `SnipingPenalty` | `address indexed token, address indexed buyer, uint256 penaltyQuote, uint256 penaltyBps` |
| `CurveSync` | `address indexed token, uint256 virtualQuoteReserve, uint256 virtualTokenReserve` |
| `ModuleUpdated` | `bytes32 indexed moduleId, address indexed module` |
| `Halted` | `bool halted` |

## Errors

| Error | Description |
|-------|-------------|
| `TokenNotFound()` | Token not registered |
| `AlreadyGraduated()` | Already graduated |
| `InvalidKValue()` | Invalid K value |
| `ProtocolHalted()` | Protocol halted |
