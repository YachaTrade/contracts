# IYachaRouter

**Path:** `src/interfaces/IYachaRouter.sol`
**Type:** Interface

`IYachaRouter` is the user-facing token creation and lifecycle trading interface. It calls `BondingCurve` before graduation and requires canonical Uniswap V3 metadata after graduation. ERC-20 routes support every allowlisted quote token registered for the launch token. Native routes support only the Router's configured wrapped-native token.

For implementation behavior and fee formulas, see [YachaRouter](../router/YachaRouter.md). For the fee-free pool boundary, see [V3SwapAdapter](../adapters/V3SwapAdapter.md).

## Parameter structs

| Struct | Fields |
|---|---|
| `CreateParams` | `string name`, `string symbol`, `string tokenURI`, `address quoteToken`, `IBondingCurve.VaultAllocation[] vaults`, `bytes32 salt`, `ITokenRegistry.DexType dexType`, `uint256 buyQuoteAmount`, `uint256 deadline` |
| `BuyParams` | `uint256 amountIn`, `uint256 amountOutMin`, `address token`, `address to`, `uint256 deadline` |
| `BuyWithNativeParams` | `uint256 amountOutMin`, `address token`, `address to`, `uint256 deadline` |
| `BuyWithPermitParams` | `uint256 amountIn`, `uint256 amountOutMin`, `uint256 amountAllowance`, `address token`, `address to`, `uint256 deadline`, `uint8 v`, `bytes32 r`, `bytes32 s` |
| `SellParams` | `uint256 amountIn`, `uint256 amountOutMin`, `address token`, `address to`, `uint256 deadline` |
| `SellToNativeParams` | `uint256 amountIn`, `uint256 amountOutMin`, `address token`, `address to`, `uint256 deadline` |
| `SellWithPermitParams` | `uint256 amountIn`, `uint256 amountOutMin`, `uint256 amountAllowance`, `address token`, `address to`, `uint256 deadline`, `uint8 v`, `bytes32 r`, `bytes32 s` |
| `SellToNativeWithPermitParams` | `uint256 amountIn`, `uint256 amountOutMin`, `uint256 amountAllowance`, `address token`, `address to`, `uint256 deadline`, `uint8 v`, `bytes32 r`, `bytes32 s` |
| `ExactOutBuyParams` | `uint256 amountInMax`, `uint256 amountOut`, `address token`, `address to`, `uint256 deadline` |
| `ExactOutBuyWithNativeParams` | `uint256 amountOut`, `address token`, `address to`, `uint256 deadline` |
| `ExactOutSellParams` | `uint256 amountInMax`, `uint256 amountOut`, `address token`, `address to`, `uint256 deadline` |
| `ExactOutSellToNativeParams` | `uint256 amountInMax`, `uint256 amountOut`, `address token`, `address to`, `uint256 deadline` |

`amountAllowance` is the signed EIP-2612 allowance. It must be at least `amountIn`. The Router skips `permit` when its existing allowance is already sufficient, which preserves execution if another account submitted the same signature first.

## Token creation

| Function | Mutability | Return | Behavior |
|---|---|---|---|
| `create(CreateParams params)` | nonpayable | `(address token, uint256 tokenOut)` | Pulls `deployFee + buyQuoteAmount` in the selected ERC-20 quote token and calls `BondingCurve.create`. |
| `createWithNative(CreateParams params)` | payable | `(address token, uint256 tokenOut)` | Same operation using native currency. `params.quoteToken` must equal `wrappedNative()`. Excess `msg.value` is refunded. |

The creation flow deploys the Token clone, creates and registers its canonical V3 pool, configures its creator vault allocation, and stores the curve state in one transaction.

## Exact-input trading

| Function | Return | Quote asset |
|---|---|---|
| `buy(BuyParams params)` | `uint256 amountOut` | Registered ERC-20 quote token |
| `buyWithNative(BuyWithNativeParams params)` | `uint256 amountOut` | Native, only for wrapped-native quoted tokens |
| `buyWithPermit(BuyWithPermitParams params)` | `uint256 amountOut` | Registered ERC-20 quote token with EIP-2612 approval |
| `sell(SellParams params)` | `uint256 amountOut` | Registered ERC-20 quote token |
| `sellToNative(SellToNativeParams params)` | `uint256 amountOut` | Native, only for wrapped-native quoted tokens |
| `sellWithPermit(SellWithPermitParams params)` | `uint256 amountOut` | Registered ERC-20 quote token with EIP-2612 approval |
| `sellToNativeWithPermit(SellToNativeWithPermitParams params)` | `uint256 amountOut` | Native with EIP-2612 approval, only for wrapped-native quoted tokens |

