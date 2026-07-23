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
| `k` | `uint256` | Constant-product invariant captured at creation |
| `minTokenReserve` | `uint256` | Graduation threshold |
| `initialQuoteReserve` | `uint256` | Initial virtual quote reserve |
| `initialTokenReserve` | `uint256` | Initial virtual token reserve |
| `createdAtBlock` | `uint64` | Creation block number (anti-sniping index = `block.number - createdAtBlock`) |
| `graduated` | `bool` | Whether graduated |
| `version` | `CurveVersion` | V1 |
| `dexType` | `ITokenRegistry.DexType` | Registered DEX type; current launches require Uniswap V3 |
| `pair` | `address` | Canonical V3 pool address |
| `graduateFee` | `uint256` | Quote-denominated graduation fee captured for the curve |

### VaultAllocation — Vault allocation for token creation

| Field | Type | Purpose |
|-------|------|---------|
| `vault` | `address` | Singleton vault address registered in VaultRegistry |
| `bps` | `uint16` | Basis points allocation (> 0) |
| `setupData` | `bytes` | Vault-specific setup data |

### CreateTokenParams — Token creation parameters

| Field | Type | Purpose |
|-------|------|---------|
| `name` | `string` | Token name |
| `symbol` | `string` | Token symbol |
| `tokenURI` | `string` | Token metadata URI |
| `quoteToken` | `address` | Quote token address |
| `vaults` | `VaultAllocation[]` | Vault allocations (max 5, bps sum = 10000) |
| `salt` | `bytes32` | CREATE2 salt |
| `dexType` | `ITokenRegistry.DexType` | DEX type selection; current launches require Uniswap V3 |
| `creator` | `address` | Token creator |
| `buyQuoteAmount` | `uint256` | Explicit optional initial-buy quote amount |

> `sum(vaults[i].bps) == 10000` is required. Maximum 5 vaults.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `create(CreateTokenParams)` payable | `(address token, uint256 tokenOut)` | Create token and optionally execute the explicit initial buy |
| `buy(to, token, quoteIn)` | `uint256 tokenOut` | Pull and execute an exact quote-input curve buy |
| `sell(to, token, tokenIn)` | `uint256 quoteOut` | Pull and execute an exact token-input curve sell |
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
| `Create` | `creator, token, pair, quoteToken, name, symbol, tokenURI, virtualQuoteReserve, virtualTokenReserve, minTokenReserve` |
| `Buy` | `address indexed token, address indexed buyer, uint256 quoteIn, uint256 tokenOut` |
| `Sell` | `address indexed token, address indexed seller, uint256 tokenIn, uint256 quoteOut` |
| `Graduate` | `address indexed token, address indexed pair` |
| `SnipingPenalty` | `address indexed token, address indexed buyer, uint256 snipingFee, uint256 penaltyBps` |
| `Sync` | `token, realQuoteReserve, realTokenReserve, virtualQuoteReserve, virtualTokenReserve` |
| `ModuleUpdate` | `bytes32 indexed moduleId, address indexed module` |
| `Halt` | `bool halted` |

## Errors

| Error | Description |
|-------|-------------|
| `TokenNotFound()` | Token not registered |
| `AlreadyGraduated()` | Already graduated |
| `InvalidKValue()` | Invalid K value |
| `ProtocolHalted()` | Protocol halted |
| `UnsupportedVersion()` | Curve version is unsupported |
| `ZeroModule()` | Module address is zero |
| `ModuleAlreadySet(bytes32)` | Module ID is already configured |
| `InsufficientTokenOut()` | Initial buy returned no tokens |
| `DuplicateVault()` | Vault appears more than once in allocations |
