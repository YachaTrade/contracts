# BondingCurveLibrary

> `src/libraries/BondingCurveLibrary.sol` — Pure Library (stateless)

Stateless constant-product AMM math library. Provides input/output calculations for any constant-product curve given the invariant `k` and reserve values.

## Design

BondingCurveLibrary contains no storage and all functions are `pure`. The BondingCurve contract stores `virtualQuoteReserve` and `virtualTokenReserve` as state, and passes them to this library for swap calculations.

The library works with any constant-product curve, not just the bonding curve specifically. Ceiling division is used to ensure the protocol never loses value due to rounding in favor of the trader.

## Constants

| Name | Value | Description |
|------|-------|-------------|
| *(none)* | — | No constants; `k` is passed as a parameter (set at curve creation from `QuoteConfig`) |

## Functions

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `getAmountOut(amountIn, k, reserveIn, reserveOut)` | `uint256, uint256, uint256, uint256` | `uint256` | Output amount for a given input (rounds down via ceil on denominator) |
| `getAmountIn(amountOut, k, reserveIn, reserveOut)` | `uint256, uint256, uint256, uint256` | `uint256` | Required input amount for a desired output (rounds up) |
| `ceilDiv(a, b)` | `uint256, uint256` | `uint256` | Ceiling division helper |

### getAmountOut

Calculates how many output tokens are received for a given input amount:

```
amountOut = reserveOut - ceil(k / (reserveIn + amountIn))
```

Uses ceiling division on `k / (reserveIn + amountIn)` so that `amountOut` is slightly less, protecting the protocol.

### getAmountIn

Calculates how many input tokens are required to receive a specific output amount:

```
newReserveIn = ceil(k / (reserveOut - amountOut))
amountIn = newReserveIn - reserveIn
```

Uses ceiling division so that `amountIn` is slightly more, protecting the protocol.

### ceilDiv

```
ceilDiv(a, b) = (a + b - 1) / b
```

Standard ceiling division. Rounds up instead of truncating.

## Usage in BondingCurve

```solidity
// Buy: user sends quoteToken, receives token
uint256 tokenOut = BondingCurveLibrary.getAmountOut(
    quoteAmountIn, k, virtualQuoteReserve, virtualTokenReserve
);

// Sell: user sends token, receives quoteToken
uint256 quoteOut = BondingCurveLibrary.getAmountOut(
    tokenAmountIn, k, virtualTokenReserve, virtualQuoteReserve
);
```
