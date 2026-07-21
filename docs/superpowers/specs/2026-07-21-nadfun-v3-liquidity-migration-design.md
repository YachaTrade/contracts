# NadFun V3 Liquidity Migration Design

## Purpose

Build a fresh-deployment NadFun contract repository by taking the current `nadfun-contract-v2` architecture as the baseline and replacing its custom Uniswap V2-style launch DEX with canonical Uniswap V3 pools. The new system keeps the V2 repository's Solidity 0.8.24, Foundry, UUPS core modules, deterministic token clones, unified lifecycle router, and vault allocation model.

The Uniswap V3 price, tick, range, liquidity, and direct-pool position formulas are ported from `nads-pump/contract-v3`. The formulas are generalized from a single WMON quote asset to the quote token registered for each launch, without changing their economic meaning.

## Source Baseline and Copy Policy

- Copy tracked project content from the current `/Users/gyu/project/nads-pump/nadfun-contract-v2` worktree into `/Users/gyu/project/giwa/new_contract`, preserving its tracked local edits except for the root instruction file replacement below.
- Exclude `.git/`, `.env*`, local credentials, `out/`, `cache/`, `broadcast/`, OS metadata, local browser logs, and untracked deployment payloads.
- Do not modify either source repository.
- Replace the copied root `AGENTS.md` with `/Users/gyu/project/giwa/contracts/AGENTS.md` as requested.
- Use the current `contract-v3` worktree only as a V3 logic reference. Do not copy its constructor-based architecture, deployment addresses, local environment, generated output, or dirty working-tree artifacts wholesale.
- Add Uniswap V3 core and periphery dependencies at revisions compatible with the reference formulas and Solidity 0.8.24 build.

## Scope

### In Scope

- Canonical V3 pool creation and initialization for every launched token.
- Multiple allowlisted quote tokens, each with its own curve parameters, V3 fee tier, and LP-fee protocol share.
- Two direct, one-sided V3 positions per graduated token using the `contract-v3` dual-range strategy.
- Unified pre-graduation curve and post-graduation V3 routing.
- V3 position fee collection, base-token fee conversion into the registered quote token, and quote-only distribution.
- Existing CreatorFeeProcessor vault allocation behavior, repurposed to distribute the configured share of V3 LP fees.
- V3-compatible BurnVault, LPVault, CreatorFeeVault, GiftVault, and DividendVault behavior.
- Deployment scripts, interfaces, ABIs, English/Korean documentation, and tests affected by the V3-only launch lifecycle.

### Out of Scope

- Compatibility with deployed V2 proxies, existing V2 tokens, or existing NadFunPair liquidity.
- A V2/V3 coexistence mode for newly launched tokens.
- Uniswap V3 position NFTs or NonfungiblePositionManager custody.
- Removable protocol launch liquidity.
- A custom V3 pool, hook, transfer-tax token, or pair-level creator fee.
- On-chain deployment, role changes, transaction broadcasting, or live-chain configuration.

## Architecture

### Retained Components

- `BondingCurve`: UUPS lifecycle state machine and curve trading engine.
- `ProtocolManager`: UUPS quote-token configuration and selector-scoped operator authorization.
- `TokenRegistry`: UUPS source of truth for token, pool, quote token, and fee tier.
- `LPManager`: UUPS owner and coordinator for permanent V3 launch positions and LP-fee settlement.
- `CreatorFeeProcessor`: immutable vault allocation engine. Its name is retained, but it receives the creator-processor share of LP fees rather than a per-trade creator fee.
- Vault registry and the configured vault implementations.
- `Token`: EIP-1167 clone with the pre-graduation pool-transfer restriction.
- `NadFunRouter`: UUPS unified curve/V3 trading entrypoint.

### Removed Components and Concepts

- `NadFunFactory`, `NadFunPair`, their interfaces, and launch-DEX-specific V2 libraries.
- `NadSwapAdapter` and `NadFunRouter02`.
- `FeeCollector`, its settlement threshold, pair fee configuration, settler flow, and wiring.
- Creator fee rate allowlists, creation parameters, curve state, events, accounting, and DEX fee enforcement.
- `dexProtocolFeeRate`. Canonical V3 swaps pay the pool's configured LP fee; the protocol receives its configured share when LP fees are collected.
- `DexType` selection for launch pools. The new launch lifecycle is V3-only.

External V2 launch routing is removed. Any remaining external venue integration must use the V3 swap boundary defined by this design.

### New Components

#### V3PoolDeployer

A UUPS module authorized through ProtocolManager. It holds the canonical V3 factory address and creates or adopts the factory's pool for `(token, quoteToken, feeTier)`. It validates the factory result and initializes an uninitialized pool in the token-creation transaction at the deterministic graduation price.

