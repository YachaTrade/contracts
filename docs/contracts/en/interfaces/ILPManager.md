# ILPManager

**Path:** `src/interfaces/ILPManager.sol`
**Type:** Interface

LP accounting and delegation interface for LPManager.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `addLiquidity(token, quoteToken, tokenAmount, quoteAmount, dexType, pair)` | `uint256 liquidity` | Add liquidity and track per-caller accounting |
| `claimFees(token)` | `uint256 amount0, uint256 amount1` | Collect LP fees |
| `getPair(token)` | `address` | Get pair address for a token |
| `getLiquidity(token, caller)` | `uint256` | Get caller's LP amount for a token |

---

## Events

| Event | Description |
|-------|-------------|
| `Allocate(token, pair, caller, dexType, tokenIn, quoteIn, liquidity)` | Emitted when liquidity is added |
| `ClaimFee(token, to, dexType, amount0, amount1)` | Emitted when LP fees are claimed |
