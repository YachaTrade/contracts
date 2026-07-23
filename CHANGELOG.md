# Changelog

All notable changes to the NadFun V2 contract system will be documented in this file.

## [Unreleased]

### Gas / Architecture — `FeeTo` executes zap swaps directly against `NadFunPair` (drops router dependency)

- **`FeeTo` no longer routes its zap buy / re-sell through `NadFunRouter`; it swaps directly against the `NadFunPair`.** Both legs now use a single internal `_swapExactIn(pair, tokenIn, amountIn)` helper that mirrors `NadSwapAdapter.swap` — `safeTransfer` the input straight to the pair, read `pair.getAmountOut`, then `pair.swap` in the correct direction. This removes two layers of call indirection (router → adapter → pair), the per-swap `forceApprove(router, x)` / `forceApprove(router, 0)` approval round-trips, and the redundant `tokenRegistry`/graduation lookups the router performs — none of which FeeTo needs, since it already verifies `pair`/`quote`/`token` via `_verifyPair` and operates only on graduated pairs. **Swap fees are unchanged:** protocol + creator fee are charged inside `NadFunPair._swap` (`_collectFee`), so going direct yields identical settlement (`refund`/`excess`/`quoteOut`) — the win is gas and one fewer dependency, not fee savings.
- **Storage layout and selectors are preserved — `FeeTo` is a live mainnet UUPS proxy** (`0x9a6B8ADdFEC15A27C54570033c1EE02Af1d2c7E6`). The now-unused `router` storage variable is **retained (deprecated)** to keep the UUPS slot layout intact; its `router()` getter and the `initialize(protocolManager, router)` signature/zero-check stay so `DeployFeeTo.s.sol` and existing tests are unaffected. The `claim((address,address,address,uint256)[],uint256)` selector (`0xb19e5036`, already granted to the CLAIM_BOT operator) is kept verbatim.
- **`deadline` protection restored.** With the router's `ensure(deadline)` modifier out of the path, `claim` now enforces `block.timestamp <= deadline` itself via a new `IFeeTo.ExpiredDeadline` error (named to match the router). The `deadline` parameter is retained both for selector stability and to keep this guarantee.
- **Tests.** Existing `test/core/FeeTo.t.sol` cases pass unchanged (fees and `getAmountOut` are identical, so settlement is identical); added `test_claim_revertsOnExpiredDeadline` for the restored guard. See `docs/plans/2026-06-08-feeto-direct-pairswap-design.md`.
- **Upgrade tooling.** Added `script/UpgradeFeeToSafe.s.sol`. Since `FeeTo._authorizeUpgrade` is `restricted` (authority = ProtocolManager) and the live mainnet `PM.owner()` is a Safe multisig that cannot sign forge broadcasts, the script deploys the new implementation from a deployer EOA (permissionless) and prints the `upgradeToAndCall(newImpl, "")` calldata (target = FeeTo proxy) for the Safe to submit via Transaction Builder. It sanity-checks `PM.owner() == MULTISIG`, reads/prints the old impl from the ERC1967 slot, and reads keys via `vm.envUint` (no `--private-key` on the CLI). The upgrade is layout-compatible (deprecated `router` slot retained); the printed post-execution checklist verifies the impl slot and that `router()` is unchanged.

### Periphery — standalone NadFunRouter02 (UniswapV2Router02-compatible liquidity + fee-aware swap)