The factory is permissionless, so an attacker can predict a future token address and create its canonical pool first. V3PoolDeployer safely reuses that exact canonical pool only while `slot0.sqrtPriceX96` is zero, then initializes it and raises observation cardinality atomically. Any already-initialized pool is rejected, even when its price equals the expected graduation price: while the predicted token address has no code, token-transfer calls can appear successful and allow hostile positions or other pool contamination that price equality cannot detect.

Predictable token addresses plus a permissionless canonical factory therefore leave an unavoidable targeted launch denial-of-service: an attacker can initialize the pool before the launch transaction and force creation to revert. Launch submissions should use private relays or builder-protected transaction submission where available so the token address and pool-creation intent are not exposed in the public mempool before execution. The pool has no protocol liquidity until graduation.

#### V3LiquidityActor

A non-upgradeable actor owned by the LPManager proxy. It directly calls `IUniswapV3Pool.mint`, stores the quote-side and token-side position ranges and liquidity, pokes both positions with `burn(..., 0)`, and collects only the fees belonging to those positions.

The actor exposes no principal-removal function. It supports increasing the two existing positions so LPVault can reinvest accumulated quote value in a later transaction.

#### V3SwapAdapter

A canonical-factory-aware exact-input/exact-output swap boundary used by NadFunRouter and V3-compatible vault operations. It authenticates callbacks against the registered factory pool and an active per-call context. It returns actual balance-delta amounts and accepts caller-provided slippage bounds.

LPManager may use this adapter to convert collected launch-token fees into the token's registered quote asset. The adapter never holds durable user or protocol balances.

## Configuration and Interfaces

`ProtocolManager.QuoteConfig` contains:

- quote token decimals;
- virtual quote reserve;
- virtual token reserve;
- minimum token reserve;
- deploy fee;
- graduate fee;
- curve protocol fee rate in BPS;
- V3 fee tier as `uint24`;
- LP-fee protocol share as `uint16 lpFeeProtocolShareBps`;
- active flag.

`lpFeeProtocolShareBps` is configured per quote token and must be at most `BPS`. Its initial value is 5,000 for an equal split. The CreatorFeeProcessor share is always the complement, so an invalid or stale two-rate total cannot exist.

Changing a quote token's V3 fee tier affects only pools created afterward; TokenRegistry snapshots each launched token's fee tier. Changing `lpFeeProtocolShareBps` affects the next collection for every token using that quote asset.

For rounding, the processor share is calculated first with floor division:

```text
processorShare = totalQuoteFee * (BPS - lpFeeProtocolShareBps) / BPS
protocolShare  = totalQuoteFee - processorShare
```

The protocol therefore receives any indivisible remainder and LPManager retains no distribution dust.

`TokenRegistry.TokenInfo` contains the canonical pool, quote token, and V3 fee tier. A reverse pool-to-token mapping prevents a pool from being associated with multiple launch records and supports callback validation.

`CreatorFeeProcessor` authorizes LPManager instead of FeeCollector. Its processing entrypoint pulls the exact quote amount from LPManager, resets approvals after use, and distributes it across the token's existing vault slots. The public function and event names are updated to describe LP fee processing where doing so does not break an intentionally retained integration.

LPManager collection uses this exact parameter shape:

```solidity
struct CollectParams {
    address token;
    uint256 minQuoteOut;
    uint160 sqrtPriceLimitX96;
    uint256 deadline;
}
```

`collect(CollectParams)` processes one token and `collectBatch(CollectParams[])` processes a duplicate-free batch atomically. The price limit must be on the valid side of the current price whenever a token-fee swap is required.

## Lifecycle and Data Flow

### Token Creation

1. NadFunRouter validates the deadline and transfers the deploy fee plus optional initial-buy quote amount.
2. BondingCurve verifies that the selected quote token is active.
3. BondingCurve clones the Token at the deterministic salt.
4. V3PoolDeployer reads the quote token's fee tier and graduation configuration, creates or reuses an uninitialized canonical pool, rejects an initialized pool, and initializes the accepted pool's price.
5. TokenRegistry records the token, pool, quote token, and fee tier.
6. BondingCurve configures the token's vault slots in CreatorFeeProcessor.
7. Token is initialized with the pool address so pre-graduation transfers to the pool are blocked.
8. Curve state is initialized without creator-fee or DEX-type fields.

The initial pool price uses the unadjusted graduation-target virtual reserves exactly as `contract-v3/DexDeployer` does. The snapshotted graduate fee is applied later when LPManager derives the adjusted bonding tick, exactly as `contract-v3/LpManager.calculateBondingTick` does. Quote-token decimals are represented by the configured raw reserve values; the V3 ratio is always computed from raw token units.

