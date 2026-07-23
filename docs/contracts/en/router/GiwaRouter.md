# GiwaRouter

**Path:** `src/router/GiwaRouter.sol`
**Pattern:** UUPS proxy
**Inheritance:** `IGiwaRouter`, `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

`GiwaRouter` is the user-facing creation and lifecycle trading entrypoint. Before graduation it delegates price and execution to `BondingCurve`. After graduation it accepts only active, canonical Uniswap V3 metadata and executes through `V3SwapAdapter`.

See [IGiwaRouter](../interfaces/IGiwaRouter.md) for every parameter and function signature. See [V3SwapAdapter](../adapters/V3SwapAdapter.md) for callback authentication and pool accounting.

## Initialization and dependencies

```solidity
initialize(
    address protocolManager,
    address bondingCurve,
    address tokenRegistry,
    address wrappedNative,
    address v3SwapAdapter,
    address quoterV2
)
```

All six addresses must contain code. The adapter's registry must equal `tokenRegistry`, and the QuoterV2 factory must equal the adapter factory. The constructor disables initialization on the implementation contract.

| Getter | Purpose |
|---|---|
| `authority()` | ProtocolManager used for access policy, active quote checks, per-quote V3 fee rates, and the current fee receiver. |
| `bondingCurve()` | Pre-graduation state, execution, and lifecycle status. |
| `tokenRegistry()` | Quote token, pool, reverse-pool mapping, DEX type, and V3 fee tier. |
| `wrappedNative()` | The only quote token eligible for native routes. |
| `v3SwapAdapter()` | Canonical V3 execution dependency. |
| `quoterV2()` | Post-graduation quote dependency only. |

`setAuthority` always reverts. UUPS upgrades use the fixed ProtocolManager authority and its `restricted` policy.

## Lifecycle routing

```text
GiwaRouter
├─ curve.graduated == false
│  └─ BondingCurve quote and execution
└─ curve.graduated == true
   ├─ validate TokenRegistry metadata and active quote token
   ├─ validate factory.getPool(token, quote, feeTier)
   └─ V3SwapAdapter exactInput / exactOutput
