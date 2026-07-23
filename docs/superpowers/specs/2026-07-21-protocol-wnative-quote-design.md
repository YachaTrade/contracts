# Canonical WNATIVE Quote Design

## Status

Current design for fresh deployments. This replaces the earlier proposal to deploy a protocol-owned wrapped-native contract.

## Objective

Use the chain's canonical WNATIVE predeploy as the default native quote throughout token creation, bonding-curve trading, Uniswap V3 graduation, post-graduation swaps, native unwraps, and LP fee distribution.

## Canonical dependency

- The canonical address is `0x4200000000000000000000000000000000000006`.
- `Deploy.s.sol` owns this value as `GIWA_WNATIVE`; operators cannot override it with an environment variable.
- Deployment requires code at that address and reuses it. It does not deploy, upgrade, or administer WNATIVE.
- Every native-aware component receives the same address.
- Uniswap periphery keeps its standard `WETH9()` getter name even though the configured asset is WNATIVE.

## Trust boundary

The deployment script verifies that the canonical address has code and that every deployed protocol component is wired to that address. It does not attest the predeploy's bytecode, backing, upgrade controls, or administrator surface.

The chain deployment must therefore guarantee that the canonical address implements the expected wrapped-native semantics:

- `deposit()` and `receive()` mint one unit of WNATIVE per unit of native currency;
- `withdraw(amount)` burns WNATIVE and returns the same native amount;
- ERC-20 transfers and allowances behave normally.

Local integration tests install `MockWrappedNative` at the canonical address. Its unrestricted `mint` helper is test-only and is not evidence about the live predeploy. The fork-gated native quote test uses the fixed canonical address and exercises real deposit, V3 routing, unwrap, and native payout behavior on the selected chain.

## Quote configuration

`ProtocolManager` registers WNATIVE as an active quote token with independently configured:

- virtual quote reserve;
- virtual token reserve;
- minimum token reserve;
- deploy fee;
- graduate fee;
- bonding-curve protocol fee rate;
- post-graduation DEX protocol fee rate;
- Uniswap V3 fee tier;
- LP fee protocol share in BPS.

The quote configuration is per token, so additional quote assets can use different fee tiers and fee splits.

## Module wiring

The deployment passes canonical WNATIVE to:

- `ProtocolManager` as an active quote token;
- `GiwaRouter` as `wrappedNative`;
- `QuoterV2` as its standard `WETH9` immutable;
- `CreatorFeeVault` for native unwraps;
- `TokenInfoLens` is deployed separately with the legacy V1 wrapped-native address, not canonical WNATIVE, because its fallback describes historical V1 registry entries;
- `Treasury` when it is deployed by its Safe script.

`TokenRegistry`, `V3PoolDeployer`, `LPManager`, `V3LiquidityActor`, and `V3SwapAdapter` resolve the token-specific quote through registered metadata rather than storing a second global wrapped-native address.

## Lifecycle

1. Deployment reuses canonical WNATIVE and registers its quote/V3 configuration.
2. A token is created with `DexType.UniswapV3` and WNATIVE as its quote.
3. Bonding-curve trading accumulates WNATIVE until graduation.
4. Graduation creates/registers the canonical V3 pool and transfers token/WNATIVE principal to `LPManager`.
5. `V3LiquidityActor` mints the two contract-v3-compatible positions.
6. `GiwaRouter` executes post-graduation V3 swaps and handles native wrap/unwrap at the boundary.
7. `LPManager.collect` converts token-side fees to the registered quote, pays the current protocol receiver share, and forwards the remainder to `CreatorFeeProcessor`.

## Failure handling

- Deployment reverts if canonical WNATIVE has no code.
- Deployment reverts if quote reserves, fee tier, LP split, V3 ownership, permissions, or downstream wiring are invalid.
- Token creation and graduation revert atomically when canonical pool metadata or position allocation is invalid.
- Native-aware receivers accept native currency only from their configured WNATIVE contract.
- Failed native payouts revert the entire claim or swap.

## Validation

- deployment harness reuses exactly `GIWA_WNATIVE`;
- router, quoter, vault, registry, and quote configuration agree on the same address;
- WNATIVE create → graduation → V3 buy → full-balance sell succeeds without protocol dust;
- real V3 LP fees are collected, token-side fees are swapped to WNATIVE, and the configured split is enforced;
- fork-gated coverage exercises the live canonical predeploy;
- storage layout checks confirm that terminology-only UUPS field renames do not move slots.