### Curve Trading

Curve buys and sells retain the constant-product virtual-reserve model, anti-sniping schedule, deadlines, slippage protection, and reserve isolation. The only trading fee is `curveProtocolFeeRate`, plus any anti-sniping penalty. Both are transferred directly to `ProtocolManager.feeReceiver()`.

No creator fee is accepted, calculated, emitted, collected, settled, or stored.

### Graduation and V3 Allocation

1. Reaching `minTokenReserve` marks the curve and Token as graduated before external liquidity calls.
2. BondingCurve subtracts the token's snapshotted graduate fee from raised quote value and transfers that fee to `feeReceiver`.
3. The launch token amount and remaining quote amount are transferred to LPManager.
4. LPManager validates the registered canonical pool and loads its price, tick, tick spacing, token ordering, and fee tier.
5. LPManager derives the adjusted bonding tick and the quote-side and token-side ranges with the reference V3 formulas.
6. LPManager approves V3LiquidityActor only for the call-scoped maximum amounts.
7. V3LiquidityActor directly mints the two one-sided positions and records their keys, ranges, and liquidity.
8. Approvals are reset.
9. Any rounding remainder from the requested graduation amounts is transferred to `feeReceiver`; unrelated pre-existing LPManager balances are not swept.

The two position principals remain permanently owned by the actor. There is no burn-with-liquidity, collect-principal, transfer-position, or emergency principal-withdrawal API.

### Post-Graduation Trading

NadFunRouter resolves the canonical pool from TokenRegistry and routes exact-input and exact-output swaps through V3SwapAdapter. User-provided deadlines, minimum output, and maximum input remain authoritative.

View-only V2 reserve quoting is removed. The router's lifecycle-aware quote functions lose the Solidity `view` modifier and call a configured canonical QuoterV2 after graduation; clients invoke them with `eth_call`. Curve-only quote functions remain `view`. The state-changing buy and sell paths do not call QuoterV2 and depend only on user-provided execution bounds.

Native routes are available only when the token's registered quote asset matches the router's configured wrapped-native path or an explicitly configured LVMon path. Arbitrary allowlisted ERC-20 quote tokens use ERC-20 routes only.

### LP Fee Collection and Distribution

An authorized operator calls LPManager with `CollectParams`. Batch collection supplies independent bounds for every token and reverts if a token appears twice.

For each token, LPManager:

1. validates TokenRegistry metadata against the canonical factory;
2. snapshots only the launch-token and registered-quote balances relevant to this call;
3. asks V3LiquidityActor to poke and collect both direct positions;
4. measures the exact token and quote fee deltas;
5. swaps the collected launch-token fee through the same V3 pool into quote token using exact input;
6. requires the full token fee input to be consumed and the received quote to satisfy the caller's bounds;
7. adds collected quote fees and swapped quote output;
8. reads the current quote-token `lpFeeProtocolShareBps` from ProtocolManager;
9. transfers the protocol share directly to `feeReceiver`;
10. grants a call-scoped approval and invokes CreatorFeeProcessor for the complement;
11. resets the approval and verifies that no call-scoped token or quote balance remains.

The swap itself may generate additional LP fees. Those fees remain in the two positions and are collected on a later call; collection does not recurse.

## Vault Behavior

CreatorFeeProcessor continues to require each token's vault BPS total to equal `BPS` and assigns rounding remainder to the last vault.

- BurnVault accumulates when execution is unavailable and, after graduation, swaps quote to launch token through V3SwapAdapter and burns the received token.
- LPVault records incoming quote during CreatorFeeProcessor distribution. A separate authorized execution converts the required portion to launch token and asks LPManager/V3LiquidityActor to increase the existing permanent positions. It cannot call back into LPManager during `collect`.
- CreatorFeeVault preserves its recipient claim behavior.
- GiftVault preserves its configured transfer behavior.
- DividendVault preserves its configured allocation and claim behavior, but its conversion route uses authenticated V3 pools.

A vault callback failure reverts the entire fee collection and distribution transaction. This prevents partial BPS distribution and leaves all pool fees claimable for a later retry.

## V3 Mathematical Fidelity

The following logic is ported from `contract-v3` without changing formulas:

- pool initialization price using `FullMath.mulDiv`, integer `Math.sqrt`, and Q96 encoding;
- graduate-fee adjustment before deriving the bonding price;
- `TickMath.getTickAtSqrtRatio` conversion;
- tick-spacing alignment and direction changes based on whether quote is token0;
- quote-side and token-side dual one-sided ranges;
- `LiquidityAmounts` calculation for direct V3 pool minting;
- position fee realization through zero-liquidity burn followed by pool collect.

