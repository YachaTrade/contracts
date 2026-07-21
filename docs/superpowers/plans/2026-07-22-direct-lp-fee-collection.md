# Direct V3 LP Fee Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove FeeCollector and creator trade fees, then implement permissioned LPManager V3 fee collection that converts token fees to each launch token's quote token and distributes the configured protocol/creator shares.

**Architecture:** V3LiquidityActor retains the contract-v3 `burn(0) -> collect(max)` position mechanics. LPManager performs call-scoped balance accounting, swaps the token side through V3SwapAdapter with the approved `amountOutMin = 0` policy, pays ProtocolManager.feeReceiver, and invokes CreatorFeeProcessor. CreatorFeeProcessor uses ProtocolManager selector permissions for both setup and processing, eliminating immutable caller coupling and address prediction.

**Tech Stack:** Solidity 0.8.24, Foundry, UUPS proxies, EIP-1167 token clones, canonical Uniswap V3 core/periphery.

## Global Constraints

- `LPManager.collect(address[] calldata tokens)` is the only LP fee entrypoint and is `restricted nonReentrant`.
- Token-fee swaps use `amountOutMin = 0` by explicit user decision; full token input consumption remains mandatory.
- Never sweep pre-existing balances or donations; every transfer uses call-scoped exact balance deltas.
- Resolve quote tokens and `lpFeeProtocolShareBps` per token so one batch supports multiple quote tokens.
- Protocol share rounds down; CreatorFeeProcessor receives the remainder including dust.
- CreatorFeeProcessor authorization uses `ProtocolManager.canCall(msg.sender, address(this), msg.sig)`.
- FeeCollector, settlement, creator trade fees, and active NadFun V2 graduation dependencies are removed rather than disabled.
- The existing V3 factory is reused, but the partially deployed protocol graph is never upgraded or reused.
- Never inspect, print, commit, or expose `.env.testnet` or any private key.

---

### Task 1: Centralize CreatorFeeProcessor authorization in ProtocolManager

**Files:**
- Modify: `src/core/CreatorFeeProcessor.sol`
- Modify: `src/interfaces/ICreatorFeeProcessor.sol`
- Modify: `test/token/CreatorFeeProcessorV2.t.sol`
- Modify: `test/vault/VaultAttack.t.sol`

**Interfaces:**
- Consumes: `IProtocolManager.canCall(address,address,bytes4) returns (bool,uint32)`.
- Produces: `CreatorFeeProcessor(address protocolManager)`, selector-authorized `setup` and `processCreatorFee`.

- [ ] **Step 1: Write failing authorization and balance-delta tests**

Cover BondingCurve-only setup permission, LPManager-only processing permission, ProtocolManager owner override, taxed/short-credit quote-token rollback, vault callback rollback, donation isolation, and no processor residue.

- [ ] **Step 2: Run the focused suite and verify RED**

```bash
forge test --match-path test/token/CreatorFeeProcessorV2.t.sol -vv
```

Expected: constructor and immutable FeeCollector assumptions fail the new tests.

- [ ] **Step 3: Implement ProtocolManager-backed authorization**

Use one immutable `IProtocolManager protocolManager`, validate its code in the constructor, and gate both mutating entrypoints with:

```solidity
(bool allowed,) = protocolManager.canCall(msg.sender, address(this), msg.sig);
if (!allowed) revert NotAuthorized();
```

Pull and push quote tokens with sender/recipient balance snapshots, retain last-vault dust assignment, and require the processor balance to return to its call-entry value.

- [ ] **Step 4: Run focused validation**

```bash
forge test --match-path test/token/CreatorFeeProcessorV2.t.sol -vv
forge test --match-path test/vault/VaultAttack.t.sol -vv
forge fmt --check
git diff --check
```

- [ ] **Step 5: Commit**

```bash
git add src/core/CreatorFeeProcessor.sol src/interfaces/ICreatorFeeProcessor.sol test/token/CreatorFeeProcessorV2.t.sol test/vault/VaultAttack.t.sol
git commit -m "refactor: authorize creator fee processing through protocol manager"
```

### Task 2: Implement LPManager collect, swap, and distribution

**Files:**
- Modify: `src/core/LPManager.sol`
- Modify: `src/interfaces/ILPManager.sol`
- Create: `test/modules/LPManagerCollect.t.sol`
- Modify: `test/modules/LPManagerV3.t.sol`

