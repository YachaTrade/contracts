# GiwaRouter integration report

## Result

- Source commit `db4bc8e` was integrated with `git cherry-pick db4bc8e`.
- The cherry-pick completed without textual conflicts and produced `b4c4e88` (`feat: add GiwaRouter V3 routing`). Git auto-merged `src/core/BondingCurve.sol` cleanly.
- The semantic integration follow-up is `02421da` (`fix: align launch lifecycle with V3 routing`).
- No push, pull request, deployment, or external write was performed.

## Integration decisions

- Production token creation now accepts only `ITokenRegistry.DexType.UniswapV3`; V2 and V4 are rejected before token deployment.
- BondingCurve creates the canonical pool through `V3PoolDeployer`, registers its pool and snapshotted fee tier through `TokenRegistry.registerV3`, and graduates only through `LPManager.allocate`.
- Graduation passes `initialQuoteReserve` and `initialTokenReserve` to `ILPManager.AllocateParams`. This preserves the contract-v3 bonding tick/range inputs; no range clamping or LPManager math change was introduced.
- The public `MODULE_FACTORY` constant/getter was retained for upgrade ABI compatibility, although the production creation/graduation path no longer uses it.
- The shared test fixture now deploys and wires `V3PoolDeployer` and `V3LiquidityActor`, sets V3 quote configuration, and grants only the V3 creation/registration/allocation selectors required by BondingCurve.
- Router lifecycle fixtures were migrated to V3. Tests that asserted graduated-V2 router metadata were removed because V2 graduation is no longer a supported production state. Near-graduation refund tests retain output and balance assertions without assuming an uninterrupted ERC-20 event sequence across V3 allocation.

## Preserved liquidity work

`src/core/LPManager.sol`, `src/interfaces/ILPManager.sol`, and `src/actors/V3LiquidityActor.sol` are unchanged across `b927a69..02421da` (zero diff). In particular, the integration preserved:

- `ILPManager.AllocateParams` and `allocate`;
- one-time V3 actor/factory wiring through `setV3LiquidityActor`;
- balance-delta settlement checks;
- stored-pool and stored-position lifecycle;
- the contract-v3 bonding tick/range implementation and its parity/fuzz tests;
- disabled legacy `addLiquidity` and `claimFees` behavior.

BondingCurve storage layout is unchanged. No state variable was added, removed, reordered, or retyped.

## Validation

The protected untracked `test/integration/ProtocolWethQuote.t.sol` was moved to a temporary directory only for compilation/test commands and restored by a shell trap.

- `forge fmt` on all seven touched Solidity files: passed.
- `forge fmt --check` on all seven touched Solidity files: passed.
- `forge fmt --check` repository-wide: failed only on pre-existing formatting in unchanged `test/core/BondingCurveAttack.t.sol` lines 61-63.
- `forge build` with the protected paused test temporarily excluded: passed with warnings only.
- Plain `forge build` with that untracked test present: fails because the paused test calls missing helper `_deployWethAndProtocolManager`.
- `forge test --match-path test/adapters/V3SwapAdapter.t.sol`: 27 passed, 0 failed.
- `forge test --match-path 'test/router/GiwaRouter*.t.sol'`: 45 passed, 0 failed.
- `forge test --match-path test/modules/LPManagerV3.t.sol`: 12 passed, 0 failed, including 257 fuzz runs.
- `forge test --match-path test/modules/V3LiquidityActor.t.sol`: 28 passed, 0 failed.
- `forge test --match-path 'test/core/GiwaRouter*.t.sol'`: 49 passed, 0 failed.
- BondingCurve V3-only creation regressions: 3 passed, 0 failed.
- Independent review also ran the complete focused `test/core/BondingCurve.t.sol`: 38 passed, 0 failed.
- `git diff --check`: passed.
- `git show --stat --oneline --summary b4c4e88` and `git show --name-status --format='' b4c4e88`: inspected; the cherry-pick contains 102 paths and the expected router, adapter, interface, test, ABI, and documentation changes.
- Full non-fork suite with the protected paused test excluded: 709 passed, 69 failed. The failures are the legacy-V2 and shared-fixture follow-ups described below, so the repository-wide suite is not green.

The fork suite was not run because this integration did not receive/validate fork environment configuration.

## Required follow-ups and release concerns

1. **Fee-tier mutation can block graduation.** A token snapshots its V3 pool fee tier at creation, but `LPManager._loadPoolData` also requires that tier to equal the quote token's current mutable configuration. Changing the configured tier between creation and graduation makes `allocate` revert. The LPManager implementation was intentionally preserved in this integration; a follow-up should validate against the registry/pool snapshot and add a create -> change tier -> graduate regression.
2. **The normal deployment script is not V3-ready.** `script/deploy/normal/Deploy.s.sol` still registers `FACTORY`, grants `TokenRegistry.register`/`LPManager.addLiquidity`, does not deploy/wire `V3PoolDeployer` or `V3LiquidityActor`, and does not set V3 quote configuration. A deployment from that script cannot create tokens under the new V3-only BondingCurve. This belongs to the paused protocol-WETH/deployment task and is a release blocker until completed.
3. **Legacy V2 graduation suites require conversion or removal.** Exact production-lifecycle suites still depending on V2 are `test/core/Graduation.t.sol`, `test/core/BondingCurveV2.t.sol`, `test/integration/FullLifecycleE2E.t.sol`, and the post-graduation cases in `test/integration/SettleBondingPhase.t.sol`. Direct legacy LPManager suites `test/core/RouterV2.t.sol` and `test/modules/LPManager.t.sol` also target now-disabled APIs. They were not mass-rewritten in this integration because a separate repo-wide audit was reserved for the next task.
4. **Paused test and formatting debt remain protected.** `test/integration/ProtocolWethQuote.t.sol` prevents a plain build until its next-task helper is implemented, and unchanged `test/core/BondingCurveAttack.t.sol` prevents repository-wide `forge fmt --check`.

## Protected workspace state

The following user-owned paths were neither staged nor committed:

- `.superpowers/sdd/progress.md`
- `docs/superpowers/plans/2026-07-21-protocol-weth-quote.md`
- `graphify-out/`
- `test/integration/ProtocolWethQuote.t.sol`
