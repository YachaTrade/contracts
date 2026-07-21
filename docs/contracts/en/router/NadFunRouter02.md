# NadFunRouter02

**Path:** `src/router/NadFunRouter02.sol`
**Pattern:** UUPS Upgradeable
**Inheritance:** `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

Standalone UniswapV2Router02-compatible periphery for graduated NadFunPairs. Handles liquidity management (add/remove, with or without permit) and fee-aware multi-hop swaps over the NadFun custom AMM. Separated from `NadFunRouter` to stay within the EIP-170 24 KB contract size limit; `NadFunRouter` (bonding-curve lifecycle + buy/sell) is unchanged and remains the sole entry point for pre-graduation trading and token creation.

`WETH()` returns the WMON address. The `...ETH` / `WETH()` naming is kept verbatim for drop-in compatibility with aggregators and SDKs that expect the UniswapV2Router02 ABI (Sushi/PancakeSwap convention).

---

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `INadFunFactory` | Pair lookup via `getPair`; permissionless `createPair` |
| `INadFunPair` | Mint/burn LP; `getAmountOut`/`getAmountIn` fee-aware views |
| `IWrappedNative` | WMON wrapping/unwrapping for `...ETH` functions |
| `NadFunLibrary` | `pairFor` (resolves via `factory.getPair`), `quote`, `getAmountsOut`, `getAmountsIn` |

---

## State Variables

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_factory` | `INadFunFactory` | private | NadFunFactory reference for pair lookup and creation |
| `_wrappedNative` | `IWrappedNative` | private | WMON address; returned by `WETH()` |

---

## Functions

### Initialization

| Function | Description |
|----------|-------------|
| `initialize(protocolManager, factory, wmon)` | Proxy initializer. Sets `_factory` and `_wrappedNative`; wires `AccessManagedUpgradeable` to `protocolManager` |

### Liquidity

#### Create Pair

| Function | Description |
|----------|-------------|
| `createPair(tokenA, tokenB) returns (address pair)` | Permissionless pair creation via `factory.createPair`. Does not require any role or multisig; callable by anyone |

#### Add Liquidity

| Function | Description |
|----------|-------------|
| `addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline) returns (amountA, amountB, liquidity)` | Add ERC20/ERC20 liquidity. Computes optimal amounts against current reserves, enforces minimums, mints LP tokens to `to` |
| `addLiquidityETH(token, amountTokenDesired, amountTokenMin, amountETHMin, to, deadline) returns (amountToken, amountETH, liquidity)` payable | Add token/native liquidity. Wraps `msg.value` to WMON, computes optimal split, refunds unused native |

#### Remove Liquidity

| Function | Description |
|----------|-------------|
| `removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline) returns (amountA, amountB)` | Burn LP tokens, withdraw ERC20/ERC20. Enforces output minimums |
| `removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline) returns (amountToken, amountETH)` | Burn LP tokens, withdraw token + native. Unwraps WMON to native before forwarding |
| `removeLiquidityWithPermit(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline, approveMax, v, r, s)` | `removeLiquidity` preceded by EIP-2612 permit approval on the LP token |
| `removeLiquidityETHWithPermit(token, liquidity, amountTokenMin, amountETHMin, to, deadline, approveMax, v, r, s)` | `removeLiquidityETH` preceded by LP token permit |
| `removeLiquidityETHSupportingFeeOnTransferTokens(token, liquidity, amountTokenMin, amountETHMin, to, deadline) returns (amountETH)` | Remove liquidity where the base token may apply a fee-on-transfer; measures actual received balance |
| `removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(token, liquidity, amountTokenMin, amountETHMin, to, deadline, approveMax, v, r, s)` | Permit variant of the above |

**Pre-graduation guard:** NadFun's `Token.sol` blocks transfers to the pair address before graduation (`TransferToPairBeforeGraduation` error). Adding liquidity to a pre-graduation pair therefore reverts at the token level — no separate router-level check is needed.

### Swap

All swap functions accept a `path[]` of token addresses for multi-hop routing. Each hop is routed through the NadFunPair for that token pair.

**Fee-awareness:** `getAmountsOut`/`getAmountsIn` delegate per-hop to `NadFunPair.getAmountOut`/`getAmountIn`, which account for LP fee, protocol fee, and creator fee (buy/sell asymmetric). This is necessary: using a flat 0.3% approximation would compute amounts that do not satisfy the pair's k-invariant check, causing the swap to revert.

#### Exact-In

| Function | Description |
|----------|-------------|
| `swapExactTokensForTokens(amountIn, amountOutMin, path[], to, deadline) returns (amounts[])` | Swap exact ERC20 input along `path`; enforce minimum output |
| `swapExactETHForTokens(amountOutMin, path[], to, deadline) returns (amounts[])` payable | Wrap native → WMON, swap exact native input along `path` |
| `swapExactTokensForETH(amountIn, amountOutMin, path[], to, deadline) returns (amounts[])` | Swap exact ERC20 input along `path`; unwrap final WMON to native |

