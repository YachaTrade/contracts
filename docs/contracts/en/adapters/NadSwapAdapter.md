# NadSwapAdapter

**Path:** `src/adapters/NadSwapAdapter.sol`
**Pattern:** Stateless (no storage, no proxy)
**Inheritance:** `IDexAdapter`

Thin wrapper around `NadFunPair` (V2 AMM). Delegates all AMM math (`getAmountOut`, `getAmountIn`) to the pair contract and handles token transfers via push pattern. No access control — callers must transfer tokens to the adapter before calling.

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `swap(pair, tokenIn, tokenOut, amountIn, to, data)` | external | Transfer tokenIn to pair, query pair for amountOut, execute swap. `data` passed to pair for flash swap support. |
| `getAmountOut(pair, tokenIn, amountIn)` | view | Delegates to `NadFunPair.getAmountOut` |
| `getAmountIn(pair, tokenOut, amountOut)` | view | Delegates to `NadFunPair.getAmountIn` |
| `addLiquidity(pair, tokenA, tokenB, amountA, amountB, to)` | external | Transfer both tokens to pair, call `pair.mint(to)` |
| `removeLiquidity(pair, liquidity, to)` | external | Transfer LP tokens to pair, call `pair.burn(to)` |
| `claimableFees(pair, liquidity)` | pure | Always reverts `NoClaims` — V2 fees are embedded in reserves |
| `claimFees(pair, liquidity, to)` | pure | Always reverts `NoClaims` — no separate claim mechanism in V2 |

---

## Key Design: Delegation to NadFunPair

Unlike a generic V2 adapter that implements constant-product math internally, NadSwapAdapter delegates all pricing logic to `NadFunPair`:

- `getAmountOut` / `getAmountIn` — direct pass-through to the pair contract
- No internal reserve tracking or fee calculation
- NadFunPair is the single source of truth for fee-aware AMM math

---

## Errors

| Error | Description |
|-------|-------------|
| `NoClaims()` | Reverted by `claimableFees` and `claimFees` — V2 has no separate fee claiming |
