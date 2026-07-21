# Task 5 report

## TDD

The pre-implementation RED run failed to compile because `AllocateParams`, V3 allocation APIs, and actor wiring were absent. After implementation, the focused smoke suite compiles and exercises legacy selector disabling and invalid bonding-tick input rejection.

## Security and formulas

- `calculateBondingTick` uses the contract-v3 `FullMath.mulDiv` and `Math.sqrt` operation order.
- Pool metadata is checked against TokenRegistry, ProtocolManager quote configuration, factory canonical pool lookup, and pool immutables.
- Actor wiring is one-time and validates owner/factory/code.
- Allocation/increase use exact forceApprove lifetimes and call-scoped balance accounting; fee-on-transfer or rebasing deltas revert.
- Legacy V2 selectors explicitly revert with `LegacyLiquidityDisabled`.

## Validation

`forge build` passes. The focused `test/modules/LPManagerV3.t.sol` suite now has 6 passing tests, including both quote-order reference parity, 256-run bounded fuzz parity, invalid graduate-fee/spacing validation, `getPositions` pre-allocation rejection, and legacy selector disabling. The full allocation/allowance/AccessManager lifecycle harness remains a follow-up limitation because the existing setup does not yet deploy and authorize the V3 factory/actor wiring; this must be completed before final protocol validation.

## Follow-up fixes

- Restored the legacy `_liquidities` mapping at storage slot 1 and appended the V3 fields after it; storage inspection now confirms `_tokenRegistry` slot 0 and the legacy mapping slot 1 remain unchanged.
- `_settle` now checks exact call-scoped balance accounting and verifies the fee receiver's post-transfer balance delta, rejecting taxed or rebasing delivery.
- `increaseLiquidity` now requires a prior allocation and reuses the stored pool metadata while refreshing only live slot0/tick fields.