- **Added `src/router/NadFunRouter02.sol` and `src/interfaces/INadFunRouter02.sol`** — a new UUPS proxy that covers the UniswapV2Router02 surface (createPair, addLiquidity/addLiquidityETH, removeLiquidity/removeLiquidityETH/\*WithPermit/\*SupportingFeeOnTransferTokens, six swap variants + three FeeOnTransfer swap variants) for graduated NadFunPairs. Separated from `NadFunRouter` because combining both routers exceeds the EIP-170 24 KB contract size limit; `NadFunRouter` (bonding-curve lifecycle + buy/sell) is unchanged. `NadFunRouter02` depends only on `NadFunFactory` and WNATIVE — no BondingCurve, no TokenRegistry. Deploying it requires no multisig and no upgrade of any existing contract; `script/DeployRouter02.s.sol` handles the fresh deploy.
- **Pre-graduation safety is enforced by `Token.sol`**, not by router-level guards. `Token.transferFrom` reverts with `TransferToPairBeforeGraduation` when the destination is the pair address before graduation, so `addLiquidity` on a pre-graduation pair naturally reverts without any additional check in `NadFunRouter02`. `createPair` is permissionless and forwards directly to `NadFunFactory`.
- **Swap amounts are fee-aware via per-hop pair delegation.** `getAmountsOut`/`getAmountsIn` (and the internal swap executors) delegate each hop to `NadFunPair.getAmountOut`/`getAmountIn`, which account for LP fee (0.25%), protocol fee, and creator fee (buy/sell asymmetric). Using a vanilla 0.3% constant would produce amounts that fail the pair's k-invariant check and revert. The pure 3-argument `getAmountOut`/`getAmountIn` views apply LP fee only and carry a documented caveat that they underestimate the actual fee deduction on NadFunPairs with active protocol/creator fees.
- **Added `src/libraries/NadFunLibrary.sol`** — router helper library. Key divergence from the standard UniswapV2Library: `pairFor` resolves the pair address via `INadFunFactory.getPair(tokenA, tokenB)` instead of recomputing the CREATE2 init-code hash, because NadFunPair is deployed as an EIP-1167 minimal proxy clone for which the init-code-hash trick produces a wrong address. `getAmountsOut`/`getAmountsIn` delegate per-hop to the pair's view functions rather than recomputing internally.
- **`WETH()` returns WNATIVE; `...ETH` naming kept for ABI compatibility.** The `WETH()` getter and `addLiquidityETH`/`swapExactETHForTokens`/etc. family use the Sushi/PancakeSwap Router02 naming convention so that aggregators and SDKs expecting the standard interface can integrate without changes. LVMON (raw native) wrapping/unwrapping is handled via `IWrappedNative` exactly as in `NadFunRouter`.
- **Tests:** `test/router/RouterLiquidity.t.sol` (addLiquidity, removeLiquidity, permit, FeeOnTransfer variants), `test/router/RouterSwap.t.sol` (all six swap modes + FeeOnTransfer variants, slippage, deadline), `test/libraries/NadFunLibrary.t.sol` (pairFor, getReserves, quote, getAmountsOut, getAmountsIn).

### Integration — `TokenInfoLens` view contract for V1/V2 token classification (#203)

- **Added `src/integration/TokenInfoLens.sol`**, a stateless immutable view contract that lets off-chain SDKs and indexers resolve any token address to `(version, quoteToken)` in a single RPC call. `version` is `enum {None, V1, V2}` where V1 = legacy `contract-v3` `TokenRegistry`, V2 = this codebase's `TokenRegistry`. For V1 matches the lens reports the configured legacy V1 wrapped-native quote; for V2 matches it forwards `v2Registry.getTokenInfo(token).quoteToken`; misses return `(None, address(0))`. Branching is V2-first so the implausible overlap case still resolves deterministically. Both `getTokenInfo(address)` and a batch variant `getTokenInfos(address[])` are exposed.
- **Cross-version interop is contained in a minimal V1 adapter.** `src/integration/interfaces/ITokenRegistryV1.sol` redeclares only `tokenInfos(address)` so the `^0.8.24` codebase can statically call the `^0.8.12` V1 registry without importing it. The lens takes V1 registry, V2 registry, and `v1WrappedNative` as immutable constructor args (no storage, no admin, no upgrade). The V1 fallback is intentionally distinct from the fresh deployment's canonical WNATIVE.
- **Coverage.** `test/integration/TokenInfoLens.t.sol` covers 12 cases — constructor zero-address guards, immutable getter wiring, the four lookup branches, V2 priority on overlap, batch order preservation, and empty batch. `test/fork/TokenInfoLensFork.t.sol` adds fork-gated coverage against the real legacy V1 wrapped-native address. `test/mocks/MockTokenRegistryV1.sol` mirrors only the V1 ABI shape (`register` and `registerFull` helpers).
- **Deployment + tooling.** `script/deploy/normal/DeployTokenInfoLens.s.sol` reads `PRIVATE_KEY`, `V1_TOKEN_REGISTRY`, `TOKEN_REGISTRY`, and `V1_WRAPPED_NATIVE`, then broadcasts via `vm.startBroadcast(pk)` so the secret never lands in a CLI argument. `TokenInfoLens` is not part of the canonical ABI extraction manifest and must be consumed from its Foundry artifact when deployed separately.
- **Fresh-deployment compatibility.** The immutable getter is `v1WrappedNative()`. Previously deployed immutable Lens instances predate this API and are historical only; new clients must use a newly deployed Lens address from `DeployTokenInfoLens.s.sol`.

### UX — Native currency unwrap on `CreatorFeeVault` and `GiftVault` claims

