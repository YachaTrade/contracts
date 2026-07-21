# ProtocolManager

> `src/core/ProtocolManager.sol` — UUPS Proxy, OwnableUpgradeable

Unified protocol configuration contract. Single source of truth for global fees, creator fee settings, sniping penalty config, quote token registry, and centralized operator permissions for AccessManaged modules.

## Responsibilities

| Area | What It Manages |
|------|----------------|
| **Fees** | curveProtocolFeeRate, dexProtocolFeeRate, feeReceiver |
| **Quote-Specific Fees** | deployFee, graduateFee, v3FeeTier, lpFeeProtocolShareBps |
| **Creator Fee Config** | owner-configured allowedCreatorFeeRates, settlementThreshold |
| **Sniping Penalty** | snipingPenaltyTable (per-block BPS lookup) |
| **Quote Tokens** | Per-token config: virtualReserve, virtualTokenReserve, minTokenReserve, decimals |
| **Authority Policy** | target + selector scoped operator permissions for AccessManaged modules |

## State

```
Fee State:
  _feeReceiver          address    Fee recipient
  (deployFee and graduateFee are now per-quote-token — see QuoteConfig)

Creator Fee Config:
  _allowedCreatorFeeRates      mapping(uint16 => bool)   Creator fee rate allowlist (e.g., 100/300/500)
  settlementThreshold is stored per quote token in QuoteConfig

Sniping Penalty Config:
  _snipingPenaltyTable          uint256[]  Per-block penalty table (BPS).
                                           Index = block.number - createdAtBlock. Out-of-range → penalty 0.

Quote Token Registry:
  _configs              mapping(address => QuoteConfig)  Per-quote-token bonding curve params

Operator Permissions:
  _operatorPermissions  mapping(target => operator => selector => bool)
```

## QuoteConfig Struct

```solidity
struct QuoteConfig {
    uint8 decimals;              // ERC20 decimals (auto-detected)
    uint256 virtualReserve;      // Initial virtual quote reserve for bonding curve
    uint256 virtualTokenReserve; // Initial virtual token reserve for bonding curve
    uint256 minTokenReserve;     // Graduation threshold (minimum virtualTokenReserve to trigger)
    uint256 deployFee;           // Token creation fee (in quote token units)
    uint256 graduateFee;         // Graduation fee (in quote token units)
    uint16 curveProtocolFeeRate; // Bonding curve protocol fee rate (BPS)
    uint16 dexProtocolFeeRate;   // DEX protocol fee rate (BPS)
    uint256 settlementThreshold;  // Min creator fee balance before settlement
    uint24 v3FeeTier;             // Canonical Uniswap V3 fee tier
    uint16 lpFeeProtocolShareBps; // Protocol share of collected V3 LP fees
    bool active;                 // Whether this quote token is allowed
}
```

## Functions

### Fee Management

| Function | Access | Description |
|----------|--------|-------------|
| `feeReceiver()` | view | Returns fee recipient address |
| `curveProtocolFeeRate(address)` | view | BondingCurve protocol fee rate (BPS) for a quote token |
| `dexProtocolFeeRate(address)` | view | DEX protocol fee rate (BPS) for a quote token |
| `deployFee(address quoteToken)` | view | Token creation fee for specific quote token |
| `graduateFee(address quoteToken)` | view | Graduation fee for specific quote token |
| `v3FeeTier(address quoteToken)` | view | Canonical V3 fee tier for a quote token |
| `lpFeeProtocolShareBps(address quoteToken)` | view | Protocol share of collected V3 LP fees |
| `setFeeReceiver(address)` | onlyOwner | Set fee recipient |
### Creator Fee Configuration

| Function | Access | Description |
|----------|--------|-------------|
| `isCreatorFeeRateAllowed(uint16)` | view | Check if creator fee rate is in allowlist |
| `settlementThreshold(address quoteToken)` | view | Min creator fee balance for settlement for a quote token |
| `setAllowedCreatorFeeRates(uint16[])` | onlyOwner | Add rates to allowlist (additive) |
| `removeCreatorFeeRate(uint16)` | onlyOwner | Remove rate from allowlist |
| `setSettlementThreshold(address quoteToken, uint256 threshold)` | onlyOwner | Set settlement threshold for a quote token |
| `setV3QuoteConfig(address quoteToken, uint24 feeTier, uint16 lpFeeProtocolShareBps)` | onlyOwner | Set V3 fee tier and LP-fee protocol share |

### Sniping Penalty Configuration

