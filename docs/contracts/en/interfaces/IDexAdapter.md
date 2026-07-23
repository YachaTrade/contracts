# IDexAdapter

**Path:** `src/interfaces/IDexAdapter.sol`
**Type:** Optional external-market adapter interface

`IDexAdapter` is the push-based interface used by optional vault integrations for explicitly configured external markets. The canonical launch path does not use it: YachaRouter uses `IV3SwapAdapter`, and LPManager uses `IV3LiquidityActor` plus `IV3SwapAdapter`.

## Functions

| Function | Description |
| --- | --- |
| `swap(pair, tokenIn, tokenOut, amountIn, to, data)` | Execute a push-funded swap |
| `getAmountOut(pair, tokenIn, amountIn)` | Quote exact input |
| `getAmountIn(pair, tokenOut, amountOut)` | Quote exact output |
| `addLiquidity(pair, tokenA, tokenB, amountA, amountB, to)` | Add push-funded liquidity |
| `removeLiquidity(pair, liquidity, to)` | Remove liquidity |
| `claimableFees(pair, liquidity)` | Preview claimable fees |
| `claimFees(pair, liquidity, to)` | Claim fees |

Current optional implementations are `UniswapV2ExternalAdapter` and `UniswapV3ExternalAdapter`.