- **`CreatorFeeVault.claim` and `GiftVault.claim` now unwrap WNATIVE to native currency when the registered quote token equals the configured `wnative`.** Both vaults gained a new `wnative` storage variable set at `initialize` (`address(0)` disables the unwrap branch — claims fall back to ERC20 `safeTransfer` for all quotes). When unwrap fires, the vault calls `IWrappedNative.withdraw(amount)`, then forwards via `recipient.call{value: amount}("")`; native-transfer failure reverts with `NativeTransferFailed` so the claim state rolls back and ops can rotate the recipient (`setCreator` / `setReceiver`) and retry. A `receive() external payable` accepts native only when `msg.sender == wnative`, otherwise reverts `UnexpectedNative` to prevent stranded native from accidental funding. `claim` is wrapped with `nonReentrant` (OZ `ReentrancyGuard` — ERC-7201 namespaced storage, proxy-safe) on top of the existing CEI ordering (`balance = 0` before the external call) for defense in depth.
- **Fresh deployment wiring uses canonical WNATIVE.** `Deploy.s.sol` passes the compiled `GIWA_WNATIVE` constant to `CreatorFeeVault`; no wrapped-native address is read from the environment. `GiftVault`, when deployed separately, must receive the intended WNATIVE address in its initializer.
- **Tests cover both branches.** `test/vault/CreatorFeeVault.t.sol` and `test/vault/GiftVault.t.sol` add `test_initialize_setsWnative`, `test_claim_unwrapsWhenQuoteIsWnative`, `test_claim_revertsWhenNativeTransferFails` (using a `RevertingReceiver` helper), and `test_receive_revertsFromNonWnative`. Standalone test setups (`BondingCurveV2.t.sol`, `FeeCollector.t.sol`, `GiftVault.t.sol`) now deploy a `MockWrappedNative` so production wiring is mirrored. Vault casts wrap with `payable(...)` to accommodate the new `receive`. Updated `docs/contracts/{en,ko}/vault/CreatorFeeVault.md` and `GiftVault.md` (CreatorFeeVault EN/KO docs were also brought in line with the current claim-model implementation as part of this update).

### Architecture — Per-block sniping penalty lookup table (block.number based)

- **Anti-sniping rewritten from a `block.timestamp`-based linear decay to a `block.number`-indexed lookup table.** `ProtocolManager` now stores `_snipingPenaltyTable` (a `uint256[]` of BPS values), and `getSnipingPenalty(uint256 createdAtBlock)` returns `_snipingPenaltyTable[block.number - createdAtBlock]` (0 once elapsed exceeds the table length). The new admin entrypoint is `setSnipingPenaltyTable(uint256[])`; the previous `setSnipingPenaltyConfig(duration, penaltyPerMinute)` / `snipingDuration()` / `snipingPenaltyPerMinute()` surface and `SnipingPenaltyUpdate` event are removed in favor of `SnipingPenaltyTableUpdate(uint256[] penaltyTable)`. Same-block buys (`block.number == createdAtBlock`) map to index 0 — peak penalty applies. `block.number` removes the validator-timestamp manipulation vector and lets ops express arbitrary non-linear curves (e.g. heavy first-block deterrent, fast decay, then a small tail) without redeploying.
- **`Curve.createdAt` (uint64 timestamp) renamed to `Curve.createdAtBlock` (uint64 block number).** `BondingCurve._initCurve` now records `block.number` and `_getSnipingFeeRate` looks up the penalty by `createdAtBlock`. ABI-breaking for any indexer/SDK that read the old field — there are no live tokens against this audit branch so no migration shim is provided.
- **Deploy script ships the production curve.** `Deploy.s.sol` now configures `[8000, 4000, 2000, 1500, 1000, 1000, 500]` BPS for blocks 0..6 (80%/40%/20%/15%/10%/10%/5%, then 0% from block 7) and `_verify` walks the table entry-by-entry. New standalone `script/SetSnipingConfig.s.sol` retunes the curve on a deployed `ProtocolManager` post-deploy without redeploying.
- **Tests retargeted at the per-block table.** `test/SetUp.t.sol` seeds the production table; `_skipAntiSniping` now also `vm.roll`s past the window. `test_antiSniping_perBlockTableMatchesCurve` validates the full curve, `test_antiSniping_sameBlockUsesIndexZero` covers the elapsed=0 edge, and the legacy "fee >= BPS reverts" tests (which assumed the old 99% peak) are repurposed to verify that buys still succeed at the new 80% peak with the sniping fee actually charged. Other suites switched their `vm.warp(... 100 minutes)` skip-sniping calls to also `vm.roll(block.number + 10)`. See `docs/plans/2026-05-07-sniping-block-lookup-design.md` for the full design.

### Observability — Emit `Create` before initial buy in `BondingCurve.create`

- **`BondingCurve.create` now emits the `Create` event before the initial buy executes** (previously emitted after `_initialBuy`). Off-chain indexers ingesting the create-with-initial-buy flow now see `Create → Buy` in chronological order, matching the on-chain sequence and removing the need for indexer-side reordering. The function body was split into two scoped blocks (`totalIn`/`deployFee_` block, then a `Curve storage curve` block for the emit) to keep the EVM stack within the 16-slot reach window without `viaIR`. Behavior is unchanged.

