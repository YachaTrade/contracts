# AGENTS.md

## Project

- GIWA Launchpad is a bonding-curve token launchpad that graduates into canonical Uniswap V3 pools.
- Stack: Solidity `0.8.24`, Foundry, UUPS proxies, and EIP-1167 clones.

- UUPS proxies: `BondingCurve`, `ProtocolManager`, `LPManager`, `TokenRegistry`, `V3PoolDeployer`, `VaultRegistry`, `FeeCollector`, `CreatorFeeVault`, `Treasury`, and `GiwaRouter`. `CreatorFeeProcessor` is a plain non-upgradeable contract.
- `Token` is an EIP-1167 clone; `TokenInfoLens` is an immutable integration.

## Structure

- `src/core/` holds lifecycle managers; `src/router/` owns user-facing routing and callbacks.
- `src/token/` contains the clone implementation; `src/vault/` contains the fee vaults; `src/integration/` contains external protocol adapters.
- `src/interfaces/` and `src/libraries/` define shared boundaries and math/helpers.
- `script/` contains deployment and upgrade scripts; `deploy/`, `abis/`, and `metadata/` contain deployment artifacts.
- `test/` is split into unit, integration, invariant, fork, harness, mock, and utility suites.

## Commands

```shell
forge fmt
forge fmt --check
forge build
forge test
forge test --match-path test/core/GiwaRouter.t.sol -vvv
forge test --match-path test/invariant/LPPrincipalLock.invariant.t.sol -vvv
RUN_FORK_TESTS=true forge test --match-path test/fork/GiwaRouterNativeQuoteFork.t.sol -vvv
```

## Repository References

- Product and architecture: `README.md`, `PRODUCT.md`, `docs/ARCHITECTURE.md`, and both `docs/PROTOCOL_FLOW*` files.
- Testing and APIs: `TEST.md`, `docs/CONTRACTS.md`, and `docs/contracts/{en,ko}/`; release notes live in `CHANGELOG.md`.

## Solidity Conventions

- Prefer explicit, readable Solidity. Apply DRY to established duplication, but avoid premature abstractions.
- Prefer `quoteIn`, `quoteOut`, `tokenIn`, and `tokenOut`; avoid redundant `Amount` suffixes and plural direction names such as `tokensOut`.
- Name fee stages explicitly, for example `quoteInAfterProtocolFee` and `quoteInAfterSnipingFee`.
- Avoid vague accounting words such as `effective`, `gross`, `net`, `actual`, `total`, and `expected` unless an existing API requires them.
- Use full names such as `reserve0`, `config`, and `feeReceiver`. Use a trailing `_` only to avoid state-variable shadowing.
- Name fees by type: `lpFee`, `protocolFee`, `snipingFee`, `deployFee`, and `graduateFee`.
- Do not rename unrelated existing identifiers solely to satisfy these conventions.

## Security Checklist

- Use the `solidity-security` skill for substantive smart-contract edits or reviews.
- Access control on every state-changing and administrative function.
- Reentrancy and external-call ordering around transfers, hooks, swaps, and callbacks.
- UUPS initializer safety and storage-layout compatibility.
- ERC-20 balance-delta accounting for V3 fee collection and donation isolation.
- Native-transfer refunds, failure behavior, and slippage around variable external execution.
- Graduation and bonding-curve boundary cases.

## Native Quote And WNATIVE

- Let existing tooling consume ignored local `.env` values; never inspect or hardcode them. Expected keys include `RPC_URL`, `UNISWAP_V3_FACTORY`, and `WNATIVE`.
- Require the curve quote token to equal the Router's configured WNATIVE before asset movement.
- Wrap only the call-scoped routed quote amount and refund excess native without sweeping pre-existing Router balances.
- Accept native value in `receive()` only from WNATIVE during `withdraw`.
- Gate fork tests using deployed WNATIVE behind `RUN_FORK_TESTS=true`.

## Validation And Reporting

- Documentation-only changes: inspect the Markdown and run `git diff --check`.
- Narrow Solidity changes: run `forge fmt --check`, `forge build`, and focused tests.
- Broad protocol changes: also run `forge test`; fork-dependent changes also require the relevant `RUN_FORK_TESTS=true` suite.
- Review storage layout for every UUPS change and run invariant coverage for lifecycle, fee, or liquidity-accounting changes.
- Report exact failed or skipped commands and any remaining fork or deployment uncertainty.
