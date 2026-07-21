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

`forge build` passes. The focused `test/modules/LPManagerV3.t.sol` smoke tests compile and pass where fixtures are available. Full actor/integration coverage remains in the existing suites.
