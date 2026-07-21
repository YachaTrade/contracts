# IProtocolManager

**Path:** `src/interfaces/IProtocolManager.sol`
**Type:** Interface

Protocol-wide configuration management interface. Centralizes global fees, creator fee settings, anti-sniping parameters, quote token whitelist management, and selector-scoped operator permissions for AccessManaged modules.

---

## Structs

### QuoteConfig

```solidity
struct QuoteConfig {
    uint8 decimals;              // Token decimals (6=USDT, 18=WMON)
    uint256 virtualReserve;      // Initial virtual quote reserve
    uint256 virtualTokenReserve; // Initial virtual token reserve
    uint256 minTokenReserve;     // Graduation threshold (minimum virtualTokenReserve)
    uint256 deployFee;           // Token deploy fee (quote token units)
    uint256 graduateFee;         // Graduation fee (quote token units)
    uint16 curveProtocolFeeRate; // Bonding curve protocol fee (BPS) per quote token
    uint16 dexProtocolFeeRate;   // DEX protocol fee (BPS) per quote token
    uint256 settlementThreshold;  // Creator fee settlement threshold per quote token
    bool active;                 // Whether creation with this quote is allowed
}
```

---

## Function Signatures

### Fee Getters

| Function | Returns | Description |
|----------|---------|-------------|
| `feeReceiver()` | `address` | Protocol fee recipient |
| `curveProtocolFeeRate(quoteToken)` | `uint16` | Bonding curve trading fee (BPS) per quote token |
| `dexProtocolFeeRate(quoteToken)` | `uint16` | DEX protocol fee (BPS) per quote token |
| `deployFee(quoteToken)` | `uint256` | Token deploy fee per quote token |
| `graduateFee(quoteToken)` | `uint256` | Graduation fee per quote token |

### Fee Setters (admin only)

| Function | Description |
|----------|-------------|
| `setFeeReceiver(address)` | Set fee recipient |
### Creator Fee Config

| Function | Returns | Description |
|----------|---------|-------------|
| `isCreatorFeeRateAllowed(rate)` | `bool` | Check if creator fee rate is whitelisted |
| `settlementThreshold(quoteToken)` | `uint256` | Creator fee settlement threshold for a quote token |
| `setAllowedCreatorFeeRates(rates)` | — | Add allowed creator fee rates |
| `removeCreatorFeeRate(rate)` | — | Remove a creator fee rate from allowed list |
| `setSettlementThreshold(quoteToken, threshold)` | — | Set settlement threshold for a quote token |

### Sniping Penalty Config

| Function | Returns | Description |
|----------|---------|-------------|
| `snipingPenaltyTable()` | `uint256[]` | Full per-block penalty table (BPS) |
| `snipingPenaltyAt(uint256 blocksElapsed)` | `uint256` | Penalty (BPS) at a specific elapsed-block index. Past length → 0 |
| `snipingPenaltyTableLength()` | `uint256` | Length of the penalty table (= sniping window in blocks) |
| `getSnipingPenalty(uint256 createdAtBlock)` | `uint256` | Current penalty in BPS, indexed by `block.number - createdAtBlock` |
| `setSnipingPenaltyTable(uint256[] calldata table)` | — | Replace the table. Each entry ≤ 10000 BPS. Empty → disable |

### Operator Permission Management

| Function | Returns | Description |
|----------|---------|-------------|
| `setOperatorPermission(operator, target, selector, allowed)` | — | Grant/revoke selector-scoped operator permission for an AccessManaged target |
| `isOperatorAllowed(operator, target, selector)` | `bool` | Check selector-scoped operator permission |

### Quote Token Management

| Function | Returns | Description |
|----------|---------|-------------|
| `addQuoteToken(token, virtualReserve, virtualTokenReserve, minTokenReserve, deployFee, graduateFee, curveProtocolFeeRate, dexProtocolFeeRate, settlementThreshold)` | — | Register new quote token |
| `removeQuoteToken(token)` | — | Deactivate quote token |
| `updateQuoteToken(token, virtualReserve, virtualTokenReserve, minTokenReserve, deployFee, graduateFee, curveProtocolFeeRate, dexProtocolFeeRate, settlementThreshold)` | — | Update quote token config |
| `isAllowed(token)` | `bool` | Whether quote token is active |
| `getConfig(token)` | `QuoteConfig` | Full config for quote token |
| `getVirtualReserve(token)` | `uint256` | Virtual quote reserve |
| `getVirtualTokenReserve(token)` | `uint256` | Virtual token reserve |
| `getMinTokenReserve(token)` | `uint256` | Graduation threshold |
| `getDecimals(token)` | `uint8` | Token decimals |

---

## Events

| Event | Description |
|-------|-------------|
| `FeeReceiverUpdate(address)` | Fee receiver changed |
| `CreatorFeeRatesUpdate(uint16[])` | Creator fee rate whitelist changed |
| `SettlementThresholdUpdate(address, uint256)` | Quote token settlement threshold changed |
| `SnipingPenaltyTableUpdate(uint256[] penaltyTable)` | Per-block sniping penalty table replaced |
| `QuoteTokenAdd(address, uint256, uint256, uint256, uint256, uint256, uint16, uint16, uint256)` | New quote token registered |
| `QuoteTokenRemove(address)` | Quote token deactivated |
| `QuoteTokenUpdate(address, uint256, uint256, uint256, uint256, uint256, uint16, uint16, uint256)` | Quote token config updated |
| `GiftSignerUpdate(address, address)` | GiftVault signer changed |
| `OperatorPermissionUpdated(address, address, bytes4, bool)` | Selector-scoped operator permission changed |

## Errors

| Error | Description |
|-------|-------------|
| `QuoteTokenNotAllowed()` | Unregistered quote token used |
| `QuoteTokenAlreadyAdded()` | Duplicate quote token registration |
| `ZeroAddress()` | Zero address provided |