`amountOutMin` is authoritative after every Router-level V3 protocol fee. A V3 exact-input swap may stop at its price limit. The function then returns the actual output and refunds the unused call-scoped input.

## Exact-output trading

| Function | Return semantics |
|---|---|
| `exactOutBuy(ExactOutBuyParams params)` | Returns quote-token input used, including the V3 protocol fee. Unused `amountInMax` is refunded. |
| `exactOutBuyWithNative(ExactOutBuyWithNativeParams params)` | Returns native input used, including the V3 protocol fee. Unused `msg.value` is refunded. |
| `exactOutSell(ExactOutSellParams params)` | Returns launch-token input used to deliver `amountOut` quote tokens after the V3 protocol fee. |
| `exactOutSellToNative(ExactOutSellToNativeParams params)` | Returns launch-token input used. Graduated V3 delivers exactly `amountOut` native after the Router fee; the curve branch may deliver at least the requested amount because of curve rounding. |

Graduated V3 exact-output execution rejects partial output. The bonding-curve branch can return at least the requested output because of integer rounding. `amountInMax` remains the hard caller limit.

## Quotes and dependency getters

| Function | Mutability | Description |
|---|---|---|
| `isGraduated(address token)` | view | Reads the BondingCurve lifecycle flag. |
| `getAmountOut(address token, uint256 amountIn, bool isBuy)` | nonpayable | Lifecycle-aware quote. Uses BondingCurve before graduation and QuoterV2 after graduation. |
| `getAmountIn(address token, uint256 amountOut, bool isBuy)` | nonpayable | Lifecycle-aware required-input quote. |
| `getBondingCurveAmountOut(address token, uint256 amountIn, bool isBuy)` | view | BondingCurve-only quote. |
| `getBondingCurveAmountIn(address token, uint256 amountOut, bool isBuy)` | view | BondingCurve-only required-input quote. |
| `getDexAmountOut(address token, uint256 amountIn, bool isBuy)` | nonpayable | Canonical V3 exact-input quote. |
| `getDexAmountIn(address token, uint256 amountOut, bool isBuy)` | nonpayable | Canonical V3 exact-output quote. Reverts when full output cannot be quoted. |
| `bondingCurve()` | view | Configured BondingCurve. |
| `tokenRegistry()` | view | Configured TokenRegistry. |
| `wrappedNative()` | view | Configured WNATIVE-compatible wrapped-native token. |
| `v3SwapAdapter()` | view | Configured canonical V3 adapter. |
| `quoterV2()` | view | Configured QuoterV2. |

QuoterV2 quote entrypoints are intentionally not Solidity `view`: canonical QuoterV2 simulates swaps through revert-based/state-changing execution. Clients should call them with `eth_call`. State-changing trades never call QuoterV2.

## Events

| Event | Meaning |
|---|---|
| `Create(address indexed token, address indexed creator)` | A token was created for the caller. |
| `RouterBuy(address indexed buyer, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated)` | For a graduated buy, `amountIn` includes the Router protocol fee. |
| `RouterSell(address indexed seller, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated)` | For a graduated sell, `amountIn` is launch-token input used and `amountOut` is quote output after the Router protocol fee. |

## Errors

| Error | Condition |
|---|---|
| `ExpiredDeadline()` | `deadline < block.timestamp`. |
| `InvalidAmountIn()` / `InvalidAmountOut()` | Required amount is zero or invalid. |
| `InsufficientOutput()` | Output is below the caller's minimum or requested exact output. |
| `ExcessiveInput()` | Exact-output input exceeds the caller's maximum. |
| `TokenNotFound()` | BondingCurve or registry metadata is missing. |
| `TokenNotGraduated()` | The selected function requires a graduated token. |
| `InvalidNativeQuoteToken()` | A native route's quote token is not `wrappedNative()`. |
| `InvalidRecipient()` | Recipient or fee receiver is invalid. |
| `InvalidAllowance()` | Permit allowance is smaller than the requested input. |
| `InvalidBalanceDelta(token, account, requiredBalance, currentBalance)` | A token transfer did not debit or credit the exact amount. |
| `NativeTransferFailed()` / `UnexpectedNative()` | Native delivery failed, or native currency arrived from an address other than wrapped-native. |
| `InvalidDependency()` | Proxy initializer dependency wiring is missing or inconsistent. |
| `InvalidDexFeeRate()` | The per-quote V3 protocol fee rate is at least 10,000 BPS. |
| `InvalidV3Pool()` | Registry metadata does not resolve to the canonical factory pool. |
| `InvalidV3Quote()` | The registered V3 quote token is not currently allowlisted. |

## Related

- [YachaRouter](../router/YachaRouter.md)
- [V3SwapAdapter](../adapters/V3SwapAdapter.md)
- [Protocol flow](../../../PROTOCOL_FLOW.md)