| Function | Access | Description |
|----------|--------|-------------|
| `snipingPenaltyTable()` | view | Returns the full per-block penalty table (BPS array) |
| `snipingPenaltyAt(uint256 blocksElapsed)` | view | Penalty (BPS) at a specific elapsed-block index. Past length → 0 |
| `snipingPenaltyTableLength()` | view | Length of the penalty table (= sniping window in blocks) |
| `getSnipingPenalty(uint256 createdAtBlock)` | view | Current penalty (BPS) for a curve, indexed by `block.number - createdAtBlock` |
| `setSnipingPenaltyTable(uint256[] calldata table)` | onlyOwner | Replace the table. Each entry ≤ 10000 BPS. Empty array disables sniping |

### Factory Management

| Function | Access | Description |
|----------|--------|-------------|
| `setFactoryFeeTo(address factory, address feeTo)` | onlyOwner | Set protocol fee recipient on a NadFunFactory |
| `setFactoryImplementation(address factory, address implementation)` | onlyOwner | Set NadFunPair implementation address on a NadFunFactory |

### Operator Permission Management

| Function | Access | Description |
|----------|--------|-------------|
| `setOperatorPermission(operator, target, selector, allowed)` | onlyOwner | Grant/revoke selector-scoped permission for an operator on an AccessManaged target |
| `isOperatorAllowed(operator, target, selector)` | view | Check whether a selector-scoped operator permission is set |

### Quote Token Management

| Function | Access | Description |
|----------|--------|-------------|
| `addQuoteToken(address, uint256, uint256, uint256, uint256, uint256, uint16, uint16, uint256)` | onlyOwner | Register quote token with virtual reserves, fees, curve/dex protocol fee rates, and settlement threshold |
| `removeQuoteToken(address)` | onlyOwner | Deactivate quote token |
| `updateQuoteToken(address, uint256, uint256, uint256, uint256, uint256, uint16, uint16, uint256)` | onlyOwner | Update active quote token config including curve/dex protocol fee rates and settlement threshold |
| `isAllowed(address)` | view | Check if quote token is active |
| `getConfig(address)` | view | Get full QuoteConfig |
| `getVirtualReserve(address)` | view | Get virtual quote reserve |
| `getVirtualTokenReserve(address)` | view | Get virtual token reserve |
| `getMinTokenReserve(address)` | view | Get graduation threshold |
| `getDecimals(address)` | view | Get token decimals |

## Deployment Configuration

```
initialize(): owner + feeReceiver only
Deploy.s.sol later configures allowedCreatorFeeRates (currently 100/300/500 BPS),
quote tokens, and the sniping penalty table.
settlementThreshold: configured per quote token
snipingPenaltyTable (BPS, index = block.number - createdAtBlock):
  block 0: 8000 (80%)
  block 1: 4000 (40%)
  block 2: 2000 (20%)
  block 3: 1500 (15%)
  block 4: 1000 (10%)
  block 5: 1000 (10%)
  block 6:  500  (5%)
  block 7+:  0  (out of table range)
quote-specific fee rates: set per quote token
```

## Who References ProtocolManager

| Contract | What It Uses |
|----------|-------------|
| `BondingCurve` | All fees, creator fee rate validation, quote token config, feeReceiver, sniping penalty config |
| `TokenRegistry` | authority policy via `setOperatorPermission()` / `canCall()` |
| `LPManager` | authority policy via `setOperatorPermission()` / `canCall()` |
| `GiwaRouter` | `dexProtocolFeeRate(quoteToken)`, `feeReceiver()` and AccessManaged authorization |
| `FeeCollector` | authority via `AccessManaged`, feeReceiver lookup, quote-token settlement thresholds |
| `GiftVault` | `AccessManaged` authority (operator permission for `setReceiver(token, receiver)` selector granted to a trusted off-chain relayer by admin) |
| `NadFunFactory` | `setFactoryFeeTo()`, `setFactoryImplementation()` — factory admin via ProtocolManager |

## Errors

| Error | When |
|-------|------|
| `ZeroAddress()` | Adding quote token with address(0) |
| `QuoteTokenAlreadyAdded()` | Adding already-active quote token |
| `InvalidFeeTier()` | V3 fee tier is invalid |
| `InvalidLpFeeShare()` | V3 LP-fee protocol share exceeds BPS |

## Events

Fee: `FeeReceiverUpdate`, `V3QuoteConfigUpdate`

Creator fee: `CreatorFeeRatesUpdate`, `SettlementThresholdUpdate`

Sniping: `SnipingPenaltyTableUpdate(uint256[] penaltyTable)`

Quote: `QuoteTokenAdd`, `QuoteTokenRemove`, `QuoteTokenUpdate`

Authority: `OperatorPermissionUpdated`