### Tooling — UUPS upgrade script for `BondingCurve`

- **Added `script/UpgradeBondingCurve.s.sol`** mirroring `UpgradeRouter.s.sol`. Deploys a fresh `BondingCurve` implementation and calls `upgradeToAndCall` on the proxy. Authority check uses `bc.hasRole(DEFAULT_ADMIN_ROLE, signer)` (BondingCurve uses AccessControl, not Ownable); signer is `MULTISIG_PRIVATE_KEY`. New env variable `V2_BONDING_CURVE` carries the proxy address.

### Observability — Emit full vault configuration in `CreatorFeeProcessor.Setup`

- **`CreatorFeeProcessor.Setup` event now emits the full `VaultSlot[]` (vault address + bps) instead of only `vaults.length`.** Off-chain indexers can now reconstruct per-token vault configuration (which vaults, at what BPS split) directly from event logs, without an additional `getVaults(token)` RPC call. `setup` is a one-time call per token, so the extra log data is bounded by `MAX_VAULTS = 5`. Updated `test_setup_emitsEvent` and contract documentation (`docs/contracts/en|ko/core/CreatorFeeProcessor.md`) to match the new signature and corrected stale event names (`VaultsConfigured` → `Setup`, `VaultDistributed` → `Distribute`, `VaultCallbackFailed` → `CallbackFail`).

### Security — Restrict `FeeCollector.settle` to an authorized settler

- **`FeeCollector.settle` is now gated by `AccessManaged.restricted`** so it can only be called by addresses that have been granted the selector via `ProtocolManager.setOperatorPermission`. Settlement was previously permissionless; since the `_settling[pair]` flag waives creator/protocol fees on the pair and triggers vault buyback/zap swaps with no slippage/TWAP guard, an arbitrary caller could time settlement to sandwich those forced swaps. Restricting the trigger to an operator-controlled settler removes the public timing vector while keeping `settlementThreshold` as the per-settle size cap. Deploy script now takes an optional `SETTLER` env var and grants it `FeeCollector.settle` permission; the shared test SetUp grants the permission to the test contract.

### Security — Enforce exact-out output in NadFunRouter pre-graduation paths

- **`exactOutBuy`, `exactOutBuyWithNative`, `exactOutSell`, `exactOutSellToNative` now assert the realized output matches the requested `amountOut` on the pre-graduation curve path** and revert with `InsufficientOutput` otherwise. Previously, if `BondingCurve.buy` / `sell` silently clamped at the graduation boundary (excess quote routed to `feeReceiver`, tokenOut capped to `availableTokenOut`), the router still succeeded and returned fewer tokens / less quote than the caller asked for. Exact-out callers now get a clean revert in that case. Standard exact-in paths (with `amountOutMin`) are unchanged.

### Security — Block `NadFunPair.sync` before launch

- **`NadFunPair.sync` now reverts with `"NadFunPair: NOT_LAUNCHED"` when `totalSupply() == 0`.** An attacker could otherwise defeat our pre-`addLiquidity` skim defense by donating quote tokens to the pre-graduation pair, calling `sync()` to lift reserves to match the balance, and leaving `balance − reserve = 0` for `skim()` to no-op. With `sync()` blocked pre-launch, the reserves stay zero and the skim path restores the donation to `feeReceiver` at graduation as intended. Post-launch `sync()` behaves as the standard Uniswap V2 helper. Added regression test `test_graduation_sync_revertsPreLaunch`.

### Security — Always call `IVault.setup` during token creation

- **`BondingCurve._setupVaults` now calls `IVault.setup` unconditionally instead of skipping when `setupData.length == 0`.** Empty-setupData previously left configuration-requiring vaults (e.g. `CreatorFeeVault`, `GiftVault`) uninitialized; fees delivered later were silently ignored by `afterDeposit`, with no `claim()` or `setCreator()` recovery path. Vaults that require configuration now revert at create time (via `abi.decode` on empty bytes), failing the create cleanly; no-op `setup` vaults (`BurnVault`, `LPVault`) are unaffected. Added regression test `test_create_revertsOnEmptySetupDataForCreatorFeeVault`.

### Security — Block settle during pair lock

- **`FeeCollector.settle` now reverts with `PairLocked` when called inside a `NadFunPair.lock`-guarded operation.** An attacker could otherwise call `settle` from a flash-swap callback while the pair was locked; `CreatorFeeProcessor.processCreatorFee` would transfer funds to each vault, the vault's `afterDeposit` callback would reenter the pair (swap/addLiquidity), hit the lock guard, and revert — but the `try/catch` in `CreatorFeeProcessor` would swallow the revert, stranding the already-transferred funds in the vaults. Added `INadFunPair.isLocked()` view so external callers can check the guard state without racing against it.