The WMON-specific names become quote-token names, and global WMON configuration becomes per-token registry data. Bounds checks are added for zero amounts, square-root price range, tick ordering, tick spacing, fee tier, multiplication overflow, and zero liquidity. These checks do not alter valid reference outputs.

## Security and Failure Semantics

- UUPS implementations disable initializers in constructors; initializer arguments must be deployed contracts with consistent ProtocolManager authority.
- BondingCurve is the only authorized V3PoolDeployer and initial LP allocation caller.
- LP fee collection and LPVault reinvestment are selector-authorized through ProtocolManager.
- All external-call-heavy lifecycle, swap, collection, and vault paths are non-reentrant.
- Mint and swap callbacks require an active context, exact expected pool, canonical factory lookup, matching token order and fee tier, matching calldata hash, correct delta direction, and a bounded amount owed.
- Callback context is deleted before paying the pool.
- Every pool read is checked against TokenRegistry and `factory.getPool`.
- V3PoolDeployer may reuse a pre-created canonical pool only when it remains uninitialized; any initialized pool is treated as contaminated and rejected regardless of its price.
- Exact balance deltas isolate donations and reject fee-on-transfer, rebasing, surcharge, or otherwise non-standard balance behavior.
- Collection swap bounds are explicit per transaction. An expired deadline, insufficient quote output, invalid square-root price limit, or partially filled exact input reverts the complete collect.
- A zero or self-referential fee receiver, processor, actor, adapter, or registry wiring is rejected.
- Pool creation, graduation, and allocation are atomic; a failure leaves the launch in its pre-call state.
- LP principal cannot be removed through any public or privileged function in scope.

Canonical V3 pools remain permissionless after graduation. Third parties may route swaps or add their own liquidity, but cannot collect or remove the protocol actor's positions. There is intentionally no post-graduation creator fee or additional protocol fee on direct pool swaps.

## Testing Strategy

Implementation follows red-green-refactor. Every behavior change begins with a focused Foundry test that is observed failing for the intended missing behavior before production code is written.

### Unit Coverage

- ProtocolManager per-quote fee tier and LP share, including 0, 5,000, 10,000, and invalid values.
- Complete absence of creator-fee and DEX-protocol-fee configuration paths.
- V3PoolDeployer initial price vectors and canonical pool validation.
- Reference parity vectors for square-root price, bonding tick, range endpoints, and liquidity.
- Both address orderings for every price, range, mint, collect, and swap path.
- Token pre-graduation pool-transfer restriction.
- LPManager position creation, duplicate allocation, exact approvals, rounding remainder, and permanent principal.
- Forged callback, wrong factory, wrong pool, wrong fee tier, wrong delta, overpayment, nested callback, and reentrancy rejection.
- Fee collection with only quote fees, only token fees, both fee assets, zero fees, and indivisible rounding.
- Token-fee conversion failures for deadline, minimum output, price limit, and partial fill.
- Balance donation isolation and unsupported token behavior.
- CreatorFeeProcessor authorization and exact vault BPS distribution.
- V3-compatible BurnVault and deferred LPVault execution.

### Integration and Invariant Coverage

- Create, curve buy/sell, automatic graduation, V3 buy/sell, LP fee accrual, collect, conversion, split, and vault distribution.
- At least two quote tokens with different decimals, fee tiers, and LP share settings.
- Native and ERC-20-only quote paths.
- Quote conservation across curve reserves, graduate fee, V3 allocation, LP collection, fee receiver, and vaults.
- Protocol actor liquidity never decreases.
- LPManager and adapter do not retain call-scoped balances after success.
- A callback cannot cause payment to an unregistered pool.
- A failing vault or token causes complete rollback without partial fee distribution.

### Validation Commands

```shell
forge fmt
forge fmt --check
forge build --sizes
forge test --match-path test/modules/LPManagerV3.t.sol -vvv
forge test -vvv
```

The implementation also regenerates and reviews affected ABIs and inspects English/Korean contract documentation. Fork tests that depend on deployed factory, quoter, wrapped-native, or LVMon contracts remain gated and are reported separately if the required non-secret environment is unavailable.

## Completion Criteria

- The repository builds on Solidity 0.8.24 with V3 core/periphery dependencies.
- No launch lifecycle code references NadFunPair, NadFunFactory, creator fee rates, settlement thresholds, FeeCollector, or DEX protocol fee rates.
- Every allowed quote token can configure its own V3 fee tier and LP protocol share.
- Graduation produces the two expected permanent V3 positions for both token address orderings.
- Collected token-side fees are converted to quote, then the total quote value is split according to ProtocolManager and distributed without retained dust.
- Existing vault allocation semantics pass their migrated tests.
- Focused, full, and invariant test suites pass, with any fork-only omissions reported explicitly.