```

Graduated metadata must have `DexType.UniswapV3`, `pair == pool`, a nonzero fee tier, the correct reverse registry entry, and the canonical factory pool. Legacy V2 metadata is rejected with `InvalidV3Pool`.

ERC-20 routes work with any active registered quote token. Native routes call `_requireNativeQuoteToken` before permit or asset movement and require the token's registered quote to equal `wrappedNative()`.

## Four graduated V3 fee flows

The Router reads `ProtocolManager.dexProtocolFeeRate(quoteToken)` and `feeReceiver()` at execution time. The rate is denominated in BPS and must be less than `10_000`. The fee is always paid in the registered quote token and rounded up with `FullMath.mulDivRoundingUp`.

This Router-level V3 protocol fee is not applied to the BondingCurve branch. BondingCurve retains its separate curve fee, anti-sniping, and current creator-fee accounting. A direct `V3SwapAdapter` call also bypasses the Router fee.

### Exact-input buy

The caller's `amountIn` is the maximum quote spend including the protocol fee:

```text
protocolFeeMax = ceil(amountIn × rate / 10_000)
poolQuoteInMax = amountIn - protocolFeeMax
```

The adapter may consume less than `poolQuoteInMax` at the price limit. In that case the Router prorates the already-rounded maximum fee once:

```text
protocolFee = ceil(protocolFeeMax × poolQuoteIn / poolQuoteInMax)
quoteSpent   = poolQuoteIn + protocolFee
refund       = amountIn - quoteSpent
```

The return value is launch-token output. The `Buy` event's `amountIn` is `quoteSpent`.

### Exact-input sell

The adapter may consume less than the launch-token maximum and returns the actual quote output before the Router fee:

```text
protocolFee = ceil(quoteOutBeforeProtocolFee × rate / 10_000)
quoteOut    = quoteOutBeforeProtocolFee - protocolFee
```

Unused launch tokens are refunded. `amountOutMin` applies to `quoteOut`, after the fee. The return value is the net quote output.

### Exact-output buy

The adapter returns the pool quote input needed for the exact launch-token output. The Router grosses that input up:

```text
quoteInWithProtocolFee = ceil(poolQuoteIn × 10_000 / (10_000 - rate))
protocolFee            = quoteInWithProtocolFee - poolQuoteIn
```

The gross input must be at most `amountInMax`; the remainder is refunded. The function and `Buy` event return/report gross quote input including the fee.

### Exact-output sell

The requested `amountOut` is the exact quote amount the recipient receives after fees. The Router asks the pool for a gross quote output:

```text
quoteOutBeforeProtocolFee = ceil(amountOut × 10_000 / (10_000 - rate))
protocolFee               = quoteOutBeforeProtocolFee - amountOut
```

The adapter must deliver the full gross output. The function returns actual launch-token input, not quote output, and refunds unused `amountInMax`.

## Partial fills, refunds, and allowances

Exact-input V3 calls use the direction's extreme valid price limit. If available liquidity ends at that limit, the actual adapter input/output is authoritative and the Router refunds unused call input.

Exact-output calls require the requested output exactly. Adapter partial output reverts. Router `amountInMax` and `amountOutMin` checks remain authoritative.

The Router pulls only the current call's maximum, approves the adapter only for the pool maximum, and resets that approval to zero after the swap. Exact balance-debit and balance-credit checks reject fee-on-transfer, surcharge, rebasing, or short-credit behavior. Pre-existing Router and adapter token donations are not swept.

## Native routes

- Native creation and buys wrap only the current call's routed quote amount.
- Graduated native buys initially wrap `msg.value`, then unwrap only the calculated call refund.
- Native sells receive WNATIVE at the Router, pay the quote-token fee in WNATIVE, unwrap only the call's net output, and send it to `to`.
- `receive()` accepts native currency only from the configured wrapped-native contract during `withdraw`.
- A failed unwrap/refund/recipient transfer reverts the complete swap, fee payment, permit, and token movement.

Existing Router WNATIVE or native balances are excluded from refund equations.

## Quotes

BondingCurve-only quotes are `view`. Lifecycle-aware and V3-only quotes are nonpayable because canonical QuoterV2 is not a Solidity view contract. Frontends should simulate them with `eth_call`.

V3 exact-input quotes apply the same buy-input or sell-output fee direction as execution. Exact-output buy quotes gross up the Quoter's pool input; exact-output sell quotes gross up the desired net quote output before calling QuoterV2. Exact-output quotes use `sqrtPriceLimitX96 = 0` so QuoterV2 rejects an unfillable partial output. State-changing trade functions never call QuoterV2.

## Storage and size

| Slot | Field |
|---:|---|
| 0 | `_bondingCurve` |
| 1 | `_tokenRegistry` |
| 2 | `_wrappedNative` |
| 3 | `_v3SwapAdapter` |
| 4 | `_quoterV2` |

OpenZeppelin upgradeable base state uses namespaced storage. The current deployed runtime is 23,959 bytes, leaving 617 bytes below the EIP-170 limit of 24,576 bytes. Any implementation change must rerun the size regression and inspect storage compatibility.

## Deployment status

The fresh deployment script deploys V3SwapAdapter, canonical QuoterV2, and a six-argument GiwaRouter proxy. It removes Router02 and grants only GiwaRouter the BondingCurve router role.

It does **not** yet create an end-to-end canonical-V3 launch lifecycle. `Deploy.s.sol` still wires `BondingCurve` to `NadFunFactory`, registers tokens through the legacy `register` path, and uses the current LPManager, whose graduation allocation supports only `DexType.UniswapV2`. It also does not deploy/configure the repository's separate `V3PoolDeployer` lifecycle. Tokens produced by that retained graph have legacy V2 metadata and GiwaRouter intentionally rejects their graduated path.

Treat the script as Router-facing V3 dependency wiring plus a retained legacy creation/graduation graph. A production V3 launch needs separate completion and validation of pool creation, `registerV3`, V3 liquidity allocation, and per-quote `setV3QuoteConfig` configuration. No legacy NadFunRouter proxy can be upgraded to GiwaRouter; `UpgradeGiwaRouter.s.sol` is only for an already-deployed GiwaRouter proxy.

## Related

- [IGiwaRouter](../interfaces/IGiwaRouter.md)
- [V3SwapAdapter](../adapters/V3SwapAdapter.md)
- [Architecture](../../../ARCHITECTURE.md)
- [Protocol flow](../../../PROTOCOL_FLOW.md)
