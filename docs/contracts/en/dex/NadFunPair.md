# NadFunPair

> `src/dex/NadFunPair.sol` — EIP-1167 Clone (deployed by NadFunFactory)

Uniswap V2-style AMM pair with integrated creator + DEX protocol fee collection via FeeCollector. Inherits ERC20PermitUpgradeable (clone-compatible). LP token name/symbol are "NadFun LP" / "NADLP".

## Overview

Each pair holds reserves of two ERC20 tokens and enforces the constant-product (x*y=k) invariant with a 0.25% LP fee. On top of the LP fee, the pair collects `creatorFeeRate + dexProtocolFeeRate` in quoteToken through `FeeCollector`. The fee direction depends on swap direction:

- **Buy** (quote in): creator + DEX protocol fee deducted from input before k-check
- **Sell** (base in): creator + DEX protocol fee deducted from output after AMM calculation

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MINIMUM_LIQUIDITY` | `10^3` | Permanently locked on first mint (sent to `0xdead`) |

## State Variables

| Variable | Type | Description |
|----------|------|-------------|
| `factory` | `address` | Factory that deployed this pair |
| `token0` | `address` | Lower-sorted token |
| `token1` | `address` | Higher-sorted token |
| `feeCollector` | `address` | FeeCollector contract for creator + DEX protocol fee |
| `price0CumulativeLast` | `uint256` | Cumulative price oracle for token0 |
| `price1CumulativeLast` | `uint256` | Cumulative price oracle for token1 |
| `kLast` | `uint256` | Last recorded k (for protocol fee mint) |

## Functions

| Function | Params | Returns | Description |
|----------|--------|---------|-------------|
| `initialize` | `factory_`, `token0_`, `token1_`, `feeCollector_` | — | Called once by factory after clone deployment (`initializer` modifier). Sets factory address, token pair, and fee collector |
| `getReserves` | — | `reserve0`, `reserve1`, `blockTimestampLast` | Current reserves and last update timestamp |
| `mint` | `to` | `uint256 liquidity` | Mint LP tokens proportional to deposited token amounts. Caller must pre-transfer both tokens. Locks `MINIMUM_LIQUIDITY` on first mint |
| `burn` | `to` | `amount0`, `amount1` | Burn LP tokens (transferred to pair) and return underlying tokens to `to` |
| `swap` | `amount0Out`, `amount1Out`, `to`, `data` | — | Execute swap with k-invariant check. Supports flash swaps via `INadFunCallee` callback. Collects protocol fee via FeeCollector |
| `skim` | `to` | — | Transfer excess token balances (above reserves) to `to` |
| `sync` | — | — | Force reserves to match current balances |
| `getAmountOut` | `tokenIn`, `amountIn` | `uint256` | Fee-aware output calculation (includes 0.25% LP fee + creator + DEX protocol fee) |
| `getAmountIn` | `tokenOut`, `amountOut` | `uint256` | Fee-aware reverse calculation for required input |

## Events

| Event | Params | Description |
|-------|--------|-------------|
| `Mint` | `sender` (indexed), `amount0`, `amount1` | Liquidity added |
| `Burn` | `sender` (indexed), `amount0`, `amount1`, `to` (indexed) | Liquidity removed |
| `Swap` | `sender` (indexed), `amount0In`, `amount1In`, `amount0Out`, `amount1Out`, `to` (indexed) | Token swap executed |
| `Sync` | `reserve0`, `reserve1` | Reserves updated |

## Fee Mechanism

NadFunPair is a Uniswap V2-style pair, but its quote helpers are fee-aware. The pair reads `FeeCollector.getFeeConfig(address(this))`, then computes:

| Symbol | Meaning |
|--------|---------|
| `BPS` | `10_000` |
| `LP_FEE_RATE` | `25` (0.25%) |
| `feeRate` | `creatorFeeRate + dexProtocolFeeRate` |
| `quoteToken` | Token used for NadFun creator/protocol fees |

The fee direction is determined by `tokenIn == quoteToken`:

- **Buy** (`quoteToken` in): LP fee + creator/protocol fee are charged on the input side.
- **Sell** (base token in, `quoteToken` out): LP fee is charged on input, creator/protocol fee is charged on the quote output side.

### `getAmountOut(tokenIn, amountIn)`

Buy path:

```text
totalFeeRate = LP_FEE_RATE + feeRate
amountInWithFee = amountIn * (BPS - totalFeeRate)
amountOut = amountInWithFee * reserveOut / (reserveIn * BPS + amountInWithFee)
```

Sell path:

```text
amountInWithLpFee = amountIn * (BPS - LP_FEE_RATE)
grossQuoteOut = amountInWithLpFee * reserveOut / (reserveIn * BPS + amountInWithLpFee)
amountOut = grossQuoteOut - ceil(grossQuoteOut * feeRate / (BPS - LP_FEE_RATE))
```

The sell-side subtraction makes the returned `amountOut` the net quote amount received by the user. During `swap()`, `_collectFee()` transfers the corresponding quote fee to `feeCollector` with:

```text
quoteFee = netQuoteOut * feeRate / (BPS - LP_FEE_RATE - feeRate)
```

So the pair accounts for both the user's net quote output and the protocol/creator quote fee while preserving the LP-fee-adjusted invariant.

### `getAmountIn(tokenOut, amountOut)`

Buy path:

```text
totalFeeRate = LP_FEE_RATE + feeRate
amountIn = ceil(reserveIn * BPS * amountOut / ((BPS - totalFeeRate) * (reserveOut - amountOut)))
```

Sell path:

```text
grossQuoteOut = amountOut
if feeRate > 0:
  grossQuoteOut = ceil(amountOut * (BPS - LP_FEE_RATE) / (BPS - LP_FEE_RATE - feeRate))

amountIn = ceil(reserveIn * BPS * grossQuoteOut / ((BPS - LP_FEE_RATE) * (reserveOut - grossQuoteOut)))
```

For sells, callers pass the desired net quote output as `amountOut`; the pair first converts it into the gross quote output needed before creator/protocol fee, then runs the LP-fee-adjusted reverse AMM calculation.

## Reentrancy Protection

All state-changing functions use a `lock` modifier (manual reentrancy guard via `_unlocked` flag).