### Security — Validate dexType adapter on create

- **`BondingCurve._create` now rejects any `dexType` that has no adapter registered in `TokenRegistry`.** Previously, a user could pass `dexType = UniswapV3` or `UniswapV4`; the token would deploy fine (pair is always a V2 `NadFunPair`), but at graduation `LPManager.addLiquidity` would revert on the unsupported adapter lookup — permanently locking the token pre-graduation. Added regression test `test_create_revertsOnUnsupportedDexType`.

### Security — LPVault zap math (no leftover on liquidity add)

- **`LPVault.afterDeposit` now uses a closed-form zap split instead of a naive 50/50 swap+add.** The previous logic swapped half of the quoteToken and used the other half for `addLiquidity`, but the swap moved the pool price — so the remaining half and the received tokens no longer matched the new reserve ratio. V2's `mint()` then consumed only the lesser-ratio amount, donating the excess to existing LPs (including the protocol-custodied graduation LP). LPVault now derives the optimal swap amount from the constant-product invariant with LP fee, leaving no vault-side dust and maximizing LP burn. If reserves are empty (edge case), `afterDeposit` carries the deposit over to the next call via `_accumulatedQuote` instead of reverting. Added regression tests `test_afterDeposit_zap_leavesNoRemainder` (asserts 0 dust across 5 deposit sizes) and `test_afterDeposit_emptyPair_accumulates`.

### Security — Remove permissionless `GiftVault.expire`

- **Removed `GiftVault.expire(address)` external entry point.** The function was redundant with the inline auto-expire inside `afterDeposit` (which already runs the same expiry/burn sequence on the first delivery past `firstDepositAt + expiryDuration`) and only added an externally-triggerable path that third parties could time for MEV around the forced buyback. Also removed the now-unused `GiftNotExpired` error. Tests that used `vault.expire(...)` as an expiry shortcut were updated to trigger auto-expire via a post-expiry `afterDeposit` call; the six `test_expire_*` tests exercising only the removed function were deleted.

### Security — Per-quote `settlementThreshold`

- **`settlementThreshold` is now stored per-quoteToken inside `QuoteConfig` instead of as a single global.** A single numeric threshold couldn't meaningfully gate settlements across quote tokens with different decimals (e.g., WNATIVE with 18 vs USDC with 6). Admins now set an explicit threshold at `addQuoteToken` / `updateQuoteToken` time (new trailing arg) or via `setSettlementThreshold(address quoteToken, uint256 threshold)`. `FeeCollector.settle` and `isSettleable` read the threshold for the pair's quote token. The global `_settlementThreshold` field, no-arg getter, and single-arg setter were removed. Deploy script and all tests updated to the new signatures.

### Security — TokenRegistry.register zero-address guards

- **`TokenRegistry.register` now reverts with `ZeroAddress` if `token`, `pair`, or `quoteToken` is `address(0)`.** Previously, registration was inferred solely from `_tokens[token].pair != address(0)` (same check used by `isRegistered` and the `AlreadyRegistered` guard). A first `register` call with `pair = 0` would leave the slot "unregistered" from the contract's point of view, so subsequent registrations could overwrite metadata until a non-zero pair was finally written. The current system only reaches `register` from BondingCurve with valid inputs, so there was no in-scope exploit, but the invariant is now enforced defensively. Added unit tests in `test/core/TokenRegistry.t.sol`.

### Security — FeeCollector double-split fix

- **Fix FeeCollector double-splitting creator fee on BondingCurve trades.** Previously, BondingCurve pre-split fees into `protocolFee`/`creatorFee` and sent only the creator portion to FeeCollector, which then split it *again* using `(creatorFeeRate + curveProtocolFeeRate)` — systematically underpaying creators and overpaying the protocol. BondingCurve now forwards the combined `(protocolFee + creatorFee)` to FeeCollector and lets FeeCollector perform the single authoritative split, matching the NadFunPair flow. `snipingFee` still goes directly to `feeReceiver` (curve-specific, not in the pair fee config), and excess `quoteIn` at the graduation boundary is routed directly to `feeReceiver` (not a fee, so not subject to the split).

### Security — Sniping penalty per-second decay

- **Fix minute-flooring in `ProtocolManager.getSnipingPenalty`.** Previously `(duration - elapsed) / 60` floored the remaining minutes, causing the first minute of anti-sniping protection to start below the configured maximum and the last minute to drop to zero before the window actually ended. Replaced with per-second interpolation: `(remainingSeconds * _snipingPenaltyPerMinute) / 60`. Values at exact minute boundaries are unchanged; intra-minute values now decay smoothly. Added regression test `test_antiSniping_decaysPerSecond`.

