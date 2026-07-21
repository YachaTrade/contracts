# V3SwapAdapter

**Path:** `src/adapters/V3SwapAdapter.sol`
**Pattern:** Non-upgradeable contract with immutable factory and registry dependencies

`V3SwapAdapter` executes single-pool exact-input and exact-output swaps against the canonical Uniswap V3 pool registered for a launch token. It charges no Router protocol fee, has no privileged withdrawal API, and pulls the actual callback amount directly from the caller to the pool.

## Constructor and getters

```solidity
constructor(address factoryAddress, address tokenRegistryAddress)
function factory() external view returns (address)
function tokenRegistry() external view returns (address)
```

Both constructor arguments must contain code. The addresses are immutable.

## Swap parameters

| Struct | Fields |
|---|---|
| `ExactInputParams` | `address token`, `address tokenIn`, `uint256 amountIn`, `uint256 amountOutMin`, `address recipient`, `uint160 sqrtPriceLimitX96`, `uint256 deadline` |
| `ExactOutputParams` | `address token`, `address tokenIn`, `uint256 amountOut`, `uint256 amountInMax`, `address recipient`, `uint160 sqrtPriceLimitX96`, `uint256 deadline` |

`token` is the launch token used to resolve `TokenRegistry.TokenInfo`. `tokenIn` must be either that launch token or its registered quote token. The other asset becomes `tokenOut`.

## Functions

| Function | Returns | Behavior |
|---|---|---|
| `exactInput(ExactInputParams params)` | `(uint256 amountIn, uint256 amountOut)` | Swaps up to `params.amountIn`. Price-limit partial fills are valid when actual output satisfies `amountOutMin`. Returns actual input consumed and output received. |
| `exactOutput(ExactOutputParams params)` | `(uint256 amountIn, uint256 amountOut)` | Requests exactly `params.amountOut`, bounded by `amountInMax`. Any partial output reverts. |
| `uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes data)` | none | Canonical V3 callback. It is callable only while one authenticated adapter swap is active. |

The caller must approve the adapter for the possible input. The adapter does not receive the output: the pool sends it directly to `recipient`. Direct calls are fee-free at the Router layer, though the canonical pool still applies its configured Uniswap V3 LP fee.

## Canonical-pool checks

Before the swap and again in the callback, the adapter requires:

- `TokenInfo.dexType == UniswapV3`;
- `pair == pool` and the pool contains code;
- launch and quote tokens match sorted `token0`/`token1`;
- the pool fee matches the registered `feeTier`;
- `pool.factory()` matches the immutable factory;
- `factory.getPool(token, quoteToken, feeTier)` returns the same pool;
- `TokenRegistry.getTokenByPool(pool)` returns the same launch token.

Changing any of those relationships during the call makes the transaction revert.

## Callback and accounting defenses

Each swap writes one active context containing the pool, payer, input/output assets, maximum input, and a hash of nonce-bound callback data. The callback validates the caller and data first, re-resolves canonical metadata, accepts exactly one positive owed delta, and requires the amount owed to be at most the stored maximum.

The context is deleted before `safeTransferFrom(payer, pool, amountOwed)`. This makes replay fail even during the same pool call. A separate reentrancy flag prevents nested `exactInput` or `exactOutput` calls.

After the pool returns, the adapter requires:

- the callback consumed the active context;
- the returned input/output deltas have the expected signs;
- payer input decreased by exactly `amountIn`;
- recipient output increased by exactly `amountOut`.

These balance-delta checks reject fee-on-transfer, surcharge, and rebasing behavior. Tokens donated to the adapter are not used for settlement or refunds.

## Storage

| Storage | Slot(s) | Purpose |
|---|---:|---|
| `_activeSwap` | 0–5 | Ephemeral authenticated callback context. |
| `_swapNonce` | 6 | Binds callback data to the current swap. |
| `_entered` | 7 | Local non-reentrancy flag. |

The factory and registry are immutables in bytecode, not storage slots.

## Errors

- Input and bounds: `ExpiredDeadline`, `InvalidAmountIn`, `InvalidAmountOut`, `InvalidPriceLimit`, `InvalidRecipient`, `InsufficientOutput`, `ExcessiveCallbackAmount`.
- Registry and pool: `InvalidFactory`, `InvalidRegistry`, `InvalidPool`, `InvalidTokenIn`.
- Callback lifecycle: `NoActiveSwap`, `InvalidCallback`, `CallbackNotConsumed`, `ReentrantCall`.
- Token accounting: `InvalidBalanceDelta`.

## Related

- [IGiwaRouter](../interfaces/IGiwaRouter.md)
- [GiwaRouter](../router/GiwaRouter.md)
- [Protocol flow](../../../PROTOCOL_FLOW.md)
