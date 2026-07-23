# LP Fee Collection and FeeCollector Removal Design

**Status:** Approved for implementation

**Date:** 2026-07-22

**Target:** Fresh GIWA testnet deployment; existing protocol addresses will not be upgraded or reused

## Goal

Replace the disabled LP fee path with a canonical Uniswap V3 collection pipeline:

```text
V3 positions
  -> LPManager.collect
  -> convert collected launch-token fees to the pool quote token
  -> send the quote-token protocol share to ProtocolManager.feeReceiver
  -> call CreatorFeeProcessor.processCreatorFee with the quote-token remainder
  -> distribute the creator share across the token's configured vaults
```

`FeeCollector` and creator trade fees are removed completely. `ProtocolManager` remains the single source of truth for selector permissions, fee receivers, and quote-token-specific LP fee split ratios.

## Public Interfaces

### LPManager

`LPManager` exposes the contract-v3-compatible function name and batch shape:

```solidity
function collect(address[] calldata tokens) external;
```

The function is `restricted` through `ProtocolManager.canCall` and `nonReentrant`. It does not accept minimum output or deadline parameters. Token-fee swaps intentionally use `amountOutMin = 0`, as explicitly selected for this deployment. Full token-fee consumption is still mandatory; a partial-input swap reverts the entire transaction.

The disabled V2-style `claimFees(address)` stub is removed from `LPManager` and `ILPManager`.

### CreatorFeeProcessor

`CreatorFeeProcessor` stores only an immutable `ProtocolManager` address for authorization. It does not store a FeeCollector, LPManager, or BondingCurve authority.

Both state-changing entrypoints use selector-scoped authorization:

- `BondingCurve -> CreatorFeeProcessor.setup`
- `LPManager -> CreatorFeeProcessor.processCreatorFee`

Authorization is checked with:

```solidity
ProtocolManager.canCall(msg.sender, address(this), msg.sig)
```

The existing ProtocolManager owner override remains available through the established `canCall` behavior.

## Collection Data Flow

For every launch token in `collect(tokens)`:

1. Load `TokenRegistry.TokenInfo` and require an active, registered Uniswap V3 token with a canonical pool, quote token, creation-time fee tier, configured factory, and matching live pool metadata.
2. Snapshot only the LPManager balances for that launch token and its quote token.
3. Call the existing `V3LiquidityActor.collectFees(pool)`. The actor keeps the contract-v3 V3 mechanics: it pokes both permanent positions with `burn(..., 0)` and collects the maximum owed fees. Its existing canonical-pool, reentrancy, and exact balance-delta checks remain intact.
4. Derive `tokenFee` and `directQuoteFee` from the actor return values according to actual pool token ordering. Require exact LPManager balance increases. Pre-existing balances and donations are excluded.
5. When `tokenFee > 0`, approve exactly that amount to `V3SwapAdapter` and call `exactInput` directly, never through `GiwaRouter`. The swap uses:
   - the registered launch token and quote token;
   - the canonical creation-time fee tier;
   - `recipient = LPManager`;
   - `amountOutMin = 0`;
   - the full-range directional V3 price limit;
   - `deadline = block.timestamp`.
6. Require `amountInUsed == tokenFee`, require the reported quote output to equal the exact LPManager quote balance delta, and reset the adapter allowance to zero.
7. Set `totalQuoteFee = directQuoteFee + swappedQuoteFee`.
8. Read the current quote-token configuration from ProtocolManager. Calculate:
   - `protocolQuote = totalQuoteFee * lpFeeProtocolShareBps / 10_000`;
   - `creatorQuote = totalQuoteFee - protocolQuote`.
   The creator side receives rounding dust, so no quote fee remains stranded.
9. Transfer `protocolQuote` to the current `ProtocolManager.feeReceiver()` with exact sender/recipient balance-delta checks.
10. Approve exactly `creatorQuote` to CreatorFeeProcessor, call `processCreatorFee(token, quoteToken, creatorQuote)`, reset approval to zero, and require no call-scoped residue in LPManager.
11. Emit one auditable event containing the token, pool, raw token fee, direct quote fee, swapped quote fee, protocol quote, and creator quote.