### Security — Sweep donated tokens from pair before liquidity add (V2)

- **`LPManager._addLiquidityV2` now skims any pre-donated tokens from the `NadFunPair` before minting LP.** Token.sol already blocks base-token transfers to the pair while `!isGraduated`, but quote tokens (WNATIVE/standard ERC20s) can still be sent directly to the pair's CREATE2 address. At the initial graduation mint, V2's `mint()` credits liquidity based on `balance - reserve`, so pre-donated quote would otherwise skew the initial reserves and launch price. Donations are now swept to `feeReceiver` so the pool opens on a clean reserve state and the launch price matches the bonding-curve math. The skim lives in the V2-specific branch of LPManager (not in core BondingCurve) so that future V3/V4 adapters can implement their own initial-state protection. Added regression test `test_graduation_sweepsDonatedQuoteToFeeReceiver`.

### Architecture — Router Consolidation

- **Merged BondingCurveRouter and DexRouter into NadFunRouter.** Eliminated 3-tier routing overhead (approve→transferFrom→external call chain). NadFunRouter now calls BondingCurve and DEX adapters directly as a UUPS Proxy in `src/router/NadFunRouter.sol`. Deleted `src/router/` directory and `IBondingCurveRouter`/`IDexRouter` interfaces.
- **Removed dexRouterFee entirely.** No fee is charged on DEX trades through the router anymore. Removed `dexRouterFeeRate`, `setDexRouterFeeRate()`, `DexRouterFeeRateUpdated` event, `_calculateDexRouterFee()`, and `_calculateGrossAmount()` from NadFunRouter and ProtocolManager.

### Refactored — FeeCollector config unification

- **`FeeConfigInternal` struct removed.** The internal-only struct has been unified with the public `FeeConfig` struct defined in `IFeeCollector`. There is now a single struct used for both storage and the external view return type.
- **`FeeConfig` expanded to 5 fields.** Now includes `baseToken`, `quoteToken`, `creatorFeeRate`, `curveProtocolFeeRate`, and `dexProtocolFeeRate` — matching the split curve/DEX fee model.
- **`getPairFeeConfig()` removed.** Pairs now call `IFeeCollector(feeCollector).getFeeConfig(address(this))` and compute `feeRate = creatorFeeRate + protocolFeeRate` locally. One fewer public function, one fewer code path, and the `msg.sender`-based implicit lookup is replaced by an explicit argument.
- Callers updated: `NadFunPair._collectFee()`, `NadFunPair.getAmountOut()`, `NadFunPair.getAmountIn()` now use `getFeeConfig(address(this))`.

### Architecture — v2.0.0 Custom DEX

- **TaxToken replaced by Token (plain ERC20).** Fee-on-transfer removed. Token is a simple ERC20 + Burnable + Permit (EIP-1167 clone). No 4-state machine, no `_update()` hook, no settlement logic.
- **NadFunFactory/NadFunPair — custom Uniswap V2 fork.** Replaces external Uniswap V2 + V2DexAdapter. NadFunFactory deploys NadFunPair via CREATE2. NadFunPair deducts fees (LP fee + protocol fee + creator fee) atomically in `swap()`.
- **FeeCollector — central fee management (per-pair storage).** New UUPS contract. Stores per-pair `FeeConfig` (baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate). Pair queries its own config via `getFeeConfig(address(this))` in a single external call. Protocol fee shares are forwarded immediately; creator fees accumulate until authorized settlement.
- **CreatorFeeProcessor simplified.** No longer swaps baseToken → quoteToken. Receives quoteToken directly from FeeCollector. Just distributes to vaults by BPS.
- **BondingCurve: Token + NadFunFactory + creator fee.** Deploys Token (not TaxToken), creates pair via NadFunFactory, deducts creator fee from quote amounts during curve trading and sends to FeeCollector.
- **NadFunPair: native getAmountOut/getAmountIn view functions.** Pair is the single source of truth for fee-aware AMM math. Uses `FeeCollector.getFeeConfig(address(this))` for direction-aware fee deduction (1 external call instead of 2). External contracts and frontends can query pair directly.
- **IDexAdapter + NadSwapAdapter: pluggable DEX adapter pattern.** IDexAdapter interface for V2/V3/V4 extensibility. NadSwapAdapter is a thin wrapper — delegates AMM views to pair.getAmountOut/getAmountIn. TokenRegistry maps DexType→IDexAdapter.
- **BurnVault/LPVault: swap via IDexAdapter.** Removed duplicate `_getAmountOut()` logic. Delegates to adapter.
- **DexRouter: swap via IDexAdapter.** Removed internal AMM helpers (`_pairGetAmountOut`, `_getRawSwapOut`, etc.). Delegates to adapter.
- **LPManager: liquidity via IDexAdapter.** `_addLiquidityV2` delegates to the configured adapter. LPManager intentionally exposes no liquidity-removal entrypoint; graduation LP is permanent protocol launch liquidity.
- **Creator fee is permanent.** No more creatorFeeExpirationTime or TaxFree state. Fees collected indefinitely.

