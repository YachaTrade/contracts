# FeeCollector

**Path:** `src/core/FeeCollector.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IFeeCollector`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

Central fee management contract with per-pair storage. Collects trading fees and settles accumulated creator fees through CreatorFeeProcessor.

BondingCurve calls `setup()` on token creation to register a pair's fee config. On each trade, the pair (or BondingCurve) transfers quoteToken to this contract and calls `collectFee()`. The active protocol fee share is forwarded immediately to the ProtocolManager feeReceiver, while creator fees are accumulated per pair. `settle()` is restricted to authorized settlers and runs once the accumulated creator fee meets the quote token's threshold.

---

## State Variables

### Private (set via initialize)

| Variable | Type | Purpose |
|----------|------|---------|
| `_creatorFeeProcessor` | `ICreatorFeeProcessorV2` | V2 CreatorFeeProcessor for settlement |
| `_bondingCurve` | `address` | Authorized caller for `setup()` |

### Per-Pair Storage

| Variable | Type | Purpose |
|----------|------|---------|
| `_configs` | `mapping(address => FeeConfig)` | Fee config per pair (uses the unified `IFeeCollector.FeeConfig` struct) |
| `_accumulatedFees` | `mapping(address => uint256)` | Accumulated creator fees per pair |
| `_trackedBalance` | `mapping(address => uint256)` | Per-quoteToken tracked balance for balance delta calculation |
| `_settling` | `mapping(address pair => bool)` | True during settle — vault buybacks are fee-free |

### FeeConfig (Struct)

Defined once in `IFeeCollector` and reused here for storage. There is no separate internal struct anymore.

```solidity
struct FeeConfig {
    address baseToken;       // passed to CreatorFeeProcessor on settlement
    address quoteToken;      // fee asset
    uint16 creatorFeeRate;   // creator fee rate (BPS)
    uint16 curveProtocolFeeRate; // bonding curve protocol fee rate (BPS)
    uint16 dexProtocolFeeRate;   // dex protocol fee rate (BPS)
}
```

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager_, creatorFeeProcessor_, bondingCurve_)` | external (initializer) | Proxy initializer; wires authority plus core addresses |
| `setup(pair, baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)` | external (onlyBondingCurve) | Register per-pair fee config; reverts if already configured |
| `getFeeConfig(pair)` | view | Returns the full `FeeConfig` for a pair |
| `collectFee(pair)` | external | Balance delta fee collection: msg.sender must be pair or bondingCurve. Uses curve or dex protocol fee rate depending on caller, forwards protocol share immediately, accumulates creator share. |
| `settle(pair)` | external (restricted) | Settle accumulated creator fees to CreatorFeeProcessor if above threshold. Works in both bonding and post-graduation phases. |
| `isSettling(pair)` | view | Whether pair is currently in settling state |
| `accumulatedFee(pair)` | view | Accumulated creator fee for a pair |
| `settlementThreshold(pair)` | view | Current settlement threshold for the pair's quote token |
| `isSettleable(pair)` | view | Whether accumulated fee meets threshold |
| `setCurveProtocolFeeRate(pair, rate)` | external (restricted) | Update bonding curve protocol fee rate for a pair |
| `setDexProtocolFeeRate(pair, rate)` | external (restricted) | Update dex protocol fee rate for a pair |

---

## Key Logic: collectFee Flow

```
Caller (pair or bondingCurve) transfers quoteToken to FeeCollector, then calls collectFee(pair)

1. Auth check: msg.sender must be pair itself or bondingCurve (revert NotAuthorized otherwise)
2. Look up pair config (revert if not configured)
3. Determine amount via balance delta: currentBalance - _trackedBalance[quoteToken]
4. Pick active protocol fee rate:
   - bondingCurve caller -> curveProtocolFeeRate
   - pair caller -> dexProtocolFeeRate
5. Split amount by rate ratio (using mulDivUp for protocol share):
   protocolAmount = amount * activeProtocolFeeRate / (creatorFeeRate + activeProtocolFeeRate)
   creatorFeeAmount = amount - protocolAmount
6. Transfer protocolAmount to feeReceiver immediately
7. Accumulate creatorFeeAmount in _accumulatedFees[pair]
8. Update _trackedBalance[quoteToken] to current balance
```

## Key Logic: settle Flow

```
Authorized settler calls settle(pair)

1. Check _accumulatedFees[pair] >= settlementThreshold (silent return if below)
2. Zero out _accumulatedFees[pair] and decrement tracked balance (CEI pattern)
3. Mark pair as settling (_settling[pair] = true)
4. Approve and call creatorFeeProcessor.processCreatorFee(baseToken, quoteToken, amount)
5. Unmark pair as settling (_settling[pair] = false)
```

Settlement works in both bonding and post-graduation phases. During settling, BondingCurve's `_calculateFees` and `_getTotalFeeRate` return 0 fees for the pair, and NadFunPair skips fee collection — preventing recursive fee accumulation during vault buybacks.

---

## Events

| Event | Parameters |
|-------|------------|
| `Setup` | `address indexed token, address indexed pair, uint16 creatorFeeRate, uint16 curveProtocolFeeRate, uint16 dexProtocolFeeRate` |
| `Collect` | `address indexed token, address indexed pair, uint256 amount` |
| `Settle` | `address indexed token, address indexed pair, uint256 totalFee, uint256 creatorFee` |

## Errors

| Error | Description |
|-------|-------------|
| `AlreadyConfigured()` | Pair already has a fee config registered |
| `NotConfigured()` | Pair has no fee config (quoteToken is zero) |
| `ZeroAddress()` | Required address parameter is zero |
| `InvalidRates()` | creatorFeeRate, curveProtocolFeeRate, and dexProtocolFeeRate are all zero |
| `NotAuthorized()` | Caller is not pair or bondingCurve |
| `PairLocked()` | Pair is inside its lock-guarded operation |