**Interfaces:**
- Consumes: `IV3LiquidityActor.collectFees(address)`, `IV3SwapAdapter.exactInput(ExactInputParams)`, `IProtocolManager.getConfig`, `ICreatorFeeProcessor.processCreatorFee`.
- Produces: `collect(address[] calldata tokens)` and an event with raw token fee, direct quote fee, swapped quote, protocol quote, and creator quote.

- [ ] **Step 1: Write the failing collect suite**

Tests must cover unauthorized access, empty/duplicate batches, quote-only/token-only/two-sided fees, both address orderings, 50:50 and per-quote ratios, multi-quote batches, zero fees, donations, partial input, false balance reports, taxed transfers, vault callback failure, reentrancy, and allowance/residue cleanup.

- [ ] **Step 2: Run the suite and verify RED**

```bash
forge test --match-path test/modules/LPManagerCollect.t.sol -vv
```

Expected: `collect` is missing and the current `claimFees` stub reverts.

- [ ] **Step 3: Append fee-routing state and initialize it**

Append, without moving existing UUPS fields:

```solidity
address public creatorFeeProcessor;
address public v3SwapAdapter;
```

Change initialization to validate and store ProtocolManager, TokenRegistry, CreatorFeeProcessor, and V3SwapAdapter. Require the adapter's registry and later configured factory to match LPManager's canonical graph.

- [ ] **Step 4: Implement token-scoped collection**

For each token, load and validate canonical pool data, snapshot LPManager token/quote balances, call the actor, map token0/token1 results, and require exact balance increases. Swap exactly `tokenFee` through V3SwapAdapter with directional `TickMath` full-range price limit, `amountOutMin = 0`, `recipient = address(this)`, and `deadline = block.timestamp`. Require exact input consumption and quote output delta, then reset allowance to zero.

- [ ] **Step 5: Implement quote distribution**

Compute:

```solidity
uint256 protocolQuote = totalQuote * config.lpFeeProtocolShareBps / BPS;
uint256 creatorQuote = totalQuote - protocolQuote;
```

Pay the current ProtocolManager fee receiver, approve/call/reset CreatorFeeProcessor for the remainder, require entry balances are restored, and emit the collection event.

- [ ] **Step 6: Run focused validation**

```bash
forge test --match-path test/modules/LPManagerCollect.t.sol -vv
forge test --match-path test/modules/LPManagerV3.t.sol -vv
forge test --match-path test/modules/V3LiquidityActor.t.sol -vv
forge fmt --check
git diff --check
```

- [ ] **Step 7: Commit**

```bash
git add src/core/LPManager.sol src/interfaces/ILPManager.sol test/modules/LPManagerCollect.t.sol test/modules/LPManagerV3.t.sol
git commit -m "feat: collect and distribute V3 LP fees"
```

### Task 3: Remove creator trade fees and FeeCollector from the active curve

**Files:**
- Modify: `src/core/BondingCurve.sol`
- Modify: `src/interfaces/IBondingCurve.sol`
- Modify: `src/interfaces/IGiwaRouter.sol`
- Modify: `src/router/GiwaRouter.sol`
- Modify: `src/core/ProtocolManager.sol`
- Modify: `src/interfaces/IProtocolManager.sol`
- Modify: `test/core/BondingCurve.t.sol`
- Modify: `test/core/Fee.t.sol`
- Modify: `test/core/ProtocolManager.t.sol`
- Modify: `test/core/GiwaRouterCreate.t.sol`

**Interfaces:**
- Consumes: ProtocolManager curve protocol fee and sniping table.
- Produces: create/curve/config ABIs without creator trade-fee or settlement fields.

- [ ] **Step 1: Write failing no-creator-trade-fee tests**

