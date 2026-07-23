# GIWA Launchpad Test Guide

## Standard validation

Run from the repository root:

```shell
forge fmt --check
forge build
forge test
bash test/script/extract-abis.sh
git diff --check
```

The latest complete local run finished with:

```text
557 passed
0 failed
2 skipped
```

The two skipped cases are environment-gated fork tests. They require explicit RPC configuration and `RUN_FORK_TESTS=true`.

## Focused commands

```shell
# Complete WNATIVE lifecycle: create, curve trading, graduation, V3 sell-out
forge test --match-path test/integration/WnativeV3GraduationE2E.t.sol -vvv

# V3 LP fee accrual, token-to-quote swap, protocol/creator split
forge test --match-path test/integration/WnativeV3LpFeeCollectionE2E.t.sol -vvv

# LPManager fee accounting and adversarial cases
forge test --match-path test/modules/LPManagerCollect.t.sol -vvv

# Contract-v3 two-position math and permanent-liquidity allocation
forge test --match-path test/modules/LPManagerV3.t.sol -vvv
forge test --match-path test/modules/V3LiquidityActor.t.sol -vvv

# Principal-lock invariant
forge test --match-path test/invariant/LPPrincipalLock.invariant.t.sol -vvv

# YachaRouter routes and native-value behavior
forge test --match-path test/core/YachaRouter.t.sol -vvv
forge test --match-path test/router/YachaRouterNativeV3.t.sol -vvv
forge test --match-path test/router/YachaRouterV3Swap.t.sol -vvv

# Deployment and migration scripts
forge test --match-path test/script/DeployYachaRouter.t.sol -vvv
forge test --match-path test/script/MigrateYachaRouterRole.t.sol -vvv
forge test --match-path test/script/UpgradeLPManager.t.sol -vvv
forge test --match-path test/script/UpgradeYachaRouter.t.sol -vvv

# Optional fork suite
RUN_FORK_TESTS=true forge test --match-path test/fork/YachaRouterNativeQuoteFork.t.sol -vvv
```

## Coverage map

| Area | Test paths | Main assertions |
| --- | --- | --- |
| Curve lifecycle | `test/core/BondingCurve*.t.sol`, `test/core/Graduation.t.sol` | Creation, reserve math, fees, attacks, graduation boundary |
| Protocol config | `test/core/ProtocolManager*.t.sol` | Multiple quote tokens, V3 tier, LP split, operator permissions |
| Registry and pools | `test/core/TokenRegistry.t.sol`, `test/core/V3PoolDeployer.t.sol` | Canonical metadata, factory validation, initialization |
| Router | `test/core/YachaRouter*.t.sol`, `test/router/` | Curve/V3 dispatch, quotes, permits, deadlines, slippage, refunds |
| V3 execution | `test/adapters/V3SwapAdapter.t.sol`, `test/modules/V3LiquidityActor.t.sol` | Callback authentication, swaps, minting, collection |
| LPManager | `test/modules/LPManagerV3.t.sol`, `test/modules/LPManagerCollect.t.sol` | Two-position allocation, increases, fee preview, collection and split |
| Creator revenue | `test/token/CreatorFeeProcessorV2.t.sol`, `test/vault/CreatorFeeVault.t.sol` | Authorized pull, BPS distribution, accounting, creator claim |
| End to end | `test/integration/WnativeV3*.t.sol` | Graduation, complete post-graduation sells, real pool fees |
| Invariants | `test/invariant/LPPrincipalLock.invariant.t.sol` | Fee collection cannot withdraw position principal |
| Deployment | `test/script/` | Dependency graph, staging, UUPS permission and migration guards |
| Fork | `test/fork/` | Deployed WNATIVE and external integration behavior |

## Graduation E2E

`WnativeV3GraduationE2E.t.sol` verifies:

1. a token is created with WNATIVE as its quote token;
2. curve buys move virtual reserves consistently;
3. the graduation threshold is reached;
4. the canonical V3 pool matches TokenRegistry and the factory;
5. LPManager records the pool and the two V3 positions;
6. the positions receive liquidity with the expected contract-v3 ranges;
7. the user can sell the entire remaining token balance after graduation;
8. protocol fee and residual-asset balances reach the intended receiver;
9. no unexpected token or quote balance remains in the router.

## LP-fee E2E

`WnativeV3LpFeeCollectionE2E.t.sol` verifies:

1. post-graduation swaps generate fees in the permanent positions;
2. `callStaticGetAccumulatedFees()` reports the currently collectable token and quote amounts;
3. `collect()` receives both position fees without reducing principal liquidity;
4. launch-token fees are fully swapped through the canonical pool;
5. direct and swapped quote amounts are combined;
6. the per-quote protocol share reaches `feeReceiver`;
7. the remainder reaches CreatorFeeProcessor and then CreatorFeeVault;
8. entry balances and unrelated token donations are preserved;
9. temporary allowances are zero after completion.

## Adversarial coverage

Focused attack tests cover:

- callback spoofing and noncanonical pools;
- mismatched registry metadata or fee tier;
- fee-on-transfer and false balance-delta tokens;
- duplicate collection inputs;
- partial token-fee swaps;
- donated router, curve, manager, and processor balances;
- unauthorized collect, allocation, role migration, and upgrades;
- invalid UUPS implementation targets;
- native-value use with a non-WNATIVE quote token;
- expired deadlines and slippage violations;
- failed creator-vault hooks and atomic batch rollback.

## ABI regression

`bash test/script/extract-abis.sh` rebuilds the canonical public ABIs and fails if checked-in artifacts differ. `abis/YachaRouter.json` and `abis/Lens.json` are the current router-facing artifacts.

## Fork tests

Fork tests are skipped unless explicitly enabled:

```shell
RUN_FORK_TESTS=true RPC_URL=<rpc> forge test --match-path 'test/fork/*.t.sol' -vvv
```

Do not place RPC credentials or private keys in commands, logs, committed files, or test output.
