# NadFunRouter

**Path:** `src/router/NadFunRouter.sol`
**Pattern:** UUPS Upgradeable
**Inheritance:** `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

Unified router for all token trading. Single entry point that directly handles both BondingCurve (pre-graduation) and DEX (post-graduation) trading — no intermediate sub-routers. Native wrapping, fee calculation, and slippage protection are all handled at this single entrypoint.

---

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `IBondingCurve` | Pre-graduation curve state & trading |
| `ITokenRegistry` | Post-graduation pair/adapter lookup |
| `IDexAdapter` | DEX swap execution (per dexType) |
| `IProtocolManager` | Fee rates, fee receiver, deploy fee |
| `IWrappedNative` | Native currency wrapping/unwrapping (WMON) |
| `FixedPointMathLib` | Precise fee calculation (mulDivUp) |
| `BPS` constant | Basis points denominator (10000) |

---

## State Variables

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_bondingCurve` | `IBondingCurve` | private | BondingCurve reference for pre-graduation trades |
| `_tokenRegistry` | `ITokenRegistry` | private | TokenRegistry for post-graduation pair/adapter lookup (slot 1, was `_dexRouter`) |
| `_wrappedNative` | `IWrappedNative` | private | WMON for native currency wrapping/unwrapping |
| `__gap_slot3` | `uint256` | private | Storage gap to preserve UUPS layout (was `_bondingCurveRouter`) |

---

## Functions

### ExactIn Buy

| Function | Description |
|----------|-------------|
| `buy(BuyParams)` | Buy with ERC20 quote token |
| `buyWithNative(BuyWithNativeParams)` | Buy with native currency (auto-wraps) |
| `buyWithPermit(BuyWithPermitParams)` | Buy with EIP-2612 gasless approval |

### ExactIn Sell

| Function | Description |
|----------|-------------|
| `sell(SellParams)` | Sell for ERC20 quote token |
| `sellToNative(SellToNativeParams)` | Sell for native currency (auto-unwraps) |
| `sellWithPermit(SellWithPermitParams)` | Sell with EIP-2612 permit |
| `sellToNativeWithPermit(SellToNativeWithPermitParams)` | Sell for native with permit |

### ExactOut Buy

| Function | Description |
|----------|-------------|
| `exactOutBuy(ExactOutBuyParams)` | Buy exact token amount, refund unused quote |
| `exactOutBuyWithNative(ExactOutBuyWithNativeParams)` | Buy exact tokens with native, refund unused |

### ExactOut Sell

| Function | Description |
|----------|-------------|
| `exactOutSell(ExactOutSellParams)` | Sell for exact quote output, refund unused tokens |
| `exactOutSellToNative(ExactOutSellToNativeParams)` | Sell for exact native output, refund unused tokens |

### Create Functions

| Function | Description |
|----------|-------------|
| `create(CreateParams) returns (address token, uint256 tokenOut)` | Create token (+ initial buy if `buyQuoteAmount > 0`) |
| `createWithNative(CreateParams) payable returns (address token, uint256 tokenOut)` | Same with native MON (wrap -> create -> refund excess) |

**CreateParams:** `name, symbol, tokenURI, quoteToken, creatorFeeRate, vaults, salt, dexType, buyQuoteAmount, deadline`

**Key design:**
- `BondingCurve.create()` requires `ROUTER_ROLE` — NadFunRouter is the only entry point for token creation
- Single unified `create()` function — `buyQuoteAmount > 0` triggers sniping-free initial buy automatically
- NadFunRouter calls BondingCurve directly (not via sub-router)
- `creator: msg.sender` ensures the real user is recorded as token creator
- No slippage protection needed — first buy is atomic (deterministic price)

### Views

| Function | Returns | Description |
|----------|---------|-------------|
| `isGraduated(token)` | `bool` | Whether token has graduated to DEX |
| `getBondingCurveAmountOut(token, amountIn, isBuy)` | `uint256` | Pre-graduation output amount (includes all fees: protocol fee, sniping penalty, creator fee) |
| `getBondingCurveAmountIn(token, amountOut, isBuy)` | `uint256` | Pre-graduation required input (includes all fees) |
| `getDexAmountOut(token, amountIn, isBuy)` | `uint256` | Post-graduation output amount. Reverts with `TokenNotGraduated` if pair not found |
| `getDexAmountIn(token, amountOut, isBuy)` | `uint256` | Post-graduation required input. Reverts with `TokenNotGraduated` if pair not found |
| `bondingCurve()` | `address` | BondingCurve address |
| `tokenRegistry()` | `address` | TokenRegistry address |
| `wrappedNative()` | `address` | WMON address |
| `authority()` | `address` | ProtocolManager address (inherited from AccessManagedUpgradeable) |

### Admin

| Function | Access | Description |
|----------|--------|-------------|
| `_authorizeUpgrade(address)` | restricted | UUPS upgrade authorization |
| `setAuthority(address)` | — | Always reverts (authority is immutable after init) |

---

## Routing Logic

All buy/sell functions check `curve.graduated`:
- **Not graduated**: Executes trade directly against BondingCurve (balance-detection pattern). Internal helpers: `_bondingCurveBuy`, `_bondingCurveSell`, `_bondingCurveExactOutBuy`, `_bondingCurveExactOutSell`.
- **Graduated**: Executes trade directly against the DEX pair via `IDexAdapter` (looked up from `ITokenRegistry`). Internal helpers: `_dexBuy`, `_dexSell`, `_dexExactOutBuy`, `_dexExactOutSell`.

Slippage protection is applied at NadFunRouter level; inner calls pass `minOut=0` / `deadline=block.timestamp`.

---

## Events

| Event | Parameters |
|-------|------------|
| `Buy` | `address indexed buyer, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated` |
| `Sell` | `address indexed seller, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated` |
| `Create` | `address indexed token, address indexed creator` |

## Errors

| Error | Description |
|-------|-------------|
| `ExpiredDeadline()` | Transaction deadline has passed |
| `InvalidAmountIn()` | Zero input amount |
| `InvalidAmountOut()` | Zero output amount |
| `InsufficientOutput()` | Output below minimum (slippage exceeded) |
| `ExcessiveInput()` | Input exceeds maximum (ExactOut) |
| `TokenNotFound()` | Token not registered in BondingCurve |
| `TokenNotGraduated()` | Token has no DEX pair (used in DEX view/swap functions) |
| `NativeTransferFailed()` | Native currency transfer failed |
