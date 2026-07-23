# CreatorFeeProcessor

**Path:** `src/core/CreatorFeeProcessor.sol`
**Pattern:** Immutable singleton
**Authority:** `ProtocolManager.canCall()`

CreatorFeeProcessor pulls an already-denominated quote-token creator share from an authorized caller and distributes it across the launch token's configured vault slots.

## State

- `protocolManager`: immutable authority
- `_vaults[token]`: up to five `(vault, bps)` slots

## Functions

| Function | Authorization | Behavior |
| --- | --- | --- |
| `setup(token, vaults)` | Exact ProtocolManager selector permission | One-time vault configuration; nonempty, maximum five, nonzero entries, total 10,000 BPS |
| `processCreatorFee(token, quoteToken, amount)` | Exact ProtocolManager selector permission | Pull exact quote amount, distribute by BPS, call every funded vault's `afterDeposit` |
| `vaultCount(token)` | Public view | Configured slot count |
| `getVaults(token)` | Public view | Complete slot list |

The default deployment authorizes BondingCurve for `setup()` and LPManager for `processCreatorFee()`.

## Distribution

```text
LPManager
  ├─ approve exact creator quote
  └─ CreatorFeeProcessor.processCreatorFee
       ├─ transferFrom exact quote amount
       ├─ transfer each BPS share to its vault
       ├─ vault.afterDeposit(token, quoteToken, amount)
       └─ require Processor exit balance == entry balance
```

The final slot receives the rounding remainder. Every pull and push checks the sender and receiver balance deltas. A failed transfer or vault callback reverts the complete distribution.
