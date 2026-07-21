# CreatorFeeProcessor

**Path:** `src/core/CreatorFeeProcessor.sol`
**Pattern:** Singleton
**Inheritance:** `ICreatorFeeProcessor`

Singleton creator fee distribution pipeline (V2). Receives quoteToken from FeeCollector (already settled) and distributes to registered vaults by BPS ratio.

One singleton instance shared by all tokens. Common state (bondingCurve, feeCollector) is set via constructor immutable. Per-token vault config stored in `mapping(token => VaultSlot[])`.

**V1 vs V2:**
- Removed baseToken -> quoteToken swap logic (FeeCollector already holds quoteToken)
- Removed ITokenRegistry, IDexAdapter, IProtocolManager dependencies
- Removed protocolFeeAmount handling (FeeCollector separates protocol fee)
- Added feeCollector immutable (access control for processCreatorFee)

**Pull Pattern:** FeeCollector calls `approve()` then `processCreatorFee()`. CreatorFeeProcessor uses `transferFrom` to pull the exact amount. No balance accumulation in CreatorFeeProcessor (prevents cross-token contamination).

**Deploy Order:** BondingCurve first -> CreatorFeeProcessor(constructor with BC + FeeCollector address) -> setModule(MODULE_CREATOR_FEE_PROCESSOR, processor).

---

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BPS` | `10_000` | Basis points reference |
| `MAX_VAULTS` | `5` | Maximum number of vault slots |

---

## State Variables

### Immutable (set via constructor)

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `bondingCurve` | `address` | public immutable | BondingCurve address (only caller for setup) |
| `feeCollector` | `address` | public immutable | FeeCollector address (only caller for processCreatorFee) |

### Per-Token Storage

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_vaults` | `mapping(address => VaultSlot[])` | private | Per-token vault address + BPS pairs |

### VaultSlot (Struct)

```solidity
struct VaultSlot {
    address vault;   // singleton vault address
    uint16 bps;      // basis points allocation
}
```

> `sum(vaults[i].bps) == 10000` (validated during setup)
>
> Each vault slot must have `bps > 0` and `vault != address(0)`.

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `constructor(bondingCurve, feeCollector)` | -- | Set immutable common state |
| `setup(token, vaults)` | external (onlyBondingCurve) | Register per-token vault config + validate BPS total |
| `processCreatorFee(token, quoteToken, amount)` | external (onlyFeeCollector) | Pull quoteToken from FeeCollector, distribute to vaults by BPS |
| `vaultCount(token)` | view | Number of vault slots for given token |
| `getVaults(token)` | view | All vault slots for given token |

---

## Key Logic: processCreatorFee Flow

```
FeeCollector.settle(pair, minAmountOut)
  -> approve(creatorFeeProcessor, amount)
  -> CreatorFeeProcessor.processCreatorFee(token, quoteToken, amount)

1. Pull: transferFrom(feeCollector, this, amount) <- pull pattern

2. Distribute quoteToken to vaults by BPS (from mapping[token])
   for each vault[i]:
     |- amount = creatorFeeQuote * vault[i].bps / BPS (last gets remainder)
     |- safeTransfer(vault[i].vault, amount)
     +- vault[i].afterDeposit(token, quoteToken, amount)
```

Each vault handles its own logic (burn, LP, dividend, direct transfer, etc.). CreatorFeeProcessor has no built-in knowledge of that logic, and the callback is direct: any vault failure reverts the full distribution and the caller's settlement transaction.

### Pull Pattern

FeeCollector calls `approve(creatorFeeProcessor, amount)` before calling `processCreatorFee()`. CreatorFeeProcessor uses `transferFrom` to pull the exact amount needed. This ensures no balance accumulation in CreatorFeeProcessor, preventing cross-token contamination in the singleton.

---

## Events

| Event | Parameters |
|-------|------------|
| `Setup` | `address indexed token, VaultSlot[] vaults` |
| `Distribute` | `address indexed token, address indexed vault, uint256 amount` |
| `CallbackFail` | `address indexed vault, uint256 amount, bytes reason` |

## Errors

| Error | Description |
|-------|-------------|
| `InvalidBpsTotal()` | Vault BPS total != 10000 |
| `ZeroAddress()` | Required address is zero |
| `NotAuthorized()` | Caller is not bondingCurve (setup) or feeCollector (processCreatorFee) |
| `TooManyVaults()` | More than 5 vaults |
| `NoVaults()` | Zero vaults provided |
| `ZeroBps()` | A vault has 0 BPS |
| `AlreadyConfigured()` | Vaults already set for this token |