### Removed

- **TaxToken** — replaced by Token (plain ERC20)
- **V2DexAdapter** — replaced by NadSwapAdapter (wraps NadFunPair with fee logic)
- **ITaxToken** — replaced by IToken
- **UniswapV2Deployer (test util)** — replaced by NadFunFactory

### Added

- **IDexAdapter** (`src/interfaces/IDexAdapter.sol`) — Pluggable DEX adapter interface
- **NadSwapAdapter** (`src/adapters/NadSwapAdapter.sol`) — IDexAdapter for NadFunPair (V2 AMM)
- **NadFunFactory** (`src/dex/NadFunFactory.sol`) — Uniswap V2 Factory fork
- **NadFunPair** (`src/dex/NadFunPair.sol`) — Uniswap V2 Pair fork with pair-level fee
- **FeeCollector** (`src/fee/FeeCollector.sol`) — Central fee config + collection + settlement
- **Token** (`src/token/Token.sol`) — Plain ERC20 + Burnable + Permit
- **Math** (`src/libraries/Math.sol`) — V2 math utilities
- **UQ112x112** (`src/libraries/UQ112x112.sol`) — V2 fixed-point arithmetic
- **Constants** (`src/libraries/Constants.sol`) — Shared constants

### Testing

- **348 tests across 27 test suites.** Full rewrite of test infrastructure for v2 architecture.
- **New test suites:** NadFunPairView, NadSwapAdapter, NadFunPair, NadFunPairFee, NadFunFactory, FeeCollector, BondingCurveV2, RouterV2, CreatorFeeProcessorV2, BurnVaultV2, LPVaultV2

### Documentation

- **All documentation updated for v2 architecture.** README.md, PRODUCT.md, ARCHITECTURE.md, PROTOCOL_FLOW.md (en/ko), CONTRACTS.md, TEST.md, todo.md.

---

## Previous Releases

### [Unreleased - pre-v2]

