# IProtocolManager

**Path:** `src/interfaces/IProtocolManager.sol`
**Type:** Interface

Protocol-wide quote configuration and selector-scoped authority interface.

## QuoteConfig

```solidity
struct QuoteConfig {
    uint8 decimals;
    uint256 virtualReserve;
    uint256 virtualTokenReserve;
    uint256 minTokenReserve;
    uint256 deployFee;
    uint256 graduateFee;
    uint16 curveProtocolFeeRate;
    uint16 dexProtocolFeeRate;
    uint24 v3FeeTier;
    uint16 lpFeeProtocolShareBps;
    bool active;
}
```

## Main functions

| Group | Functions |
| --- | --- |
| Authority | `setOperatorPermission`, `isOperatorAllowed`, `canCall` |
| Fee getters | `feeReceiver`, `curveProtocolFeeRate`, `dexProtocolFeeRate`, `deployFee`, `graduateFee`, `v3FeeTier`, `lpFeeProtocolShareBps` |
| Fee admin | `setFeeReceiver`, `setV3QuoteConfig` |
| Anti-sniping | `snipingPenaltyTable`, `snipingPenaltyAt`, `snipingPenaltyTableLength`, `getSnipingPenalty`, `setSnipingPenaltyTable` |
| Quote lifecycle | `addQuoteToken`, `addV3QuoteToken`, `removeQuoteToken`, `updateQuoteToken`, `updateV3QuoteToken` |
| Quote views | `isAllowed`, `getConfig`, `getVirtualReserve`, `getVirtualTokenReserve`, `getMinTokenReserve`, `getDecimals` |

## Events

- `FeeReceiverUpdate`
- `V3QuoteConfigUpdate`
- `SnipingPenaltyTableUpdate`
- `QuoteTokenAdd`
- `QuoteTokenRemove`
- `QuoteTokenUpdate`
- `OperatorPermissionUpdated`

## Errors

- `QuoteTokenNotAllowed`
- `QuoteTokenAlreadyAdded`
- `InvalidFeeTier`
- `InvalidLpFeeShare`
- `ZeroAddress`
