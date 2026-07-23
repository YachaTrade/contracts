# GIWA Launchpad Product Specification

## Product

GIWA Launchpad creates fixed-supply ERC-20 tokens, trades them on a virtual-reserve bonding curve, and graduates them into canonical Uniswap V3 pools with permanent protocol-owned liquidity.

The default deployment is V3-only. It supports multiple quote tokens, uses WNATIVE for native-value routes, and registers `CreatorFeeVault` as the only creator-revenue destination.

## Lifecycle

### 1. Create

The creator calls `YachaRouter.create()` or `createWithNative()`.

- `BondingCurve` deploys a deterministic EIP-1167 `Token` clone.
- `V3PoolDeployer` creates or validates the canonical factory pool and initializes its graduation-target price.
- `TokenRegistry.registerV3()` records the token, quote token, pool, and V3 fee tier.
- `CreatorFeeProcessor.setup()` records the token's vault allocation.
- `deployFee` is transferred to the current protocol `feeReceiver`.

### 2. Bonding-curve trading

Before graduation, YachaRouter routes buys and sells through BondingCurve.

- The quote token's `curveProtocolFeeRate` is charged.
- The per-block anti-sniping schedule applies only to ordinary buys.
- Creation-time initial buys and sells do not pay the anti-sniping penalty.
- Native routes are allowed only when the token's configured quote token is WNATIVE.
- There is no creator trading fee.

### 3. Graduation

Graduation occurs when the virtual token reserve reaches `minTokenReserve`.

- `graduateFee` is sent to `feeReceiver`.
- BondingCurve transfers the tracked token and quote assets to LPManager.
- LPManager validates the registry metadata and canonical factory pool.
- `V3LiquidityActor` mints the two permanent V3 positions using the contract-v3 range math.
- Unused graduation assets are sent to `feeReceiver`.
- No liquidity-principal withdrawal path is exposed.

### 4. Post-graduation trading

After graduation, YachaRouter routes trades through `V3SwapAdapter` and the registered canonical pool.

- Exact-input and exact-output flows are supported.
- The quote token's `dexProtocolFeeRate` is applied on the quote side.
- Protocol fees are transferred directly to the current `feeReceiver`.
- Uniswap V3 applies the pool's configured fee tier.
- Deadline, slippage, permit, callback-authentication, and native refund checks remain enforced.

### 5. LP-fee collection

An authorized collector calls `LPManager.collect(tokens)`.

For every token:

1. LPManager validates its stored pool against TokenRegistry and the V3 factory.
2. V3LiquidityActor collects fees from both permanent positions.
3. Any launch-token fee is fully swapped to the token's quote asset through the canonical pool.
4. The swapped quote is combined with the directly collected quote fee.
5. `lpFeeProtocolShareBps` is sent to `ProtocolManager.feeReceiver()`.
6. The remainder is passed to `CreatorFeeProcessor.processCreatorFee()`.
7. CreatorFeeProcessor distributes the quote asset to the configured vaults; the default deployment sends 100% of that share to CreatorFeeVault.

Collection is atomic across the input batch. Duplicate tokens, metadata mismatches, partial swaps, unexpected transfer deltas, or failed vault callbacks revert the entire call.

## Fee model

All active fee parameters are stored per quote token in ProtocolManager.

| Stage | Configuration | Destination |
| --- | --- | --- |
| Creation | `deployFee` | `feeReceiver` |
| Curve trade | `curveProtocolFeeRate` | `feeReceiver` |
| Ordinary early buy | `snipingPenaltyTable` | `feeReceiver` |
| Graduation | `graduateFee` | `feeReceiver` |
| Router V3 trade | `dexProtocolFeeRate` | `feeReceiver` |
| V3 pool execution | `v3FeeTier` | Permanent positions |
| LP-fee collection | `lpFeeProtocolShareBps` | Protocol share to `feeReceiver`; remainder to CreatorFeeProcessor |

Creator revenue comes only from the creator share of collected V3 LP fees.

## Multiple quote tokens

Every supported quote token has an independent `QuoteConfig`:

- decimals
- virtual quote reserve
- virtual token reserve
- minimum token reserve
- deployment fee
- graduation fee
- curve protocol fee rate
- post-graduation protocol fee rate
- canonical V3 fee tier
- LP-fee protocol share
- active status

Use `addV3QuoteToken()` and `updateV3QuoteToken()` for atomic lifecycle and V3 configuration. `LPManager.collect()` resolves each launch token's registered quote token independently, so a batch may contain multiple quote assets.

## Components

| Component | Deployment pattern | Responsibility |
| --- | --- | --- |
| `ProtocolManager` | UUPS proxy | Ownership, fee receiver, per-quote settings, anti-sniping, selector permissions |
| `BondingCurve` | UUPS proxy | Creation, curve trading, reserves, graduation |
| `TokenRegistry` | UUPS proxy | Canonical launch-token and V3 pool metadata |
| `V3PoolDeployer` | UUPS proxy | Canonical pool creation and initialization |
| `LPManager` | UUPS proxy | Permanent-liquidity accounting, fee collection, quote split |
| `YachaRouter` | UUPS proxy | User-facing creation, curve routes, V3 routes, permits, native handling |
| `VaultRegistry` | UUPS proxy | Vault implementation registry |
| `CreatorFeeVault` | UUPS proxy | Per-token creator quote balances and claims |
| `CreatorFeeProcessor` | Immutable singleton | Authorized creator-share distribution |
| `V3LiquidityActor` | Immutable singleton | Position custody, mint callbacks, fee collection |
| `V3SwapAdapter` | Immutable singleton | Canonical-pool swaps and callback authentication |
| `Lens` | Immutable integration | Frontend routing and quote facade |
| `TokenInfoLens` | Immutable integration | Token version and quote metadata |
| `Token` | EIP-1167 clone | Fixed-supply ERC-20 with ERC-2612 permit |

## Permissions

ProtocolManager is the Ownable authority for all AccessManaged modules.

- The ProtocolManager owner can call managed functions directly.
- Other operators are granted an exact `(operator, target, selector)` permission.
- BondingCurve uses `DEFAULT_ADMIN_ROLE`, `GUARDIAN_ROLE`, and `ROUTER_ROLE`.
- YachaRouter holds `ROUTER_ROLE` for creation and pre-graduation trades.
- BondingCurve may create pools, register tokens, allocate liquidity, and configure creator vault slots.
- LPManager may invoke `CreatorFeeProcessor.processCreatorFee()`.
- The configured collector may invoke `LPManager.collect()`.
- UUPS upgrades are restricted to the corresponding authority.

Role migration to a replacement router must follow: deploy, validate dependencies, grant the new role, migrate integrations, then revoke the previous role.

## Product invariants

- Every launch token has one canonical registered V3 pool.
- Pool callbacks accept only the expected canonical pool.
- Curve reserve accounting is isolated from donated balances.
- LP principal is never exposed through fee collection.
- Token-side LP fees must be completely converted to quote before distribution.
- Protocol and creator distributions are checked by exact ERC-20 balance deltas.
- Temporary swap and processor allowances are cleared.
- Native value is wrapped only for a WNATIVE-quoted token and excess value is refunded.
- Every state-changing user route enforces deadline and slippage constraints.

## Current deployment

GIWA Sepolia addresses, explorer links, transactions, configuration, verification state, and the staged YachaRouter migration runbook are maintained in [README.md](README.md).

## Validation

The current implementation is covered by unit, integration, invariant, script, and environment-gated fork tests. See [TEST.md](TEST.md) for the exact commands and coverage map.