- **BondingCurve.create() 통합 + balance detection.** 단일 `create()` 함수로 토큰 생성과 초기 매수를 원자적으로 처리. approve 없이 balance detection으로 자금 흐름 통일. (#66)
- **NadFunRouter create/createWithNative 추가.** 사용자가 Router를 통해 토큰 생성. `ROUTER_ROLE` 접근 제어로 creator 스푸핑 방지. (#66)
- **deployFee/graduateFee를 quote 토큰별로 분리.** `QuoteConfig`에 개별 수수료 필드 추가. (#67)
- **Graduation: transfer remaining tokens to feeReceiver instead of burning.** (#41)
- **Quote-specific deployFee/graduateFee.** (#67)


## [0.2.0] - 2026-03-22 — Architecture Hardening

Major refactoring wave: singleton vault architecture, stronger type safety, overflow-safe math, shared test infrastructure, and comprehensive documentation overhaul.

### Architecture

- **Vault singleton architecture.** BurnVault, LPVault, CreatorFeeVault converted from per-token EIP-1167 clones to shared singletons. Reduces deployment gas and simplifies state management. (#35)
- **CreatorFeeProcessor singleton + pull pattern.** CreatorFeeProcessor is now a single shared instance. Creator fee collection uses pull-based `processAccumulatedCreatorFee()` instead of push-on-every-trade. (#36)
- **VaultRegistry ERC-165 interface verification.** Vault registration now validates `IVault` support via `supportsInterface()` to prevent registering incompatible contracts. (#38)
- **Vault afterDeposit CreatorFeeProcessor permission check.** Vaults verify that `afterDeposit` is called only by authorized CreatorFeeProcessor instances. (#37)

### Code Quality

- **DexType enum renamed: V2/V3/V4 → UniswapV2/UniswapV3/UniswapV4.** Explicit naming removes ambiguity about which DEX protocol is referenced. (#33)
- **BondingCurveLibrary overflow-safe math.** Replaced custom `ceilDiv` with solady's `mulDivUp` for mathematically correct ceiling division without overflow risk. (#31)
- **LPManager dexType dispatch pattern.** Internal function dispatch by `dexType` replaces monolithic if/else chains for cleaner multi-DEX support. (#30)
- **Unified DexRouter and BondingCurveRouter interfaces.** Consistent parameter structures across all router contracts. (#29)

### Testing

- **Shared SetUp.t.sol test architecture.** All test files inherit from a single `SetUp` base contract. Removed `MockTokenRegistry` — tests use real contracts. 249+ tests passing. (#40)

### Documentation

- **Session-independent documentation.** All docs updated to be self-contained without requiring prior conversation context. (#39)
- **docs/contracts restructured to mirror src/.** Per-contract documentation now follows the same directory structure as source code. Removed legacy docs. (#27)
- **Full bilingual inline comments.** Korean NatSpec comments added to all 63 source and test files. (#22)
- **Document consistency audit.** Cross-referenced all docs against code for accuracy. (#23, #24)

## [0.1.0] - 2026-03-20 — Phase 1 Complete

The first release of NadFun V2: a bonding curve token launchpad with post-graduation DEX trading, composable creator fee vaults, and anti-sniping protection. Built for Monad.

### Core Protocol

- **Bonding curve token factory.** Create ERC20 tokens with a single call. Tokens trade on an AMM-style bonding curve (`x*y=k`) until they hit the funding target, then automatically graduate to a V2 DEX pair. All via UUPS-upgradeable `BondingCurve` contract.
- **ProtocolManager — unified configuration hub.** Protocol fees, creator fee settings, quote token registry, and anti-sniping parameters all live in one upgradeable contract. Previously scattered across FeeManager, AdminModule, and QuoteManager — now consolidated.
- **LPManager — pure accounting layer.** Manages DEX liquidity provisioning through IDexAdapter. LP tokens are held in LPManager custody as permanent launch liquidity and tracked per token/caller.

### Trading & Routing

- **NadFunRouter auto-routes by graduation state.** One entry point for all trades — automatically routes to the bonding curve pre-graduation and to the V2 DEX pair post-graduation.
- **ExactIn and ExactOut support everywhere.** All routers (BondingCurveRouter, DexRouter, NadFunRouter) support both modes with slippage protection. ExactOut uses reverse fee/penalty/creator fee math for precise output targeting.
- **Balance-detection core pattern.** BondingCurve buy/sell uses Uniswap V2-style balance delta detection — no amount parameters, just "how much did the balance change?" Routers handle the transfer-then-call pattern.

### Creator fee System

- **TaxToken with 4-state machine.** `BondingCurve → Migrating → TaxActive → TaxFree`. Configurable creator fee rates (1%/3%/5% allowlist). Creator fee and protocol fees tracked separately with independent accumulators.
- **CreatorFeeProcessor with composable vault distribution.** Collected creator fee is swapped to quote token, protocol fee is deducted, remainder is distributed to vault clones by BPS allocation. No hardcoded burn/LP/dividend logic — it's all in the vaults.
- **Four built-in vault types.** BurnVault (buyback and burn), LPVault (add liquidity + burn LP), CreatorFeeVault (direct transfer to recipient), plus VaultRegistry for permissionless vault template registration. Up to 5 vaults per token with BPS allocation.

### Security

- **Anti-sniping penalty.** Configurable penalty that decreases linearly over time (default: 99% at creation, -1%/min for 99 minutes). Makes flash-loan graduation attacks economically impossible.
- **246 tests including attack vectors.** Cross-curve reserve theft, flash loan graduation, reentrancy, unauthorized state transitions, sandwich attacks, vault callback failure resilience, and more.
- **CurveVersion dispatch for upgrade safety.** Buy/sell/graduate logic is versioned (`_buyV1`/`_sellV1`/`_graduateV1`) so future AMM formula changes won't break existing tokens.

### Architecture

- **UUPS Proxy for core + modules.** BondingCurve, ProtocolManager, LPManager, VaultRegistry are all upgradeable without redeployment.
- **EIP-1167 Clone for per-token contracts.** TaxToken, CreatorFeeProcessor, and all vault instances use minimal proxy clones for gas-efficient deployment.
- **Adapter pattern for multi-DEX support.** V2DexAdapter is stateless and chain-agnostic (renamed from PancakeV2Adapter). TokenRegistry maps tokens to their adapters.
- **Clean module boundaries.** Removed DexDeployer (functionality absorbed by TokenRegistry + adapters), removed CreatorFeeSwapper (vaults use adapters directly), removed DividendVault and antiFarmer logic.

### Documentation

- **Full bilingual documentation.** README.md (English), README.ko.md (Korean), PROTOCOL_FLOW.md/ko.md, ARCHITECTURE.md, CONTRACTS.md, and per-contract docs in `docs/contracts/en/` and `docs/contracts/ko/`.
- **Korean inline comments on all 63 source and test files.** Every contract, interface, library, and test file has detailed Korean NatSpec comments.
- **PRODUCT.md as design source of truth.** All design decisions, fee structures, state machines, and security considerations documented in one place.
