# FeeCollector

**Path:** `src/core/FeeCollector.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IFeeCollector`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

Central fee management contract with per-pair storage. Collects trading fees and settles accumulated creator fees through CreatorFeeProcessor.

BondingCurve calls `setup()` on token creation to register a pair's fee config. On each retained V2/curve trade, the pair (or BondingCurve) transfers quoteToken and calls `collectFee(pair, protocolFee, creatorFee)`. The received balance delta must cover those explicit components; protocol fee plus excess is forwarded immediately to the current ProtocolManager feeReceiver, while creator fee accumulates per pair. `settle(pair, minAmountOut)` is restricted to authorized settlers.

---

## State Variables

### Private (set via initialize)

| Variable | Type | Purpose |
|----------|------|---------|
| `_creatorFeeProcessor` | `ICreatorFeeProcessorV2` | Local minimal interface used for CreatorFeeProcessor settlement |
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
| `initialize(protocolManager_, creatorFeeProcessor_, bondingCurve_, router_)` | external (initializer) | Proxy initializer; wires authority, core addresses, and GiwaRouter settlement quoting |
| `setup(pair, baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)` | external (onlyBondingCurve) | Register per-pair fee config; reverts if already configured |
| `getFeeConfig(pair)` | view | Returns the full `FeeConfig` for a pair |
| `collectFee(pair, protocolFee, creatorFee)` | external | Validates caller and that the received balance delta covers the explicit components; sends protocol fee plus excess to feeReceiver and accumulates creator fee. |
| `settle(pair, minAmountOut)` | external (restricted) | Settle accumulated creator fees if above threshold and the router quote meets the caller's minimum. |
| `isSettling(pair)` | view | Whether pair is currently in settling state |
| `accumulatedFee(pair)` | view | Accumulated creator fee for a pair |
| `settlementThreshold(pair)` | view | Current settlement threshold for the pair's quote token |
| `isSettleable(pair)` | view | Whether accumulated fee meets threshold |
| `setCurveProtocolFeeRate(pair, rate)` | external (restricted) | Update bonding curve protocol fee rate for a pair |
| `setDexProtocolFeeRate(pair, rate)` | external (restricted) | Update dex protocol fee rate for a pair |

---

## Key Logic: collectFee Flow

```
Caller (pair or bondingCurve) transfers quoteToken to FeeCollector, then calls collectFee(pair, protocolFee, creatorFee)

1. Auth check: msg.sender must be pair itself or bondingCurve (revert NotAuthorized otherwise)
2. Look up pair config (revert if not configured)
3. Compute feeReceived via balance delta and require feeReceived >= protocolFee + creatorFee
4. Transfer protocolFee + any excess received to the current feeReceiver
5. Accumulate the explicit creatorFee in _accumulatedFees[pair]
6. Update _trackedBalance[quoteToken] after the transfer
```

## Key Logic: settle Flow

```
Authorized settler calls settle(pair, minAmountOut)

1. Reject a pair that is currently lock-guarded; return if accumulated fee is below threshold
2. Mark pair as settling and, when non-zero, require the GiwaRouter settlement quote >= minAmountOut
3. Zero accumulated fee and decrement tracked balance (CEI)
4. Approve and call creatorFeeProcessor.processCreatorFee(baseToken, quoteToken, amount)
5. Unmark pair as settling
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
| `InvalidFeeAmount()` | Received balance delta is below the declared fee components |
| `InsufficientOutput()` | Router settlement quote is below `minAmountOut` |