Prove create parameters and curve state contain no creator fee rate, buys/sells charge only curve protocol plus applicable sniping fees, all charged quote goes directly to the current fee receiver, and views match execution.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
forge test --match-path test/core/Fee.t.sol -vv
forge test --match-path test/core/ProtocolManager.t.sol -vv
```

- [ ] **Step 3: Remove the FeeCollector module and fee calls**

Delete the import, module constant, `_create` setup call, settlement bypass, fee-config reads, and `_sendCombinedFee`. Calculate curve fees from `curveProtocolFeeRate(quoteToken)` plus the optional sniping rate, send protocol/sniping quote directly to feeReceiver, and preserve the sniping event.

- [ ] **Step 4: Remove creator trade-fee and settlement APIs**

Remove `creatorFeeRate` from curve/create/router structs and mappings. Remove ProtocolManager creator-rate allowlist state/functions/events and `settlementThreshold` from QuoteConfig plus add/update APIs. Keep `dexProtocolFeeRate`, V3 fee tier, and LP fee share.

- [ ] **Step 5: Run focused validation**

```bash
forge test --match-path test/core/BondingCurve.t.sol -vv
forge test --match-path test/core/Fee.t.sol -vv
forge test --match-path test/core/ProtocolManager.t.sol -vv
forge test --match-path test/core/GiwaRouterCreate.t.sol -vv
forge test --match-path test/core/GiwaRouter.t.sol -vv
forge fmt --check
git diff --check
```

- [ ] **Step 6: Commit**

```bash
git add src/core/BondingCurve.sol src/interfaces/IBondingCurve.sol src/interfaces/IGiwaRouter.sol src/router/GiwaRouter.sol src/core/ProtocolManager.sol src/interfaces/IProtocolManager.sol test/core
git commit -m "refactor: remove creator trade fees from the curve"
```

### Task 4: Delete FeeCollector and obsolete NadFun V2 runtime dependencies

**Files:**
- Delete: `src/core/FeeCollector.sol`
- Delete: `src/interfaces/IFeeCollector.sol`
- Delete: `test/fee/FeeCollector.t.sol`
- Delete: `test/fee/FeeCollectorAdminEvents.t.sol`
- Delete: active obsolete V2 pair/factory/router/FeeTo sources, scripts, interfaces, and dedicated tests that cannot compile without FeeCollector
- Modify: remaining generic external-adapter/vault interfaces only where a removed NadFun type was referenced

**Interfaces:**
- Consumes: the V3-only lifecycle from Tasks 2-3.
- Produces: a compiling source tree with no runtime `FeeCollector` or active NadFun V2 graduation dependency.

- [ ] **Step 1: Capture the dependency list**

```bash
rg -l "FeeCollector|IFeeCollector|MODULE_FEE_COLLECTOR|settlementThreshold" src script test
```

- [ ] **Step 2: Remove source and obsolete tests**

Delete FeeCollector itself and V2-only contracts/tests whose only supported fee or graduation path depends on it. Do not delete generic Uniswap V2 external integration code unless it imports a removed NadFun type.

- [ ] **Step 3: Prove the runtime tree is clean**

```bash
rg -n "FeeCollector|IFeeCollector|MODULE_FEE_COLLECTOR|SETTLER|settlementThreshold" src script test
forge build
```

Expected: no matches in active Solidity and a successful build.

- [ ] **Step 4: Commit**

```bash
git add -A src script test
git commit -m "refactor: remove fee collector and legacy V2 runtime"
```

### Task 5: Rewire quote-token scripts, deployment, and harnesses

**Files:**
- Modify: `script/deploy/normal/Deploy.s.sol`
- Modify: `script/deploy/normal/AddQuoteToken.s.sol`
- Modify: `script/deploy/normal/UpdateQuoteToken.s.sol`
- Modify: `test/SetUp.t.sol`
- Modify: `test/script/QuoteTokenScripts.t.sol`
- Modify: `test/integration/ProtocolWethQuote.t.sol`
- Modify: `test/integration/WethV3GraduationE2E.t.sol`

**Interfaces:**
- Consumes: the new Processor constructor, LPManager initializer/collect selector, and reduced ProtocolManager config.
- Produces: a fresh V3-only deployment graph with no FeeCollector output.

- [ ] **Step 1: Add failing deployment-harness assertions**

Assert Processor authority is ProtocolManager, BondingCurve has setup permission, LPManager has process permission, collector has collect permission, LPManager wiring matches Processor/adapter, only CreatorFeeVault is registered, and no FeeCollector module/log/address exists.

- [ ] **Step 2: Rewire deployment order and permissions**

Deploy CreatorFeeProcessor with ProtocolManager, deploy V3SwapAdapter before LPManager, initialize LPManager with Processor/adapter, then deploy the actor, curve, router, and vault graph. Register only V3 lifecycle modules. Replace optional `SETTLER` with optional `COLLECTOR` defaulting to MULTISIG, and grant only `LPManager.collect.selector`.

- [ ] **Step 3: Remove stale environment/config fields**

Stop reading `SETTLEMENT_THRESHOLD`, `CREATOR_FEE_RATES`, and `SETTLER`. Preserve `LP_FEE_PROTOCOL_SHARE_BPS`, multiple quote tokens, canonical WETH, and V3 factory owner/tier guards.

- [ ] **Step 4: Run focused validation**

```bash
forge test --match-path test/script/QuoteTokenScripts.t.sol -vv
forge test --match-path test/integration/ProtocolWethQuote.t.sol -vv
forge test --match-path test/integration/WethV3GraduationE2E.t.sol -vv
forge fmt --check
forge build
git diff --check
```

- [ ] **Step 5: Commit**

```bash
git add script/deploy/normal test/SetUp.t.sol test/script/QuoteTokenScripts.t.sol test/integration/ProtocolWethQuote.t.sol test/integration/WethV3GraduationE2E.t.sol
git commit -m "feat: deploy direct LP fee routing"
```

### Task 6: Add full lifecycle and security regression coverage

**Files:**
- Create or modify: `test/integration/WethV3LpFeeCollectionE2E.t.sol`
- Modify: `test/invariant/LPPrincipalLock.invariant.t.sol`
- Modify: remaining compile-affected V3 router, vault, and attack tests

**Interfaces:**
- Consumes: final V3-only graph.
- Produces: end-to-end proof of graduation, trading, collection, splitting, vault receipt, and principal lock.

- [ ] **Step 1: Build the real V3 E2E**

Create and graduate tokens on both address orderings, execute post-graduation swaps to accrue both fee sides, collect, and assert launch-token fee is fully swapped, protocol quote reaches the current fee receiver, creator quote reaches the configured CreatorFeeVault, ratios match per quote token, and all LP principal remains in the actor positions.

- [ ] **Step 2: Add adversarial cases**

Cover callback reentrancy, malformed pool metadata, taxed/short-credit behavior, processor/vault callback revert, multi-token atomic rollback, pre-existing donations, and a feeReceiver update between accrual and collection.

- [ ] **Step 3: Run broad validation**

```bash
forge test --match-path test/integration/WethV3LpFeeCollectionE2E.t.sol -vv
forge test --match-path test/invariant/LPPrincipalLock.invariant.t.sol -vv
forge test
forge fmt --check
forge build
git diff --check
```

- [ ] **Step 4: Commit**

```bash
git add test src script
git commit -m "test: prove direct V3 LP fee distribution"
```

### Task 7: Independent review, fresh redeployment, and on-chain verification

**Files:**
- Ignored local input: `.env.testnet`
- Generated Foundry output: `broadcast/`

**Interfaces:**
- Consumes: final reviewed contracts and existing `V3_FACTORY`.
- Produces: fresh deployed addresses, successful receipts, and read-only post-state verification.

- [ ] **Step 1: Run independent code and security reviews**

Review direct asset flow, authorization, UUPS initialization/storage, canonical pool validation, swap callback behavior, allowance reset, donation isolation, and atomic rollback. Resolve all actionable findings and rerun focused/full tests.

- [ ] **Step 2: Safely update ignored environment inputs**

Remove reliance on obsolete settlement/creator-rate inputs without printing the file. Reuse Factory `0x00a131Cf1fbEE9b02C4632756a813A32BC250849`, canonical WETH, fee tier 10000, and the approved quote configuration.

- [ ] **Step 3: Simulate the fresh deployment**

```bash
source .env.testnet
forge script script/deploy/normal/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" -vv
```

Expected: every internal verification passes and no FeeCollector address is emitted.

- [ ] **Step 4: Broadcast and verify receipts**

```bash
forge script script/deploy/normal/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --slow -vv
```

Resume safely until every generated transaction has a successful receipt. Never reuse the prior protocol graph.

- [ ] **Step 5: Verify post-state and print addresses**

Check runtime code, ProtocolManager owner/fee receiver/quote config, Factory owner/tier, LPManager actor/adapter/processor wiring, Processor selector permissions, collect permission, Router wiring, CreatorFeeVault-only registration, and absence of FeeCollector. Print the complete public address list and deployment transaction hashes.