#### Exact-Out

| Function | Description |
|----------|-------------|
| `swapTokensForExactTokens(amountOut, amountInMax, path[], to, deadline) returns (amounts[])` | Compute required input for exact ERC20 output; enforce maximum input cap |
| `swapETHForExactTokens(amountOut, amountInMax, path[], to, deadline) returns (amounts[])` payable | Compute required native for exact token output; refund unused native |
| `swapTokensForExactETH(amountOut, amountInMax, path[], to, deadline) returns (amounts[])` | Compute required token input for exact native output; unwrap WMON on delivery |

#### Fee-on-Transfer Variants

| Function | Description |
|----------|-------------|
| `swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, amountOutMin, path[], to, deadline)` | Exact-in swap; measures actual received balance at each hop to accommodate fee-on-transfer tokens |
| `swapExactETHForTokensSupportingFeeOnTransferTokens(amountOutMin, path[], to, deadline)` payable | Native exact-in variant; same balance-delta measurement |
| `swapExactTokensForETHSupportingFeeOnTransferTokens(amountIn, amountOutMin, path[], to, deadline)` | Token exact-in → native; unwraps WMON using actual received balance |

### Views

| Function | Returns | Description |
|----------|---------|-------------|
| `factory()` | `address` | NadFunFactory address |
| `WETH()` | `address` | WMON address (named `WETH` for Router02 ABI compatibility) |
| `quote(amountA, reserveA, reserveB)` | `uint256 amountB` | LP-ratio quote: `amountB = amountA * reserveB / reserveA`. Pure arithmetic, no fee |
| `getAmountOut(amountIn, reserveIn, reserveOut)` | `uint256 amountOut` | LP-fee-only output estimate (0.25% LP fee, no protocol/creator fees). **Caveat:** actual output from `NadFunPair.swap` deducts additional protocol and creator fees; use `getAmountsOut` for end-to-end routing quotes |
| `getAmountIn(amountOut, reserveIn, reserveOut)` | `uint256 amountIn` | LP-fee-only input estimate. Same caveat as `getAmountOut` |
| `getAmountsOut(amountIn, path[])` | `uint256[] amounts` | Fee-aware output amounts along a multi-hop path; delegates per-hop to `NadFunPair.getAmountOut` |
| `getAmountsIn(amountOut, path[])` | `uint256[] amounts` | Fee-aware required inputs along a multi-hop path; delegates per-hop to `NadFunPair.getAmountIn` |

### Admin

| Function | Access | Description |
|----------|--------|-------------|
| `setFactory(address)` | restricted | Update the NadFunFactory reference. Emits `FactoryUpdated` |
| `_authorizeUpgrade(address)` | restricted | UUPS upgrade authorization |

---

## NadFunLibrary

**Path:** `src/libraries/NadFunLibrary.sol`

Helper library used by `NadFunRouter02`. Key difference from the standard UniswapV2Library: `pairFor` resolves the pair address via `INadFunFactory.getPair(tokenA, tokenB)` rather than recomputing the CREATE2 init-code hash. This is required because NadFunPair is deployed as an EIP-1167 minimal proxy clone, for which the CREATE2 init-code-hash trick is invalid.

| Function | Description |
|----------|-------------|
| `pairFor(factory, tokenA, tokenB)` | Returns pair address via `factory.getPair`; reverts if pair does not exist |
| `getReserves(factory, tokenA, tokenB)` | Returns `(reserveA, reserveB)` sorted to match `(tokenA, tokenB)` ordering |
| `quote(amountA, reserveA, reserveB)` | Pure LP-ratio quote |
| `getAmountsOut(factory, amountIn, path[])` | Delegates to `NadFunPair.getAmountOut` at each hop |
| `getAmountsIn(factory, amountOut, path[])` | Delegates to `NadFunPair.getAmountIn` at each hop |

---

## Events

| Event | Parameters |
|-------|------------|
| `AddLiquidity` | `address indexed pair, address indexed to, uint256 amountA, uint256 amountB, uint256 liquidity` |
| `RemoveLiquidity` | `address indexed pair, address indexed to, uint256 amountA, uint256 amountB, uint256 liquidity` |
| `Swap` | `address indexed pair, address indexed to, uint256 amountIn, uint256 amountOut` |
| `FactoryUpdated` | `address indexed oldFactory, address indexed newFactory` |

## Errors

| Error | Description |
|-------|-------------|
| `ExpiredDeadline()` | Transaction deadline has passed |
| `InvalidPath()` | Path has fewer than 2 tokens |
| `InsufficientOutputAmount()` | Output below minimum (slippage exceeded) |
| `ExcessiveInputAmount()` | Input exceeds maximum (exact-out) |
| `InsufficientLiquidity()` | Pair has insufficient reserves |
| `InsufficientAAmount()` | Token A output below minimum on liquidity removal |
| `InsufficientBAmount()` | Token B output below minimum on liquidity removal |
| `NativeTransferFailed()` | Native currency refund or delivery failed |
