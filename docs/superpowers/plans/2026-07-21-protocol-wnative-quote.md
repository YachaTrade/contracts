# Canonical WNATIVE Quote Implementation Record

## Status

Implemented for fresh deployments. The original plan to deploy a protocol-owned wrapper was superseded after confirming that the target chain already provides canonical WNATIVE at `0x4200000000000000000000000000000000000006`.

## Final decisions

- Reuse the canonical predeploy; never deploy a second wrapped-native token.
- Keep the address in source as `GIWA_WNATIVE`, not in an operator-controlled environment variable.
- Use project-owned `WNATIVE`/`wnative` terminology throughout source, scripts, tests, ABIs, and documentation.
- Preserve only upstream compatibility names such as Uniswap's `WETH9()` getter and Router02's `WETH()`/`...ETH` ABI.
- Support multiple quote tokens through `ProtocolManager`; WNATIVE is one registered quote, not a hardcoded quote inside V3 lifecycle modules.
- Treat the predeploy implementation as a chain trust boundary. Local mocks validate protocol integration, not live bytecode identity or administration.

## Implementation

### Deployment

`script/deploy/normal/Deploy.s.sol`:

- requires code at `GIWA_WNATIVE`;
- registers WNATIVE and its V3 settings in `ProtocolManager`;
- wires the same address into `QuoterV2`, `GiwaRouter`, and `CreatorFeeVault`;
- verifies quote configuration, `WETH9()` compatibility, router wiring, V3 ownership, roles, and admin rotation;
- prints `WNATIVE_ADDRESS`.

`script/deploy/normal/WrapNative.s.sol` wraps native currency through the same canonical address, and `DeployTreasurySafe.s.sol` imports `GIWA_WNATIVE`. `DeployTokenInfoLens.s.sol` instead reads `V1_WRAPPED_NATIVE`, because the Lens fallback reports the historical V1 registry's quote asset.

### Protocol lifecycle

- `BondingCurve` accepts WNATIVE as a configured quote and graduates only through canonical Uniswap V3.
- `TokenRegistry` records quote/pool/fee-tier metadata per launch token.
- `LPManager` and `V3LiquidityActor` retain the contract-v3 price, tick, range, and position math.
- `GiwaRouter` wraps/unwraps only at native entrypoints and does not sweep pre-existing balances.
- `LPManager.collect` swaps token-side fees into the registered quote, pays the current protocol share, and forwards the remainder to `CreatorFeeProcessor`.

### Fresh API terminology

- vault and Treasury public getters use `wnative()`;
- `DividendVault` uses `setWnative(address)` and `SetWnative`;
- `TokenInfoLens` exposes immutable `v1WrappedNative()` so the legacy fallback cannot be confused with canonical WNATIVE;
- `TransferHelper` uses `safeTransferNative` and `NativeTransferFailed`;
- no compatibility aliases are retained because this branch targets new deployments.

### Tests and fixtures

- `MockWrappedNative` supplies local deposit/withdraw behavior and a test-only mint helper.
- `ProtocolWnativeQuote.t.sol` verifies canonical address reuse and deployment wiring.
- `WnativeV3GraduationE2E.t.sol` proves create, graduation, post-graduation buy, and full-balance sell.
- `WnativeV3LpFeeCollectionE2E.t.sol` proves real V3 fee collection and quote distribution for both token orderings.
- `GiwaRouterNativeQuoteFork.t.sol` is fork-gated and uses the fixed canonical address to exercise live wrap/unwrap behavior.
- The full Foundry suite includes the LP principal-lock invariant.

## Operational prerequisites

Before a real deployment:

1. Confirm the RPC is for the intended chain.
2. Confirm code exists at `GIWA_WNATIVE`.
3. Independently confirm the chain's canonical predeploy implements the expected wrapped-native behavior and governance model.
4. Set the quote reserve, fee, V3 tier, LP split, receiver, and admin inputs.
5. Run deployment verification and record every emitted address.

The deployment script's `code.length` check is intentionally not described as a bytecode or backing attestation.
