# ProtocolManager

**Path:** `src/core/ProtocolManager.sol`
**Pattern:** UUPS proxy
**Inheritance:** `IProtocolManager`, `OwnableUpgradeable`

ProtocolManager is the global configuration and AccessManaged authority for the protocol.

## QuoteConfig

Every supported quote token has an independent configuration:

| Field | Purpose |
| --- | --- |
| `decimals` | Quote-token decimals recorded at registration |
| `virtualReserve` | Initial virtual quote reserve |
| `virtualTokenReserve` | Initial virtual launch-token reserve |
| `minTokenReserve` | Graduation threshold |
| `deployFee` | Fixed creation fee |
| `graduateFee` | Fixed graduation fee |
| `curveProtocolFeeRate` | Curve-trade protocol fee in BPS |
| `dexProtocolFeeRate` | YachaRouter V3 protocol fee in BPS |
| `v3FeeTier` | Canonical Uniswap V3 pool fee tier |
| `lpFeeProtocolShareBps` | Protocol share of collected V3 LP fees |
| `active` | Whether new launches may use this quote |

`addV3QuoteToken()` and `updateV3QuoteToken()` set the complete lifecycle and V3 configuration atomically. `setV3QuoteConfig()` changes only the V3 tier and LP split. Removing a quote token marks it inactive without deleting historical metadata.

## Global configuration

- `feeReceiver`: current destination for protocol fees and unused graduation assets
- `snipingPenaltyTable`: per-block buy penalties in BPS
- operator permissions: exact `(operator, target, selector)` grants

## Authority behavior

`canCall(caller, target, selector)` returns immediate permission when:

1. `caller` is the current ProtocolManager owner; or
2. the exact operator permission is enabled.

No target-wide or wildcard permission is inferred.

## Administrative functions

| Function | Access | Purpose |
| --- | --- | --- |
| `setFeeReceiver(receiver)` | owner | Rotate the protocol recipient |
| `addV3QuoteToken(...)` | owner | Add a complete supported quote configuration |
| `updateV3QuoteToken(...)` | owner | Atomically update a complete active quote configuration |
| `setV3QuoteConfig(quote, tier, share)` | owner | Update only V3 tier and LP split |
| `removeQuoteToken(quote)` | owner | Deactivate a quote |
| `setSnipingPenaltyTable(table)` | owner | Replace the complete penalty schedule |
| `setOperatorPermission(operator, target, selector, allowed)` | owner | Grant or revoke one exact call edge |
| `upgradeToAndCall(implementation, data)` | owner | UUPS upgrade |

Fee rates are capped by the contract, the LP share cannot exceed 10,000 BPS, and V3 fee tier must be nonzero. Quote configuration also validates virtual reserves and graduation supply.

## Consumers

- BondingCurve reads curve configuration, fees, receiver, and anti-sniping penalties.
- YachaRouter reads post-graduation protocol fee rates and receiver.
- LPManager reads the V3 fee tier, LP split, and receiver.
- All AccessManaged modules use ProtocolManager as their authority.
- CreatorFeeProcessor checks `canCall()` directly for `setup()` and `processCreatorFee()`.
