# INadFunPair

> `src/dex/interfaces/INadFunPair.sol` — Interface

Interface for the NadFunPair AMM contract. Extends standard Uniswap V2 pair interface with fee-aware quote helpers.

`getAmountOut()` and `getAmountIn()` are the canonical quote interface for NadFunPair swaps. They include the pair's 0.25% LP fee and the NadFun creator/protocol fee logic, so callers should not reuse plain Uniswap V2 library math for routed NadFunPair trades.

## Functions

| Function | Params | Returns | Description |
|----------|--------|---------|-------------|
| `MINIMUM_LIQUIDITY` | — | `uint256` | Minimum locked liquidity constant |
| `factory` | — | `address` | Factory that deployed this pair |
| `token0` | — | `address` | Lower-sorted token address |
| `token1` | — | `address` | Higher-sorted token address |
| `feeCollector` | — | `address` | FeeCollector contract address |
| `getReserves` | — | `reserve0`, `reserve1`, `blockTimestampLast` | Current reserves and timestamp |
| `price0CumulativeLast` | — | `uint256` | Cumulative price for token0 (TWAP oracle) |
| `price1CumulativeLast` | — | `uint256` | Cumulative price for token1 (TWAP oracle) |
| `kLast` | — | `uint256` | Last recorded product of reserves |
| `mint` | `to` | `uint256 liquidity` | Mint LP tokens to `to` |
| `burn` | `to` | `amount0`, `amount1` | Burn LP tokens and return underlying |
| `swap` | `amount0Out`, `amount1Out`, `to`, `data` | — | Execute swap with optional flash callback |
| `skim` | `to` | — | Skim excess balances |
| `sync` | — | — | Force-sync reserves |
| `initialize` | `token0`, `token1`, `feeCollector` | — | One-time initialization by factory |
| `getAmountOut` | `tokenIn`, `amountIn` | `uint256 amountOut` | Fee-aware output calculation (0.25% LP fee + creator + DEX protocol fee) |
| `getAmountIn` | `tokenOut`, `amountOut` | `uint256 amountIn` | Fee-aware input reverse calculation |

## Fee-Aware Quote Rules

Let:

```text
BPS = 10_000
LP_FEE_RATE = 25
feeRate = creatorFeeRate + dexProtocolFeeRate
```

Buy direction is detected by `tokenIn == quoteToken`.

| Direction | User input/output | Fee placement |
|-----------|-------------------|---------------|
| Buy | quote in, base out | LP + creator/protocol fee on input |
| Sell | base in, quote out | LP fee on input, creator/protocol fee on quote output |

For sells, `getAmountOut()` returns the net quote output to the user. `getAmountIn()` accepts the desired net quote output and internally grosses it up before applying the LP-fee reverse AMM calculation.

## Events

| Event | Params | Description |
|-------|--------|-------------|
| `Mint` | `sender` (indexed), `amount0`, `amount1` | Liquidity added |
| `Burn` | `sender` (indexed), `amount0`, `amount1`, `to` (indexed) | Liquidity removed |
| `Swap` | `sender` (indexed), `amount0In`, `amount1In`, `amount0Out`, `amount1Out`, `to` (indexed) | Swap executed |
| `Sync` | `reserve0`, `reserve1` | Reserves updated |
