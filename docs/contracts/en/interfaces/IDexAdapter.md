# IDexAdapter

**Path:** `src/interfaces/IDexAdapter.sol`
**Type:** Interface

Pluggable DEX adapter interface. Each DEX version (V2, V3, V4) implements this interface. Core contracts call the adapter without knowing DEX-specific details. Uses the Strategy Pattern — registered in TokenRegistry and selected dynamically by DexType.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `swap(pair, tokenIn, tokenOut, amountIn, to, data)` | `uint256 amountOut` | Execute swap (caller must pre-transfer tokenIn). `data` enables flash swaps via INadFunCallee callback. |
| `getAmountOut(pair, tokenIn, amountIn)` | `uint256 amountOut` | Expected output for given input (view) |
| `getAmountIn(pair, tokenOut, amountOut)` | `uint256 amountIn` | Required input for desired output (view) |
| `addLiquidity(pair, tokenA, tokenB, amountA, amountB, to)` | `uint256 liquidity` | Add liquidity (caller must pre-transfer both tokens) |
| `removeLiquidity(pair, liquidity, to)` | `uint256 amount0, uint256 amount1` | Remove liquidity |
| `claimableFees(pair, liquidity)` | `uint256 amount0, uint256 amount1` | Get claimable fee amounts (view) |
| `claimFees(pair, liquidity, to)` | `uint256 amount0, uint256 amount1` | Claim accumulated trading fees |

---

## Known Implementations

| Implementation | Description |
|----------------|-------------|
| `NadSwapAdapter` | NadFunPair thin wrapper — delegates AMM views to pair, handles swap execution and liquidity |

---

## Consumers

Used by retained legacy paths: BondingCurve/LPManager graduation and vaults such as BurnVault/LPVault/GiftVault. GiwaRouter's canonical V3 user path uses the separate `IV3SwapAdapter` interface instead.
