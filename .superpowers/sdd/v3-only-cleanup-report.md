# V3-only lifecycle cleanup report

## Status

COMPLETE

Fresh token launches and graduation are V3-only, tokens graduate through the canonical pool and fee tier snapshotted at creation, settlement supports canonical V3 pools, and the default test deployment registers only `CreatorFeeVault`.

## Production changes

- `LPManager._loadPoolData` still requires an active quote config and a V3 registry record, but no longer compares the token's snapshotted fee tier with the mutable live quote configuration. It validates the canonical factory lookup and the pool's `factory()` and `fee()` against `TokenRegistry.TokenInfo`.
- `FeeCollector.settle` now probes the configured market's lock state conservatively: legacy `isLocked()` when implemented, otherwise V3 `slot0().unlocked`. Locked or malformed/non-pool responses revert with `PairLocked`.
- `BondingCurve` was audited as V3-only: launch calls only `V3PoolDeployer.createPool` and `TokenRegistry.registerV3`; graduation calls only `LPManager.allocate`.
- No UUPS storage variables or initializer layouts changed.
- The LPManager/V3LiquidityActor tick calculation and range-bound operation order remain equivalent to `/Users/gyu/project/nads-pump/contract-v3`. The retained reference/fuzz suite covers 257 fuzz runs.

## CreatorFeeVault-only decision

- The shared `SetUp` fixture now deploys and registers only `CreatorFeeVault`.
- Fresh deployment wiring was finalized separately in `86e77cd`; it also deploys/registers only `CreatorFeeVault`.
- Product-specific BurnVault, LPVault, GiftVault, and DividendVault tests and integration lanes were removed. Their legacy source contracts were not deleted by this cleanup.
- The security-critical settlement callback invariants removed with the old product-vault integration file were preserved in `SettlementInvariants.t.sol` with generic probes: settling-flag lifetime, fee waiver during callback buys, and per-pool isolation.

## Test conversion

Converted to real V3 launch/graduation fixtures or V3 assertions:

- `test/SetUp.t.sol`
- `test/core/BondingCurve.t.sol`
- `test/core/BondingCurveAttack.t.sol`
- `test/core/BuyCap.t.sol`
- `test/core/Fee.t.sol`
- `test/core/Graduation.t.sol`
- `test/core/ProtocolManager.t.sol`
- `test/core/QuoteReserveAttack.t.sol`
- `test/fee/FeeCollector.t.sol`
- `test/integration/FullLifecycleE2E.t.sol`
- `test/modules/ModuleAttack.t.sol`
- `test/vault/VaultAttack.t.sol`

Other retained compatibility coverage was narrowed without preserving a V2 launch path:

- `test/core/FeeTo.t.sol` now creates a standalone V2 market directly.
- `test/integration/TokenInfoLens.t.sol` seeds legacy registry data directly.
- `test/vault/VaultRegistry.t.sol` uses a generic `IVault` implementation.
- `test/adapters/NadSwapAdapter.t.sol` no longer refers to a removed product vault.

Added:

- `test/integration/SettlementInvariants.t.sol`

Deleted because the files existed only for V2 launch/graduation, legacy liquidity minting, or unsupported product vaults:

- `test/core/BondingCurveV2.t.sol`
- `test/core/RouterV2.t.sol`
- `test/integration/DividendRouterLane.t.sol`
- `test/integration/SettleBondingPhase.t.sol`
- `test/mocks/MockBondingCurveV1.sol`
- `test/mocks/MockGiwaRouter.sol`
- `test/modules/LPManager.t.sol`
- `test/vault/BurnVaultV2.t.sol`
- `test/vault/DividendVault.t.sol`
- `test/vault/GiftVault.t.sol`
- `test/vault/LPVaultV2.t.sol`

## Regression coverage

- The focused tier-snapshot test creates a token at tier A (`3000`), changes the live quote config to tier B (`500`), proves the live change took effect, graduates successfully, and verifies registry/factory state remains on tier A with no tier-B pool.
- FeeCollector tests cover unlocked V3 pools, locked V3 pools, and malformed lock responses.
- Full lifecycle coverage uses GiwaRouter against the real V3 pool, verifies both permanent LPManager positions, trades after graduation, settles creator fees, and checks that CreatorFeeVault credit is fully backed.
- ProtocolManager default assertions now require the configured V3 fee tier and LP fee share instead of zero values.

## Audit

Command:

```shell
rg -n "DexType.UniswapV2|addLiquidity\(|createPair\(|TokenRegistry.register" test src/core/BondingCurve.sol script/deploy/normal/Deploy.s.sol
```

Result classification:

- `src/core/BondingCurve.sol`: no legacy match; only V3 `createPool`, `registerV3`, and `allocate` lifecycle calls.
- `script/deploy/normal/Deploy.s.sol`: only `registerV3` permission/verification matches.
- Remaining test matches are allowed standalone legacy DEX/adapter/registry compatibility tests, a vanilla V2 market, interface stubs, or the negative test proving `DexType.UniswapV2` launch rejection. None creates or graduates a launch token through V2.
- `rg -n "BurnVault|LPVault|GiftVault|DividendVault" test -g '*.sol'` returned no matches.

## Review

The first read-only code review found no production correctness or storage-layout defect. It requested three coverage/clarity improvements, all resolved before the final commits:

- restored generic settlement flag, callback fee-waiver, and per-pool isolation invariants;
- asserted that the live tier actually changed to B before snapshot graduation;
- removed stale V2-era comments and the dead `BondingCurveV2Test` reference.

The final Solidity security review found no actionable production security defect. It covered access control, settlement callback ordering, conservative pool-lock handling, canonical V3 validation, fee-tier snapshots, and UUPS layout. Residual low-priority test gaps are:

- The V3 locked-pool branch uses a faithful `slot0().unlocked == false` mock; no genuine Uniswap V3 callback invokes authorized settlement while the real pool lock is held.
- The intentionally retained legacy Burn/LP/Gift/Dividend source and upgrade scripts no longer have dedicated regression suites. Re-enabling or upgrading those vaults is outside the tested CreatorFeeVault-only fresh-deployment policy.

## Validation

- `forge test --summary` — 48 suites, 611 passed, 0 failed, 2 skipped.
- `forge test --match-path test/modules/LPManagerV3.t.sol -q` — passed, 12 tests.
- `forge test --match-path test/modules/V3LiquidityActor.t.sol -q` — passed, 28 tests.
- `forge test --match-path test/core/BondingCurve.t.sol -q` — passed, 39 tests.
- `forge test --match-path test/core/GiwaRouter.t.sol -q` — passed, 26 tests.
- `forge test --match-path test/core/Graduation.t.sol -q` — passed, 8 tests.
- `forge test --match-path test/fee/FeeCollector.t.sol -q` — passed, 37 tests.
- `forge test --match-path test/integration/SettlementInvariants.t.sol -q` — passed, 3 tests.
- `forge test --match-path test/integration/FullLifecycleE2E.t.sol -q` — passed, 4 tests.
- `forge build` — passed; repository lint emitted non-blocking warnings/notes.
- `forge fmt --check` — passed.
- `git diff --check` — passed.

The two skipped suites are intentionally gated fork tests:

- `GiwaRouterNativeQuoteForkTest`
- `TokenInfoLensForkTest`

Both require `RUN_FORK_TESTS=true` and a configured RPC environment. No fork test or live deployment was run.

## Development-time failures and resolution

- The tier-A/tier-B regression test was first run before the LPManager fix and failed with `LPManager.InvalidPool()`, providing the expected RED evidence. It passes after removing the live-tier equality check.
- During one early parallel formatter/test batch, these seven focused commands reported `Compilation failed` while sources were being formatted: LPManagerV3, V3LiquidityActor, BondingCurve, GiwaRouter, Graduation, FeeCollector, and CreatorFeeProcessor. Each was rerun sequentially after the workspace stabilized and passed.
- One intermediate `forge build` failed while the concurrently owned `ProtocolWethQuote.t.sol` was mid-edit, with undeclared `_deployV3Routing` and `_deployVaults` helpers. The WETH owner completed `86e77cd`; the final build and full suite pass.
- `forge inspect LPManager storageLayout && forge inspect FeeCollector storageLayout` exited 1 with `storage layout missing from artifact; this could be a spurious caching issue`. No cache-destructive rebuild was needed: the production diff changes only function bodies/imports and contains no state declaration, storage type, base contract, or inheritance-order change.

There are no unresolved test or build failures.

## Commits

- `382e5ca` — `fix: preserve canonical V3 lifecycle metadata`
- `c437153` — `test: remove unsupported launch and vault fixtures`

Related canonical-WETH/fresh-deployment finalization included in the final validation state:

- `86e77cd` — `fix: use canonical GIWA WETH predeploy`

The report is committed separately because `.superpowers/sdd/` is intentionally ignored by default.