The launch-token swap itself generates new V3 LP fees. Those fees remain in the positions for the next collection; collection never recurses.

## Multiple Quote Tokens

Collection never assumes WNATIVE. Each launch token resolves its quote token through TokenRegistry, and each quote token resolves its LP split through ProtocolManager. A single batch may contain tokens with different quote tokens and different `lpFeeProtocolShareBps` values. CreatorFeeProcessor receives the resolved quote token for every token-specific distribution.

## FeeCollector and Creator Trade-Fee Removal

The following concepts are deleted rather than disabled:

- `FeeCollector` implementation and interface;
- FeeCollector deployment, proxy, address prediction, module registration, permissions, verification, ABI, and logging;
- FeeCollector settlement thresholds, settler permissions, and settlement flows;
- BondingCurve FeeCollector setup and settlement bypasses;
- creator trade-fee rate fields, create parameters, allowlists, calculations, events, and tests.

Bonding-curve protocol fees continue to use `ProtocolManager.curveProtocolFeeRate` and are sent directly to `feeReceiver`. Sniping penalties also continue to go directly to `feeReceiver`. Graduated GiwaRouter trades retain the independent `dexProtocolFeeRate` behavior.

Obsolete V2 pair/factory/router code and tests that require FeeCollector are removed instead of retaining an undeployable dead FeeCollector stack. This matches the already selected V3-only fresh-deployment policy.

## Deployment and Permissions

The fresh deployment has no circular address prediction:

1. Deploy ProtocolManager, Token implementation, TokenRegistry, canonical V3 dependencies, and CreatorFeeProcessor.
2. Initialize LPManager with ProtocolManager, TokenRegistry, CreatorFeeProcessor, and V3SwapAdapter.
3. Deploy BondingCurve, V3LiquidityActor, routing, and the CreatorFeeVault-only vault graph.
4. Register all non-FeeCollector modules.
5. Grant selector permissions through ProtocolManager:
   - BondingCurve may call CreatorFeeProcessor.setup;
   - LPManager may call CreatorFeeProcessor.processCreatorFee;
   - the configured collector may call LPManager.collect;
   - existing BondingCurve lifecycle permissions remain.
6. Transfer final administration using the existing same-admin-safe testnet handoff.

The already deployed V3 factory remains reusable. The partially deployed protocol graph is not considered valid and will not be upgraded; the corrected graph receives entirely new addresses.

## Atomicity and Failure Behavior

One token failure reverts the entire batch. Actor collection, token-to-quote swap, protocol transfer, processor pull, vault transfers, and vault callbacks are atomic. This prevents collected assets from being stranded between stages.

Required protections include:

- canonical factory/pool/token/fee-tier validation;
- LPManager and actor reentrancy guards;
- call-scoped balance-delta accounting;
- exact adapter allowances followed by zero allowance;
- full token-fee input consumption;
- no sweeping of donations or unrelated balances;
- rollback on taxed, rebasing, short-credit, callback-reverting, or malformed tokens;
- selector-scoped authorization for collection and processor calls.

The accepted residual risk is price manipulation during a permissioned collection because the selected API supplies no `amountOutMin`. Operational collectors must avoid visibly manipulated pools, but the contract intentionally does not enforce a minimum quote output.

## Acceptance Tests

Implementation is complete only when tests prove:

- unauthorized collect and processor calls revert;
- quote-only, token-only, and two-sided fee collection;
- both token0/token1 orderings;
- full token-fee conversion with no token or approval residue;
- 50:50 split and different per-quote-token split ratios;
- multi-token, multi-quote batches;
- protocol receiver changes are honored at collection time;
- CreatorFeeProcessor distributes to one or multiple vaults with final-vault dust handling;
- pre-existing LPManager, actor, adapter, and processor donations are isolated;
- partial swap, false return, short credit, taxed transfer, reentrancy, and vault callback failure roll back atomically;
- LP principal remains permanently locked;
- graduation, post-graduation trading, collection, protocol receipt, and creator-vault receipt pass end to end;
- deployment contains no FeeCollector address, module, permission, or runtime dependency.
