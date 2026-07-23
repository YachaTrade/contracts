# ICreatorFeeProcessor

**Path:** `src/interfaces/ICreatorFeeProcessor.sol`
**Type:** Interface

Public interface for the non-upgradeable CreatorFeeProcessor singleton. It pulls an already-denominated quote-token creator share from a caller authorized by ProtocolManager and distributes it across the token's configured vaults.

---

## Structs

### VaultSlot

```solidity
struct VaultSlot {
    address vault;   // singleton vault address
    uint16 bps;      // basis points allocation
}
```

> `sum(vaults[i].bps) == 10000` required. Each vault must have `bps > 0` and `vault != address(0)`.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `setup(token, vaults)` | — | Register the token's vault allocation; callable only by BondingCurve and only once |
| `processCreatorFee(token, quoteToken, amount)` | — | Pull `amount` of `quoteToken` from an authorized caller, split it by BPS, transfer each share, and call each vault's `afterDeposit` |
| `vaultCount(token)` | `uint256` | Number of vault slots for given token |
| `getVaults(token)` | `VaultSlot[]` | All configured vault slots for the token |

Distribution is atomic: a failed transfer or vault callback reverts the whole transaction. No token swap is performed by CreatorFeeProcessor.

---

## Events

| Event | Parameters |
|-------|------------|
| `Setup` | `address indexed token, VaultSlot[] vaults` |
| `Distribute` | `address indexed token, address indexed vault, uint256 amount` |
| `CallbackFail` | `address indexed vault, uint256 amount, bytes reason` |

`CallbackFail` remains in the interface ABI, but the current implementation calls vaults directly and does not emit it.

## Errors

| Error | Description |
|-------|-------------|
| `InvalidBpsTotal()` | Vault BPS total != 10000 |
| `ZeroAddress()` | Required address is zero |
| `NotAuthorized()` | ProtocolManager does not authorize the caller for the exact target selector |
| `TooManyVaults()` | More than 5 vaults |
| `NoVaults()` | Zero vaults provided |
| `ZeroBps()` | A vault has 0 BPS |
| `AlreadyConfigured()` | The token already has a vault configuration |
