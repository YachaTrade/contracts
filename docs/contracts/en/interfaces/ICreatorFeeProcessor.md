# ICreatorFeeProcessor

**Path:** `src/interfaces/ICreatorFeeProcessor.sol`
**Type:** Interface

Public interface for CreatorFeeProcessor singleton. Defines the simplified swap-and-distribute pipeline with pull pattern.

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
| `setup(token, vaults)` | — | Register per-token vault config (onlyAuthorized) |
| `processCreatorFee(token, creatorFeeAmount, protocolFeeAmount)` | — | Creator fee processing: pull → swap all → fee → vaults[] |
| `quoteToken()` | `address` | Swap target token (immutable) |
| `vaultCount(token)` | `uint256` | Number of vault slots for given token |
| `getVault(token, index)` | `(address, uint16)` | Vault address and BPS at index for given token |

---

## Events

| Event | Parameters |
|-------|------------|
| `CreatorFeeProcessed` | `uint256 creatorFeeAmount, uint256 protocolFeeAmount, uint256 quoteReceived` |
| `VaultDistributed` | `address indexed vault, uint256 amount` |
| `VaultCallbackFailed` | `address indexed vault, uint256 amount, bytes reason` |

## Errors

| Error | Description |
|-------|-------------|
| `InvalidBpsTotal()` | Vault BPS total != 10000 |
| `ZeroAddress()` | Required address is zero |
| `NotAuthorized()` | Caller is not the token |
| `TooManyVaults()` | More than 5 vaults |
| `NoVaults()` | Zero vaults provided |
| `ZeroBps()` | A vault has 0 BPS |
