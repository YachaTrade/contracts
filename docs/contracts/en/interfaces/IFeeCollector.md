# IFeeCollector

**Path:** `src/interfaces/IFeeCollector.sol`
**Type:** Interface

Public interface for FeeCollector. Defines per-pair fee configuration, collection, and settlement functions.

---

## Structs

### FeeConfig

```solidity
struct FeeConfig {
    address baseToken;       // base token (graduated token); passed to CreatorFeeProcessor on settlement
    address quoteToken;      // quote token used as the fee asset
    uint16 creatorFeeRate;   // creator fee rate (BPS)
    uint16 curveProtocolFeeRate; // bonding curve protocol fee rate (BPS)
    uint16 dexProtocolFeeRate;   // dex protocol fee rate (BPS)
}
```

This is the single source of truth for per-pair fee configuration — used both for storage inside `FeeCollector` and as the return type of `getFeeConfig(pair)`.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `setup(pair, baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)` | -- | Register per-pair fee config (onlyBondingCurve) |
| `getFeeConfig(pair)` | `FeeConfig` | Returns the full fee config (baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate) for a pair. Pairs call this with `address(this)` and compute the active fee rate locally. |
| `collectFee(pair)` | -- | Collect fee via balance delta: msg.sender must be pair or bondingCurve. Uses the caller-specific protocol fee rate, forwards protocol fee immediately, and accumulates creator fee. |
| `settle(pair)` | -- | Settle accumulated creator fees (restricted to authorized settlers). Works in both bonding and post-graduation phases. |
| `accumulatedFee(pair)` | `uint256` | Accumulated creator fee for a pair |
| `settlementThreshold(pair)` | `uint256` | Current settlement threshold for the pair's quote token (from ProtocolManager) |
| `isSettleable(pair)` | `bool` | Whether accumulated fee meets threshold |
| `isSettling(pair)` | `bool` | Whether pair is currently in settling state |
| `setCurveProtocolFeeRate(pair, rate)` | -- | Update bonding curve protocol fee rate for a pair (restricted) |
| `setDexProtocolFeeRate(pair, rate)` | -- | Update dex protocol fee rate for a pair (restricted) |

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
| `NotConfigured()` | Pair has no fee config |
| `ZeroAddress()` | Required address parameter is zero |
| `InvalidRates()` | creatorFeeRate, curveProtocolFeeRate, and dexProtocolFeeRate are all zero |
| `NotAuthorized()` | Caller is not authorized |
| `PairLocked()` | Pair is inside its lock-guarded operation |
