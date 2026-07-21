# INadFunRouter

**Path:** `src/interfaces/INadFunRouter.sol`
**Type:** Interface

Unified router interface for bonding curve + DEX trading. Top-level entry point for frontends. It calls BondingCurve directly before graduation and routes post-graduation swaps through TokenRegistry + IDexAdapter. Provides slippage protection, deadline validation, native token wrapping, and EIP-2612 permit support. Supports both ExactIn and ExactOut trading modes.

---

## Structs

### Create

| Struct | Fields | Description |
|--------|--------|-------------|
| `CreateParams` | name, symbol, quoteToken, creatorFeeRate, vaults[], salt, dexType, buyQuoteAmount, deadline | Token creation (+ optional initial buy if buyQuoteAmount > 0) |

### ExactIn

| Struct | Fields | Description |
|--------|--------|-------------|
| `BuyParams` | token, amountIn, amountOutMin, deadline | ERC20 quote buy |
| `BuyWithNativeParams` | token, amountOutMin, deadline | Native currency buy |
| `BuyWithPermitParams` | token, amountIn, amountOutMin, deadline, v, r, s | Permit buy |
| `SellParams` | token, amountIn, amountOutMin, deadline | ERC20 quote sell |
| `SellToNativeParams` | token, amountIn, amountOutMin, deadline | Native currency sell |
| `SellWithPermitParams` | token, amountIn, amountOutMin, deadline, v, r, s | Permit sell |
| `SellToNativeWithPermitParams` | token, amountIn, amountOutMin, deadline, v, r, s | Permit + native sell |

### ExactOut

| Struct | Fields | Description |
|--------|--------|-------------|
| `ExactOutBuyParams` | token, amountOut, amountInMax, deadline | Exact output buy |
| `ExactOutBuyWithNativeParams` | token, amountOut, deadline | Exact output native buy |
| `ExactOutSellParams` | token, amountInMax, amountOut, deadline | Exact output sell |
| `ExactOutSellToNativeParams` | token, amountInMax, amountOut, deadline | Exact output native sell |

---

## Function Signatures

### Create

| Function | Returns | Description |
|----------|---------|-------------|
| `create(CreateParams)` | `address token, uint256 tokenOut` | Create token with ERC20 quote (optional initial buy) |
| `createWithNative(CreateParams)` | `address token, uint256 tokenOut` | Create token with native currency (optional initial buy) |

### ExactIn Buy

| Function | Returns | Description |
|----------|---------|-------------|
| `buy(BuyParams)` | `uint256 amountOut` | ExactIn buy with ERC20 |
| `buyWithNative(BuyWithNativeParams)` | `uint256 amountOut` | ExactIn buy with native |
| `buyWithPermit(BuyWithPermitParams)` | `uint256 amountOut` | ExactIn buy with permit |

### ExactIn Sell

| Function | Returns | Description |
|----------|---------|-------------|
| `sell(SellParams)` | `uint256 amountOut` | ExactIn sell for ERC20 |
| `sellToNative(SellToNativeParams)` | `uint256 amountOut` | ExactIn sell for native |
| `sellWithPermit(SellWithPermitParams)` | `uint256 amountOut` | ExactIn sell with permit |
| `sellToNativeWithPermit(SellToNativeWithPermitParams)` | `uint256 amountOut` | ExactIn sell for native with permit |

### ExactOut Buy

| Function | Returns | Description |
|----------|---------|-------------|
| `exactOutBuy(ExactOutBuyParams)` | `uint256 amountIn` | ExactOut buy with ERC20 |
| `exactOutBuyWithNative(ExactOutBuyWithNativeParams)` | `uint256 amountIn` | ExactOut buy with native |

### ExactOut Sell

| Function | Returns | Description |
|----------|---------|-------------|
| `exactOutSell(ExactOutSellParams)` | `uint256 amountOut` | ExactOut sell for ERC20 |
| `exactOutSellToNative(ExactOutSellToNativeParams)` | `uint256 amountOut` | ExactOut sell for native |

### Views

| Function | Returns | Description |
|----------|---------|-------------|
| `isGraduated(token)` | `bool` | Whether token has graduated to DEX |
| `getBondingCurveAmountOut(token, amountIn, isBuy)` | `uint256` | Expected output from bonding curve |
| `getBondingCurveAmountIn(token, amountOut, isBuy)` | `uint256` | Required input for bonding curve |
| `getDexAmountOut(token, amountIn, isBuy)` | `uint256` | Expected output from the token's registered DEX adapter |
| `getDexAmountIn(token, amountOut, isBuy)` | `uint256` | Required input from the token's registered DEX adapter |
| `bondingCurve()` | `address` | BondingCurve address |
| `tokenRegistry()` | `address` | TokenRegistry address |
| `wrappedNative()` | `address` | Wrapped native token address |

---

## Events

| Event | Parameters |
|-------|------------|
| `Buy` | `address indexed buyer, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated` |
| `Sell` | `address indexed seller, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated` |
| `Create` | `address indexed token, address indexed creator` |

> The `graduated` flag on Buy/Sell events distinguishes bonding curve trades from DEX trades.

## Errors

| Error | Description |
|-------|-------------|
| `ExpiredDeadline()` | Transaction deadline expired |
| `InvalidAmountIn()` | Zero or invalid input |
| `InvalidAmountOut()` | Zero or invalid output |
| `InsufficientOutput()` | Output below minimum (slippage exceeded) |
| `ExcessiveInput()` | Input exceeds maximum (ExactOut) |
| `TokenNotFound()` | Token not registered in TokenRegistry |
| `NativeTransferFailed()` | Native currency transfer failed |

---

## Known Implementations

| Implementation | Description |
|----------------|-------------|
| `NadFunRouter` | Unified router that calls BondingCurve directly before graduation and IDexAdapter after graduation |
