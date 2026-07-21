# NadFun V3 Liquidity Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Rebuild NadFun V2 as a fresh-deployment Solidity 0.8.24 launchpad that graduates into permanent canonical Uniswap V3 dual-range positions and distributes collected LP fees as quote token according to ProtocolManager configuration.

**Architecture:** Preserve the V2 UUPS core, deterministic Token clones, unified router, and vault allocation system. Replace the custom V2 factory/pair and creator-fee settlement path with V3PoolDeployer, a contract-v3-compatible V3LiquidityActor, V3-aware LPManager, and authenticated V3SwapAdapter. Keep the contract-v3 price, bonding-tick, range, mint, and collect formulas structurally identical, changing only WMON names into per-token quote-token data and adding the agreed access, slippage, and distribution boundaries.

**Tech Stack:** Solidity 0.8.24, Foundry, OpenZeppelin upgradeable contracts, Solady, Uniswap V3 core commit 6562c52e8f75f0c10f9deaf44861847585fc8129, Uniswap V3 periphery commit b325bb0905d922ae61fcc7df85ee802e8df5e96c.

## Global Constraints

- This is a fresh deployment. Do not preserve deployed V2 proxy storage or existing NadFunPair compatibility.
- Copy the current tracked nadfun-contract-v2 worktree as the baseline and replace root AGENTS.md with /Users/gyu/project/giwa/contracts/AGENTS.md.
- Never open or copy .env files, credentials, signing material, cache, out, broadcast, browser logs, or untracked deployment payloads.
- Use canonical Uniswap V3 pools and support multiple allowlisted quote tokens.
- Port the valid mathematical logic from /Users/gyu/project/nads-pump/contract-v3/src/DexDeployer.sol, src/LpManager.sol, and src/actors/UniswapActor.sol with the smallest possible structural change.
- Remove creator fee rates, dexProtocolFeeRate, FeeCollector, settlement thresholds, NadFunFactory, NadFunPair, and NadFunRouter02 from the final lifecycle.
- Keep curveProtocolFeeRate. Store v3FeeTier and lpFeeProtocolShareBps per quote token.
- LP fee collection converts token-side fees to the registered quote token, then sends the configured protocol share to ProtocolManager.feeReceiver and the complement to CreatorFeeProcessor.
- The default LP split is 5,000 BPS protocol and 5,000 BPS processor. The processor share is rounded down and the protocol receives the remainder.
- V3 launch principal is permanent and has no removal, rescue, transfer, or emergency-withdrawal path.
- Every production behavior follows red-green-refactor. Observe the intended test failure before implementation.
- Do not commit, push, create a PR, deploy, broadcast, or modify live roles without a separate explicit user request. Use local review checkpoints in place of commit steps.

---

## Reference-to-Target Mapping

| contract-v3 reference | New target | Fidelity rule |
|---|---|---|
| src/DexDeployer.sol | src/core/V3PoolDeployer.sol | Preserve target-reserve sqrt-price calculation and token ordering |
| src/LpManager.sol:_loadPoolData | src/core/LPManager.sol:_loadPoolData | Preserve slot0, tick spacing, aligned tick, and quote ordering |
| src/LpManager.sol:calculateBondingTick | src/core/LPManager.sol:calculateBondingTick | Preserve graduate-fee adjustment, TickMath conversion, alignment, and direction |
| src/actors/UniswapActor.sol:mint | src/actors/V3LiquidityActor.sol:mint | Preserve the two one-sided range formulas and direct pool mint |
| src/actors/UniswapActor.sol:collectFees | src/actors/V3LiquidityActor.sol:collectFees | Preserve burn-zero then collect for both positions |
| src/actors/UniswapActor.sol:uniswapV3MintCallback | src/actors/V3LiquidityActor.sol:uniswapV3MintCallback | Preserve call-scoped pool payment and add canonical validation |
| test/LpManager.t.sol | test/modules/LPManagerV3.t.sol | Port both token-ordering, allocation, callback, and real-swap fee tests |
| test/UniswapV3Compatibility.t.sol | test/integration/UniswapV3Compatibility.t.sol | Preserve init-code-hash and PoolAddress checks |

### Task 1: Establish the New Local Repository Baseline

**Files:**
- Copy: all tracked files from /Users/gyu/project/nads-pump/nadfun-contract-v2
- Replace: AGENTS.md
- Preserve: docs/superpowers/specs/2026-07-21-nadfun-v3-liquidity-migration-design.md
- Preserve: docs/superpowers/plans/2026-07-21-nadfun-v3-liquidity-migration.md
- Modify: .gitmodules
- Modify: foundry.toml
- Modify: remappings.txt
- Create: docs/V3_DEPENDENCIES.md

**Interfaces:**
- Consumes: the current tracked V2 worktree and current contract-v3 V3 library worktrees.
- Produces: a buildable V2 baseline with V3 core/periphery available under the existing Solidity 0.8.24 toolchain.

- [ ] **Step 1: Copy only tracked V2 files without overwriting this spec or plan**

Run from /Users/gyu/project/nads-pump/nadfun-contract-v2:

~~~shell
git ls-files -z | rsync -a --from0 --files-from=- ./ /Users/gyu/project/giwa/new_contract/
cp /Users/gyu/project/giwa/contracts/AGENTS.md /Users/gyu/project/giwa/new_contract/AGENTS.md
~~~

Expected: source, tests, scripts, docs, and tracked configuration appear in new_contract; .git, .env files, out, cache, broadcast, and untracked deployment files do not appear.

- [ ] **Step 2: Restore the approved design and plan if the baseline copy touched their parent directory**

Run:

~~~shell
test -f /Users/gyu/project/giwa/new_contract/docs/superpowers/specs/2026-07-21-nadfun-v3-liquidity-migration-design.md
test -f /Users/gyu/project/giwa/new_contract/docs/superpowers/plans/2026-07-21-nadfun-v3-liquidity-migration.md
cmp /Users/gyu/project/giwa/contracts/AGENTS.md /Users/gyu/project/giwa/new_contract/AGENTS.md
~~~

Expected: all three commands exit 0.

- [ ] **Step 3: Copy the exact current contract-v3 V3 dependency worktrees**

Copy tracked files from the two nested repositories so their current relaxed Solidity pragmas are retained without nested .git directories:

~~~shell
git -C /Users/gyu/project/nads-pump/contract-v3/lib/v3-core ls-files -z | rsync -a --from0 --files-from=- /Users/gyu/project/nads-pump/contract-v3/lib/v3-core/ /Users/gyu/project/giwa/new_contract/lib/v3-core/
git -C /Users/gyu/project/nads-pump/contract-v3/lib/v3-periphery ls-files -z | rsync -a --from0 --files-from=- /Users/gyu/project/nads-pump/contract-v3/lib/v3-periphery/ /Users/gyu/project/giwa/new_contract/lib/v3-periphery/
~~~

Expected: FullMath.sol, TickMath.sol, UniswapV3Factory.sol, IUniswapV3Pool.sol, LiquidityAmounts.sol, PoolAddress.sol, and QuoterV2.sol exist under lib.

- [ ] **Step 4: Add the V3 remappings and record provenance**

The final remapping additions are:

~~~text
@uniswap/v3-core/=lib/v3-core/
@uniswap/v3-periphery/=lib/v3-periphery/
~~~

docs/V3_DEPENDENCIES.md must record:

~~~markdown
# Uniswap V3 Dependencies

- v3-core: 6562c52e8f75f0c10f9deaf44861847585fc8129
- v3-periphery: b325bb0905d922ae61fcc7df85ee802e8df5e96c
- Source worktree: /Users/gyu/project/nads-pump/contract-v3
- Local delta: exact-version Solidity pragmas in deployable/test contracts are relaxed to the current contract-v3 worktree values; mathematical library bodies are unchanged.
~~~

- [ ] **Step 5: Initialize the new local Git repository without committing or pushing**

Run:

~~~shell
git -C /Users/gyu/project/giwa/new_contract init -b main
git -C /Users/gyu/project/giwa/new_contract remote add origin git@github-blackpink:YachaTrade/contracts.git
~~~

Expected: git status shows all baseline files as untracked and origin points to the newly created empty GitHub repository.

- [ ] **Step 6: Establish the baseline validation**

Run:

~~~shell
forge fmt --check
forge build --sizes
forge test -vvv
~~~

Expected: record the exact V2 baseline result before behavior changes. Any pre-existing failure must be isolated and reported; do not silently alter V2 code to hide it.

- [ ] **Step 7: Local review checkpoint**

Run:

~~~shell
git status --short
git diff --check
~~~

Expected: only the intended baseline, instruction replacement, V3 dependencies, remappings, and design artifacts are present.

### Task 2: Add Per-Quote V3 and LP-Share Configuration

**Files:**
- Modify: src/interfaces/IProtocolManager.sol
- Modify: src/core/ProtocolManager.sol
- Modify: test/core/ProtocolManager.t.sol
- Create: test/core/ProtocolManagerV3.t.sol

**Interfaces:**
- Consumes: BPS from src/libraries/Constants.sol.
- Produces: v3FeeTier(address) -> uint24 and lpFeeProtocolShareBps(address) -> uint16.

- [ ] **Step 1: Write failing quote-configuration tests**

Add tests with these assertions:

~~~solidity
function test_addQuoteToken_storesV3FeeTierAndLpProtocolShare() public {
    protocolManager.addQuoteToken(
        address(quoteToken),
        30 ether,
        1_000_000_000 ether,
        200_000_000 ether,
        1 ether,
        5 ether,
        100,
        0,
        0
    );
    protocolManager.setV3QuoteConfig(address(quoteToken), 10_000, 5_000);

    IProtocolManager.QuoteConfig memory config = protocolManager.getConfig(address(quoteToken));
    assertEq(config.v3FeeTier, 10_000);
    assertEq(config.lpFeeProtocolShareBps, 5_000);
}

function test_addQuoteToken_revertsWhenLpProtocolShareExceedsBps() public {
    protocolManager.addQuoteToken(
        address(quoteToken),
        30 ether,
        1_000_000_000 ether,
        200_000_000 ether,
        1 ether,
        5 ether,
        100,
        0,
        0
    );
    vm.expectRevert(IProtocolManager.InvalidLpFeeShare.selector);
    protocolManager.setV3QuoteConfig(address(quoteToken), 10_000, 10_001);
}

function test_addQuoteToken_revertsWhenFeeTierIsZero() public {
    protocolManager.addQuoteToken(
        address(quoteToken),
        30 ether,
        1_000_000_000 ether,
        200_000_000 ether,
        1 ether,
        5 ether,
        100,
        0,
        0
    );
    vm.expectRevert(IProtocolManager.InvalidFeeTier.selector);
    protocolManager.setV3QuoteConfig(address(quoteToken), 0, 5_000);
}
~~~

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

~~~shell
forge test --match-path test/core/ProtocolManagerV3.t.sol -vvv
~~~

Expected: compilation fails because v3FeeTier, lpFeeProtocolShareBps, InvalidLpFeeShare, and setV3QuoteConfig do not exist.

- [ ] **Step 3: Extend QuoteConfig without yet removing legacy fields**

Append the V3 fields while temporarily retaining the legacy fields until Task 13, so the repository remains incrementally buildable:

~~~solidity
struct QuoteConfig {
    uint8 decimals;
    uint256 virtualReserve;
    uint256 virtualTokenReserve;
    uint256 minTokenReserve;
    uint256 deployFee;
    uint256 graduateFee;
    uint16 curveProtocolFeeRate;
    uint16 dexProtocolFeeRate;
    uint256 settlementThreshold;
    uint24 v3FeeTier;
    uint16 lpFeeProtocolShareBps;
    bool active;
}

function v3FeeTier(address quoteToken) external view returns (uint24);
function lpFeeProtocolShareBps(address quoteToken) external view returns (uint16);
function setV3QuoteConfig(address quoteToken, uint24 v3FeeTier, uint16 lpFeeProtocolShareBps) external;
~~~

Validate v3FeeTier != 0 and lpFeeProtocolShareBps <= BPS in setV3QuoteConfig. V3PoolDeployer performs the authoritative factory.feeAmountTickSpacing validation at pool creation because ProtocolManager does not own the factory dependency. Task 13 folds these values into the final creator-fee-free addQuoteToken and updateQuoteToken signatures.

- [ ] **Step 4: Make the focused tests GREEN**

Run:

~~~shell
forge test --match-path test/core/ProtocolManagerV3.t.sol -vvv
forge test --match-path test/core/ProtocolManager.t.sol -vvv
~~~

Expected: both files pass with no warnings.

- [ ] **Step 5: Local review checkpoint**

Inspect that setV3QuoteConfig performs the V3 validation and emits the configured fee tier and LP protocol share. Folding these values into addQuoteToken and updateQuoteToken is deferred to Task 13.

### Task 3: Introduce V3 Registry Metadata and Pool Deployment

**Files:**
- Modify: src/interfaces/ITokenRegistry.sol
- Modify: src/core/TokenRegistry.sol
- Create: src/interfaces/IV3PoolDeployer.sol
- Create: src/core/V3PoolDeployer.sol
- Create: test/core/V3PoolDeployer.t.sol
- Create: test/integration/UniswapV3Compatibility.t.sol
- Create: test/harness/ContractV3MathReference.sol

**Interfaces:**
- Consumes: ProtocolManager.getConfig, canonical IUniswapV3Factory, and the cloned token address.
- Produces: createPool(token, quoteToken) -> pool and TokenInfo(pool, quoteToken, feeTier).

- [ ] **Step 1: Write the failing V3 pool deployment and registry tests**

Cover:

~~~solidity
function test_createPool_tokenIsToken0_matchesContractV3Price() public;
function test_createPool_quoteIsToken0_matchesContractV3Price() public;
function test_createPool_registersCanonicalPoolAndFeeTier() public;
function test_createPool_revertsForUnauthorizedCaller() public;
function test_createPool_revertsForUnsupportedFeeTier() public;
function test_register_revertsWhenPoolAlreadyMapped() public;
function test_poolInitCodeHashMatchesPeripheryConstant() public;
function test_factoryPoolMatchesPoolAddressComputedAddress() public;
~~~

The test-only reference harness must expose the original calculation:

~~~solidity
function calculateSqrtPrice(uint256 amount0, uint256 amount1) external pure returns (uint160 sqrtPriceX96) {
    uint256 ratioX128 = FullMath.mulDiv(amount1, uint256(1) << 128, amount0);
    uint256 sqrtRatioX64 = Math.sqrt(ratioX128);
    uint256 encoded = sqrtRatioX64 << 32;
    if (encoded > type(uint160).max) revert OverFlow();
    return uint160(encoded);
}
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/core/V3PoolDeployer.t.sol -vvv
~~~

Expected: compilation fails because V3PoolDeployer and V3 TokenInfo fields do not exist.

- [ ] **Step 3: Implement V3 TokenInfo and reverse lookup**

Add V3 metadata without deleting the legacy V2 fields until BondingCurve migrates in Task 9:

~~~solidity
struct TokenInfo {
    address pair;
    address pool;
    address quoteToken;
    DexType dexType;
    uint24 feeTier;
}

function registerV3(address token, address pool, address quoteToken, uint24 feeTier) external;
function getPool(address token) external view returns (address);
function getTokenByPool(address pool) external view returns (address);
~~~

registerV3 populates both pair and pool with the canonical pool during the transition; the existing register(address,address,address,DexType) remains only until Task 13. Task 13 removes pair, DexType, the legacy register function, and renames registerV3 to register. TokenRegistry must reject zero code-less pools, duplicate tokens, duplicate pools, and zero quote tokens.

- [ ] **Step 4: Implement V3PoolDeployer with the contract-v3 formula intact**

The core create path is:

~~~solidity
function createPool(address token, address quoteToken) external restricted returns (address pool) {
    IProtocolManager.QuoteConfig memory config = IProtocolManager(authority()).getConfig(quoteToken);
    if (!config.active) revert QuoteTokenNotAllowed();

    IUniswapV3Factory v3Factory = IUniswapV3Factory(factory);
    if (v3Factory.feeAmountTickSpacing(config.v3FeeTier) == 0) revert InvalidFeeTier();
    pool = v3Factory.createPool(token, quoteToken, config.v3FeeTier);

    uint256 k = config.virtualReserve * config.virtualTokenReserve;
    uint256 targetVirtualQuoteAmount = k / config.minTokenReserve;
    uint160 sqrtPriceX96 = _calculateSqrtPrice(
        token < quoteToken ? config.minTokenReserve : targetVirtualQuoteAmount,
        token < quoteToken ? targetVirtualQuoteAmount : config.minTokenReserve
    );

    IUniswapV3Pool(pool).initialize(sqrtPriceX96);
    IUniswapV3Pool(pool).increaseObservationCardinalityNext(32);
}

function _calculateSqrtPrice(uint256 amount0, uint256 amount1) internal pure returns (uint160 sqrtPriceX96) {
    uint256 ratioX128 = FullMath.mulDiv(amount1, uint256(1) << 128, amount0);
    uint256 sqrtRatioX64 = Math.sqrt(ratioX128);
    uint256 encoded = sqrtRatioX64 << 32;
    if (encoded > type(uint160).max) revert OverFlow();
    return uint160(encoded);
}
~~~

This body intentionally mirrors contract-v3/src/DexDeployer.sol. Do not replace it with a different fixed-point derivation.

- [ ] **Step 5: Verify GREEN and formula parity**

Run:

~~~shell
forge test --match-path test/core/V3PoolDeployer.t.sol -vvv
forge test --match-path test/integration/UniswapV3Compatibility.t.sol -vvv
~~~

Expected: both address orderings produce the same sqrtPriceX96 as ContractV3MathReference and PoolAddress matches factory output.

### Task 4: Port the Contract-V3 Direct Position Actor

**Files:**
- Modify: src/interfaces/ILPManager.sol
- Create: src/interfaces/IV3LiquidityActor.sol
- Create: src/actors/V3LiquidityActor.sol
- Create: test/modules/V3LiquidityActor.t.sol
- Create: test/mocks/MockV3Pool.sol

**Interfaces:**
- Consumes: PoolData from ILPManager and call-scoped approvals from LPManager.
- Produces: two permanent positions per pool, fee collection, fee viewing, and position increases.

- [ ] **Step 1: Write failing actor tests**

The focused test names are:

~~~solidity
function test_mint_quoteIsToken0_usesContractV3Ranges() public;
function test_mint_quoteIsToken1_usesContractV3Ranges() public;
function test_mint_revertsWhenPositionAlreadyExists() public;
function test_mintCallback_revertsForUnexpectedPool() public;
function test_mintCallback_revertsForExcessiveAmount() public;
function test_collectFees_pokesAndCollectsBothPositions() public;
function test_increase_addsLiquidityWithoutChangingRanges() public;
function test_actorExposesNoPrincipalRemovalSelector() public;
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/modules/V3LiquidityActor.t.sol -vvv
~~~

Expected: compilation fails because IV3LiquidityActor and V3LiquidityActor do not exist.

- [ ] **Step 3: Port the reference actor data model**

First add the reference-compatible PoolData shape to ILPManager so the actor task compiles before the LPManager rewrite:

~~~solidity
struct PoolData {
    address pool;
    address token0;
    address token1;
    address quoteToken;
    uint160 sqrtPrice;
    int24 currentTick;
    int24 tickSpacing;
    int24 alignedTick;
    int24 bondingTick;
    bool quoteIsToken0;
}
~~~

Use:

~~~solidity
struct Position {
    bytes32 key;
    int24 lowerTick;
    int24 upperTick;
    uint128 liquidity;
}

address public immutable owner;
address public immutable factory;
mapping(address pool => Position) public quoteLiquidityPositions;
mapping(address pool => Position) public tokenLiquidityPositions;
~~~

Do not port action IDs, actor blacklists, AmmplifyFlatActor, or treasury distribution.

- [ ] **Step 4: Port the dual-range formulas without rearranging them**

The quote-side range is the reference MON range with names changed only:

~~~solidity
int24 quoteLower =
    poolData.quoteIsToken0 ? poolData.alignedTick + poolData.tickSpacing : poolData.bondingTick;
int24 quoteUpper =
    poolData.quoteIsToken0 ? poolData.bondingTick : poolData.alignedTick - poolData.tickSpacing;
~~~

The token-side range is:

~~~solidity
int24 tokenLower = poolData.quoteIsToken0
    ? (TickMath.MIN_TICK / poolData.tickSpacing) * poolData.tickSpacing
    : poolData.alignedTick + poolData.tickSpacing;
int24 tokenUpper = poolData.quoteIsToken0
    ? poolData.alignedTick - poolData.tickSpacing
    : (TickMath.MAX_TICK / poolData.tickSpacing) * poolData.tickSpacing;
~~~

Use LiquidityAmounts.getLiquidityForAmounts and IUniswapV3Pool.mint exactly as the reference actor does. Add only the active-context hash, canonical factory lookup, amount maxima, and context deletion before transfer.

- [ ] **Step 5: Port fee realization exactly**

For each stored position:

~~~solidity
IUniswapV3Pool(pool).burn(position.lowerTick, position.upperTick, 0);
(amount0, amount1) = IUniswapV3Pool(pool).collect(
    address(this),
    position.lowerTick,
    position.upperTick,
    type(uint128).max,
    type(uint128).max
);
~~~

Collect quote and token positions, add their amounts, then transfer only those exact deltas to LPManager.

- [ ] **Step 6: Verify GREEN**

Run:

~~~shell
forge test --match-path test/modules/V3LiquidityActor.t.sol -vvv
~~~

Expected: all actor tests pass for both token orderings and the callback attack tests revert with the intended custom errors.

### Task 5: Rewrite LPManager Allocation Around the Reference Math

**Files:**
- Modify: src/interfaces/ILPManager.sol
- Rewrite: src/core/LPManager.sol
- Create: test/modules/LPManagerV3.t.sol
- Modify: test/modules/ModuleAttack.t.sol
- Modify: test/SetUp.t.sol

**Interfaces:**
- Consumes: TokenRegistry TokenInfo, ProtocolManager quote config, and V3LiquidityActor.
- Produces: allocate(AllocateParams), increaseLiquidity(token, tokenAmount, quoteAmount), getPositions(token), calculateBondingTick, and one-time actor wiring.

- [ ] **Step 1: Write failing LPManager allocation tests**

Port the contract-v3 test intent with these exact checks:

~~~solidity
function test_allocate_tokenIsToken0_createsTwoReferenceRanges() public;
function test_allocate_tokenIsToken1_createsTwoReferenceRanges() public;
function test_calculateBondingTick_matchesContractV3Reference() public;
function testFuzz_calculateBondingTick_matchesReference(
    uint128 virtualQuoteReserve,
    uint128 virtualTokenReserve,
    uint96 graduateFee
) public;
function test_allocate_revertsForNonCurveCaller() public;
function test_allocate_revertsForWrongFactoryPool() public;
function test_allocate_revertsForDuplicatePositions() public;
function test_allocate_returnsOnlyCallScopedRemainder() public;
function test_increaseLiquidity_reusesStoredRanges() public;
function test_increaseLiquidity_revertsForUnauthorizedCaller() public;
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/modules/LPManagerV3.t.sol -vvv
~~~

Expected: compilation fails because AllocateParams, PoolData, and the new actor wiring are absent.

- [ ] **Step 3: Define the target LPManager structs**

~~~solidity
struct PoolData {
    address pool;
    address token0;
    address token1;
    address quoteToken;
    uint160 sqrtPrice;
    int24 currentTick;
    int24 tickSpacing;
    int24 alignedTick;
    int24 bondingTick;
    bool quoteIsToken0;
}

struct AllocateParams {
    address token;
    uint256 quoteAmount;
    uint256 tokenAmount;
    uint256 virtualQuoteReserve;
    uint256 virtualTokenReserve;
    uint256 graduateFee;
}
~~~

Retain the old addLiquidity signature in ILPManager only as a transitional LegacyLiquidityDisabled revert so BondingCurve and scripts still compile before Task 9 switches every caller. Remove that compatibility selector in Task 13.

- [ ] **Step 4: Port _loadPoolData from contract-v3**

Preserve the sequence slot0, token0/token1, quote ordering, tickSpacing, and alignedTick. Add these canonical checks before returning:

~~~solidity
if (pool.factory() != factory) revert InvalidFactory();
if (pool.fee() != info.feeTier) revert InvalidPool();
if (IUniswapV3Factory(factory).getPool(token, info.quoteToken, info.feeTier) != info.pool) {
    revert InvalidPool();
}
~~~

- [ ] **Step 5: Port calculateBondingTick exactly**

~~~solidity
function calculateBondingTick(AllocateParams calldata params, bool quoteIsToken0, int24 tickSpacing)
    public
    pure
    returns (int24)
{
    uint256 adjustedTokenReserve = FullMath.mulDiv(
        params.virtualTokenReserve,
        params.virtualQuoteReserve,
        params.virtualQuoteReserve - params.graduateFee
    );

    uint160 bondingSqrtPrice = quoteIsToken0
        ? _calculateSqrtPrice(params.virtualQuoteReserve, adjustedTokenReserve)
        : _calculateSqrtPrice(adjustedTokenReserve, params.virtualQuoteReserve);

    int24 rawTick = TickMath.getTickAtSqrtRatio(bondingSqrtPrice);
    int24 alignedTick = (rawTick / tickSpacing) * tickSpacing;
    return quoteIsToken0 ? alignedTick - tickSpacing : alignedTick + tickSpacing;
}
~~~

Keep _calculateSqrtPrice byte-for-byte equivalent to the reference helper except for formatting enforced by forge fmt.

- [ ] **Step 6: Implement allocate and increaseLiquidity with call-scoped approvals**

Load the pool, derive bondingTick, transfer neither pre-existing donations nor unrelated quote balances, approve actor for params.tokenAmount and params.quoteAmount, mint the two positions, reset both approvals, and send only params minus actual used amounts to feeReceiver.

increaseLiquidity(address token, uint256 tokenAmount, uint256 quoteAmount) is selector-authorized for LPVault. It loads the stored actor ranges, approves only the call-scoped amounts, increases both positions without changing their ticks, resets approvals, and sends only rounding remainder from those two amounts to feeReceiver.

- [ ] **Step 7: Verify GREEN and reference parity**

Run:

~~~shell
forge test --match-path test/modules/LPManagerV3.t.sol -vvv
forge test --match-path test/modules/V3LiquidityActor.t.sol -vvv
forge test --match-path test/modules/ModuleAttack.t.sol -vvv
~~~

Expected: all pass and fuzzed valid inputs match ContractV3MathReference.

### Task 6: Implement the Authenticated V3 Swap Adapter

**Files:**
- Create: src/interfaces/IV3SwapAdapter.sol
- Create: src/adapters/V3SwapAdapter.sol
- Create: test/adapters/V3SwapAdapter.t.sol
- Retain until callers migrate: src/interfaces/IDexAdapter.sol
- Retain until callers migrate: src/adapters/UniswapV3ExternalAdapter.sol
- Remove after migration: src/adapters/NadSwapAdapter.sol
- Remove after migration: src/adapters/UniswapV2ExternalAdapter.sol

**Interfaces:**
- Consumes: canonical factory, registered pool, exact ERC-20 approval, and user execution bounds.
- Produces: exactInput and exactOutput swaps with authenticated callbacks and no durable balances.

- [ ] **Step 1: Write failing adapter tests**

~~~solidity
function test_exactInput_tokenToQuote_bothAddressOrderings() public;
function test_exactInput_quoteToToken_bothAddressOrderings() public;
function test_exactOutput_refundsUnusedMaximumInput() public;
function test_exactInput_revertsBelowMinOutput() public;
function test_swap_revertsAfterDeadline() public;
function test_swap_revertsForNonCanonicalPool() public;
function test_callback_revertsWithoutActiveContext() public;
function test_callback_revertsForWrongDeltaDirection() public;
function test_adapterRetainsNoCallScopedBalance() public;
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/adapters/V3SwapAdapter.t.sol -vvv
~~~

Expected: compilation fails because V3SwapAdapter and its pull-based API do not exist.

- [ ] **Step 3: Define the pull-based API**

~~~solidity
struct ExactInputParams {
    address pool;
    address tokenIn;
    address tokenOut;
    uint24 feeTier;
    uint256 amountIn;
    uint256 amountOutMin;
    uint160 sqrtPriceLimitX96;
    address recipient;
    uint256 deadline;
}

struct ExactOutputParams {
    address pool;
    address tokenIn;
    address tokenOut;
    uint24 feeTier;
    uint256 amountOut;
    uint256 amountInMax;
    uint160 sqrtPriceLimitX96;
    address recipient;
    address refundRecipient;
    uint256 deadline;
}
~~~

The adapter pulls exact input from msg.sender instead of trusting pre-donated adapter balances.

- [ ] **Step 4: Implement canonical callback authentication**

Before swap, require factory.getPool(tokenIn, tokenOut, feeTier) == pool. During callback, require active context, msg.sender == pool, matching data hash, the expected positive input delta, a non-positive output delta, and input not exceeding the stored maximum. Delete context before transferring input to the pool.

- [ ] **Step 5: Verify GREEN**

Run:

~~~shell
forge test --match-path test/adapters/V3SwapAdapter.t.sol -vvv
~~~

Expected: real V3 pool swaps pass in both address orders; every forged callback path reverts.

### Task 7: Rewire CreatorFeeProcessor Directly to LPManager

**Files:**
- Modify: src/interfaces/ICreatorFeeProcessor.sol
- Modify: src/core/CreatorFeeProcessor.sol
- Modify: test/token/CreatorFeeProcessorV2.t.sol
- Create: test/token/CreatorFeeProcessorLPFee.t.sol
- Mark for removal: src/interfaces/IFeeCollector.sol
- Mark for removal: src/core/FeeCollector.sol

**Interfaces:**
- Consumes: quote-token approval from LPManager and per-token VaultSlot configuration from BondingCurve.
- Produces: processFee(token, quoteToken, amount) with unchanged vault BPS allocation semantics.

- [ ] **Step 1: Write failing direct-processing tests**

~~~solidity
function test_processFee_onlyLpManager() public;
function test_processFee_pullsExactQuoteAmount() public;
function test_processFee_distributesAllRoundingToLastVault() public;
function test_processFee_revertsAtomicallyWhenVaultFails() public;
function test_processFee_rejectsWrongRegisteredQuoteToken() public;
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/token/CreatorFeeProcessorLPFee.t.sol -vvv
~~~

Expected: compilation fails because processFee and lpManager authorization do not exist.

- [ ] **Step 3: Replace FeeCollector authorization**

Use immutable bondingCurve, immutable lpManager, and immutable tokenRegistry. The core entrypoint is:

~~~solidity
function processFee(address token, address quoteToken, uint256 amount) external {
    if (msg.sender != lpManager) revert NotAuthorized();
    if (ITokenRegistry(tokenRegistry).getQuoteToken(token) != quoteToken) revert InvalidQuoteToken();
    if (amount == 0) return;

    IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), amount);
    _distributeToVaults(token, quoteToken, amount);
}
~~~

Retain setup authorization, MAX_VAULTS, exact BPS total, last-vault rounding, and synchronous afterDeposit callbacks.

- [ ] **Step 4: Verify GREEN**

Run:

~~~shell
forge test --match-path test/token/CreatorFeeProcessorLPFee.t.sol -vvv
forge test --match-path test/token/CreatorFeeProcessorV2.t.sol -vvv
~~~

Expected: migrated processor tests pass; obsolete FeeCollector-specific assertions are removed rather than weakened.

### Task 8: Add LP Fee Collection, Token-to-Quote Conversion, and Configured Split

**Files:**
- Modify: src/interfaces/ILPManager.sol
- Modify: src/core/LPManager.sol
- Extend: test/modules/LPManagerV3.t.sol
- Create: test/modules/LPManagerCollectV3.t.sol
- Create: test/modules/LPManagerCollectAttack.t.sol

**Interfaces:**
- Consumes: V3LiquidityActor.collectFees, V3SwapAdapter.exactInput, ProtocolManager.lpFeeProtocolShareBps, feeReceiver, and CreatorFeeProcessor.processFee.
- Produces: collect(CollectParams), collectBatch(CollectParams[]), and callStaticGetAccumulatedFees(token).

- [ ] **Step 1: Write failing collection tests**

~~~solidity
function test_collect_onlyQuoteFee_splitsConfiguredShare() public;
function test_collect_tokenFee_swapsAllTokenToQuoteThenSplits() public;
function test_collect_bothFees_usesCombinedQuoteValue() public;
function test_collect_zeroProtocolShare_sendsAllToProcessor() public;
function test_collect_fullProtocolShare_sendsNoneToProcessor() public;
function test_collect_oddAmount_assignsRemainderToProtocol() public;
function test_collect_revertsBelowMinQuoteOut() public;
function test_collect_revertsAfterDeadline() public;
function test_collect_revertsForDuplicateBatchToken() public;
function test_collect_isolatesPreexistingDonations() public;
function test_collect_revertsAtomicallyWhenProcessorVaultFails() public;
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/modules/LPManagerCollectV3.t.sol -vvv
~~~

Expected: compilation fails because CollectParams and collection distribution do not exist.

- [ ] **Step 3: Implement the agreed collection parameter and batching API**

~~~solidity
struct CollectParams {
    address token;
    uint256 minQuoteOut;
    uint160 sqrtPriceLimitX96;
    uint256 deadline;
}

function collect(CollectParams calldata params)
    external
    restricted
    nonReentrant
    returns (uint256 quoteFee, uint256 tokenFee, uint256 swappedQuote);

function collectBatch(CollectParams[] calldata params) external restricted nonReentrant;
~~~

- [ ] **Step 4: Collect both actor positions and swap token fee**

Snapshot LPManager token and quote balances, call actor.collectFees(pool), derive tokenFee and quoteFee from token order, approve V3SwapAdapter for exactly tokenFee, execute exact-input token-to-quote swap, and reset approval. Require the adapter to consume the entire tokenFee.

- [ ] **Step 5: Implement configurable split with protocol rounding**

~~~solidity
uint256 totalQuoteFee = quoteFee + swappedQuote;
uint256 protocolShareBps = IProtocolManager(authority()).lpFeeProtocolShareBps(quoteToken);
uint256 processorShare = FixedPointMathLib.mulDiv(
    totalQuoteFee,
    BPS - protocolShareBps,
    BPS
);
uint256 protocolShare = totalQuoteFee - processorShare;
~~~

Transfer protocolShare exactly to feeReceiver. Approve CreatorFeeProcessor for processorShare, call processFee, and reset approval. Verify post-call token and quote balances equal the snapshots.

- [ ] **Step 6: Verify GREEN and attack coverage**

Run:

~~~shell
forge test --match-path test/modules/LPManagerCollectV3.t.sol -vvv
forge test --match-path test/modules/LPManagerCollectAttack.t.sol -vvv
~~~

Expected: all split, slippage, callback, donation, rollback, and no-dust tests pass.

### Task 9: Migrate BondingCurve Creation, Fees, and Graduation

**Files:**
- Modify: src/interfaces/IBondingCurve.sol
- Modify: src/core/BondingCurve.sol
- Modify: src/interfaces/IToken.sol
- Modify: src/token/Token.sol
- Modify: test/core/BondingCurve.t.sol
- Replace: test/core/BondingCurveV2.t.sol
- Modify: test/core/Fee.t.sol
- Modify: test/core/Graduation.t.sol
- Modify: test/core/BuyCap.t.sol
- Modify: test/core/BondingCurveAttack.t.sol
- Modify: test/core/QuoteReserveAttack.t.sol

**Interfaces:**
- Consumes: V3PoolDeployer, TokenRegistry, CreatorFeeProcessor.setup, LPManager.allocate, and ProtocolManager quote config.
- Produces: creator-fee-free token creation and atomic V3 graduation.

- [ ] **Step 1: Write failing lifecycle tests**

~~~solidity
function test_create_createsAndInitializesCanonicalV3Pool() public;
function test_create_hasNoCreatorFeeParameter() public;
function test_buy_chargesOnlyCurveProtocolFeeAndSnipingPenalty() public;
function test_sell_chargesOnlyCurveProtocolFee() public;
function test_graduate_allocatesTwoPermanentV3Positions() public;
function test_graduate_passesSnapshottedGraduateFeeToBondingTickMath() public;
function test_graduate_preservesQuoteReserveIsolationAcrossQuoteTokens() public;
function test_graduate_revertsAtomicallyWhenV3MintFails() public;
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/core/Graduation.t.sol -vvv
~~~

Expected: tests fail because creation still deploys NadFunPair and LPManager still receives V2 liquidity parameters.

- [ ] **Step 3: Remove creator-fee fields from public creation and curve state**

Remove creatorFeeRate and dexType from CreateTokenParams, CreateParams, Curve, create events, validation, total-fee calculations, and exact-in/exact-out quote calculations. Keep vault allocations because they now configure the LP-fee processor share.

- [ ] **Step 4: Replace V2 pair creation and FeeCollector setup**

BondingCurve._create must:

~~~solidity
token = _tokenImplementation.cloneDeterministic(params.salt);
address pool = IV3PoolDeployer(_modules[MODULE_V3_POOL_DEPLOYER]).createPool(token, params.quoteToken);
uint24 feeTier = _protocolManager.v3FeeTier(params.quoteToken);
ITokenRegistry(registry).registerV3(token, pool, params.quoteToken, feeTier);
ICreatorFeeProcessor(processor).setup(token, _setupVaults(token, params.vaults));
IToken(token).initialize(params.name, params.symbol, params.tokenURI, address(this), pool);
~~~

Delete FeeCollector.setup and MODULE_FACTORY. Add MODULE_V3_POOL_DEPLOYER.

- [ ] **Step 5: Replace V2 graduation call with V3 allocation**

After setting graduated state and deducting graduateFee, transfer only the calculated launch token and quote amounts to LPManager, then call:

~~~solidity
ILPManager(lpManager).allocate(
    ILPManager.AllocateParams({
        token: token,
        quoteAmount: quoteBalanceAfterGraduateFee,
        tokenAmount: tokenForLiquidity,
        virtualQuoteReserve: curve.initialQuoteReserve,
        virtualTokenReserve: curve.initialTokenReserve,
        graduateFee: curve.graduateFee
    })
);
~~~

- [ ] **Step 6: Verify GREEN**

Run:

~~~shell
forge test --match-path test/core/BondingCurve.t.sol -vvv
forge test --match-path test/core/Fee.t.sol -vvv
forge test --match-path test/core/Graduation.t.sol -vvv
forge test --match-path test/core/BondingCurveAttack.t.sol -vvv
forge test --match-path test/core/QuoteReserveAttack.t.sol -vvv
~~~

Expected: all curve and graduation tests pass with no creator-fee accounting and both token address orders covered.

### Task 10: Migrate the Unified Router and Quoting Surface

**Files:**
- Modify: src/interfaces/INadFunRouter.sol
- Modify: src/router/NadFunRouter.sol
- Modify: test/core/NadFunRouter.t.sol
- Modify: test/core/NadFunRouterCreate.t.sol
- Modify: test/core/NadFunRouterPermit.t.sol
- Modify: test/core/NadFunRouterNativeQuoteGuard.t.sol
- Modify: test/core/NadFunRouterReceive.t.sol
- Create: test/router/RouterV3Swap.t.sol
- Remove after migration: src/interfaces/INadFunRouter02.sol
- Remove after migration: src/router/NadFunRouter02.sol

**Interfaces:**
- Consumes: TokenRegistry V3 metadata, V3SwapAdapter, canonical QuoterV2, wrapped-native, and LVMon minter.
- Produces: unified exact-input/exact-output curve/V3 buy and sell routes.

- [ ] **Step 1: Write failing post-graduation router tests**

~~~solidity
function test_buyGraduated_routesExactInputThroughV3() public;
function test_sellGraduated_routesExactInputThroughV3() public;
function test_exactOutBuyGraduated_refundsUnusedQuote() public;
function test_exactOutSellGraduated_respectsMaximumTokenInput() public;
function test_v3Swap_revertsBelowAmountOutMin() public;
function test_nativeRoute_requiresConfiguredWrappedQuoteToken() public;
function test_erc20OnlyQuote_rejectsNativeRoute() public;
function test_permitRoute_worksAfterGraduation() public;
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/router/RouterV3Swap.t.sol -vvv
~~~

Expected: post-graduation calls fail because the router still loads a V2 adapter and reserve quote methods.

- [ ] **Step 3: Remove creator fee and DexType from router creation**

The final CreateParams retains name, symbol, tokenURI, quoteToken, vaults, salt, buyQuoteAmount, and deadline only.

- [ ] **Step 4: Route graduated swaps through V3SwapAdapter**

For buys, tokenIn is registry.quoteToken and tokenOut is the launched token. For sells, reverse them. Pass pool, feeTier, amount bounds, recipient, deadline, and the direction-correct sqrtPriceLimitX96.

- [ ] **Step 5: Replace V2 view quoting**

Keep getBondingCurveAmountOut and getBondingCurveAmountIn as view. Make lifecycle-aware getAmountOut/getAmountIn non-view and delegate graduated quotes to the configured QuoterV2. Tests must invoke these quote methods with eth_call semantics and must prove execution does not trust the quote result.

- [ ] **Step 6: Verify GREEN**

Run:

~~~shell
forge test --match-path test/router/RouterV3Swap.t.sol -vvv
forge test --match-path test/core/NadFunRouter.t.sol -vvv
forge test --match-path test/core/NadFunRouterPermit.t.sol -vvv
forge test --match-path test/core/NadFunRouterNativeQuoteGuard.t.sol -vvv
~~~

Expected: curve and V3 lifecycle routes pass for ERC-20 quote, wrapped-native quote, LVMon quote, permits, refunds, and both token orders.

### Task 11: Migrate Vault Execution to V3

**Files:**
- Modify: src/vault/BurnVault.sol
- Modify: src/vault/LPVault.sol
- Modify: src/vault/DividendVault.sol
- Modify: src/vault/CreatorFeeVault.sol
- Modify: src/vault/GiftVault.sol
- Modify: test/vault/BurnVaultV2.t.sol
- Modify: test/vault/LPVaultV2.t.sol
- Modify: test/vault/DividendVault.t.sol
- Modify: test/vault/CreatorFeeVault.t.sol
- Modify: test/vault/GiftVault.t.sol
- Modify: test/vault/VaultAttack.t.sol

**Interfaces:**
- Consumes: V3SwapAdapter, TokenRegistry pool metadata, and LPManager.increaseLiquidity.
- Produces: unchanged vault BPS semantics with V3 buyback, conversion, and reinvestment.

- [ ] **Step 1: Write failing V3 vault tests**

~~~solidity
function test_burnVault_executesV3BuybackAndBurn() public;
function test_burnVault_revertsOnSlippage() public;
function test_lpVault_afterDeposit_onlyAccumulatesDuringCollect() public;
function test_lpVault_executePendingZap_increasesExistingPositions() public;
function test_lpVault_cannotRemoveLaunchPrincipal() public;
function test_dividendVault_convertsThroughCanonicalV3Pool() public;
function test_vaultCallbackFailure_revertsWholeProcessorDistribution() public;
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/vault/BurnVaultV2.t.sol -vvv
forge test --match-path test/vault/LPVaultV2.t.sol -vvv
~~~

Expected: tests fail because BurnVault and LPVault still depend on NadFunPair reserves and V2 liquidity tokens.

- [ ] **Step 3: Migrate BurnVault**

Keep pending accumulation and authorization. Replace the NadFun adapter swap with V3SwapAdapter exactInput using explicit minTokenOut, sqrtPriceLimitX96, and deadline. Burn the exact received launch-token delta.

- [ ] **Step 4: Migrate LPVault as deferred reinvestment**

afterDeposit only records quote. executePendingZap:

1. snapshots the pending quote;
2. swaps half to launch token through V3SwapAdapter with explicit bounds;
3. transfers the remaining quote and received token to LPManager;
4. calls increaseLiquidity on the two existing actor ranges;
5. resets pending state before external calls and relies on transaction rollback on failure.

Do not mint a transferable NFT or create a separate removable position.

- [ ] **Step 5: Migrate DividendVault conversion**

Require every configured conversion pool to match canonical factory.getPool for its token pair and fee tier. Use exact-input bounds per conversion and preserve Merkle claim accounting.

- [ ] **Step 6: Verify GREEN**

Run:

~~~shell
forge test --match-path test/vault -vvv
~~~

Expected: all vault tests pass and no vault imports INadFunPair or V2 reserve math.

### Task 12: Rebuild Deployment Wiring and Full Lifecycle Fixtures

**Files:**
- Rewrite: script/deploy/normal/Deploy.s.sol
- Modify: script/deploy/normal/UpdateQuoteToken.s.sol
- Modify: script/deploy/safe deployment/configuration scripts that remain applicable
- Modify: test/SetUp.t.sol
- Replace: test/integration/FullLifecycleE2E.t.sol
- Create: test/integration/FullLifecycleV3MultiQuote.t.sol
- Create: test/invariant/LPPrincipalLock.invariant.t.sol
- Create: test/invariant/LPFeeConservation.invariant.t.sol
- Modify: .github/workflows/test.yml

**Interfaces:**
- Consumes: every module from Tasks 2-11.
- Produces: reproducible fresh deployment wiring and full lifecycle/invariant coverage.

- [ ] **Step 1: Write the failing full lifecycle test**

The test must execute:

~~~solidity
function test_fullLifecycle_twoQuoteTokens() public {
    address tokenA = _createAndGraduate(address(quote18), 10_000, 5_000);
    address tokenB = _createAndGraduate(address(quote6), 3_000, 7_500);

    _tradeBothDirections(tokenA);
    _tradeBothDirections(tokenB);
    _collectAndAssertConfiguredSplit(tokenA);
    _collectAndAssertConfiguredSplit(tokenB);
    _assertPermanentPositions(tokenA);
    _assertPermanentPositions(tokenB);
}
~~~

- [ ] **Step 2: Run and verify RED**

Run:

~~~shell
forge test --match-path test/integration/FullLifecycleV3MultiQuote.t.sol -vvv
~~~

Expected: fixture compilation or wiring fails until the new deployment order and permissions exist.

- [ ] **Step 3: Implement the deployment order**

The deployment sequence is:

1. ProtocolManager implementation and proxy.
2. Token implementation.
3. TokenRegistry implementation and proxy.
4. BondingCurve implementation and proxy.
5. V3PoolDeployer implementation and proxy.
6. V3SwapAdapter singleton.
7. LPManager implementation and proxy.
8. V3LiquidityActor with LPManager proxy as owner.
9. CreatorFeeProcessor with BondingCurve and LPManager proxy addresses.
10. VaultRegistry and retained vault implementations/proxies.
11. NadFunRouter implementation and proxy.
12. One-time actor/processor wiring and ProtocolManager selector permissions.
13. Quote token configurations with fee tier and LP protocol share.

- [ ] **Step 4: Configure exact selector permissions**

Grant only:

- BondingCurve -> V3PoolDeployer.createPool
- BondingCurve -> TokenRegistry.register
- BondingCurve -> LPManager.allocate
- authorized collector -> LPManager.collect and collectBatch
- LPVault -> LPManager.increaseLiquidity
- admin -> UUPS upgrade authorization and quote configuration

Do not grant wildcard target authority.

- [ ] **Step 5: Add invariants**

LPPrincipalLock must snapshot actor position liquidity after graduation and assert it never decreases across handler swaps, collects, vault callbacks, and reinvestments.

LPFeeConservation must assert:

~~~text
collectedQuote + swappedQuote
= protocolReceiverDelta + processorVaultDeltas
~~~

and LPManager, actor, processor, and adapter retain no call-scoped distribution amount after success.

- [ ] **Step 6: Verify GREEN**

Run:

~~~shell
forge test --match-path test/integration/FullLifecycleV3MultiQuote.t.sol -vvv
forge test --match-path test/invariant/LPPrincipalLock.invariant.t.sol -vvv
forge test --match-path test/invariant/LPFeeConservation.invariant.t.sol -vvv
~~~

Expected: lifecycle and both invariants pass for multiple quote decimals and both token orders.

### Task 13: Remove the V2 and Creator-Fee Surface

**Files:**
- Delete: src/dex/
- Delete: src/adapters/NadSwapAdapter.sol
- Delete: src/adapters/UniswapV2ExternalAdapter.sol
- Delete: src/core/FeeCollector.sol
- Delete: src/interfaces/IFeeCollector.sol
- Delete: src/router/NadFunRouter02.sol
- Delete: src/interfaces/INadFunRouter02.sol
- Delete: test/dex/
- Delete: test/fee/
- Delete or migrate: test/router/RouterLiquidity.t.sol
- Delete: lib/v2-core/
- Delete: lib/v2-periphery/
- Delete: lib/solidity-lib/ if no retained import remains
- Modify: foundry.toml
- Modify: remappings.txt
- Modify: .gitmodules
- Modify: script/extract-abis.sh
- Modify: abis/
- Modify: src/interfaces/IProtocolManager.sol
- Modify: src/core/ProtocolManager.sol
- Modify: test/core/ProtocolManager.t.sol
- Modify: test/core/ProtocolManagerV3.t.sol

**Interfaces:**
- Consumes: completed V3 lifecycle.
- Produces: a V3-only compile graph with no obsolete selectors or artifacts.

- [ ] **Step 1: Write a failing legacy-surface guard**

Create a shell/CI assertion in the test workflow:

~~~shell
if rg -n 'NadFunPair|NadFunFactory|creatorFeeRate|dexProtocolFeeRate|settlementThreshold|FeeCollector|NadFunRouter02' src script; then
  exit 1
fi
~~~

Run it before cleanup and verify it exits 1 with legacy matches.

- [ ] **Step 2: Delete only the enumerated legacy files and imports**

Use apply_patch for source/test deletions. Remove V2 remappings and .gitmodules entries only after rg confirms no retained import.

At the same checkpoint, remove creator-fee rate state/functions, dexProtocolFeeRate, and settlementThreshold from ProtocolManager and delete setV3QuoteConfig. Fold v3FeeTier and lpFeeProtocolShareBps into the final addQuoteToken and updateQuoteToken signatures used by deployment scripts and tests. Remove pair, DexType, and the legacy register function from TokenRegistry, then rename registerV3 to register so its final TokenInfo is exactly pool, quoteToken, and feeTier.

- [ ] **Step 3: Regenerate ABIs**

Run:

~~~shell
bash script/extract-abis.sh
~~~

Expected: V3PoolDeployer, V3LiquidityActor, V3SwapAdapter, updated LPManager, ProtocolManager, TokenRegistry, CreatorFeeProcessor, BondingCurve, Router, and Vault ABIs exist; V2 pair/factory/collector/router02 ABIs do not.

- [ ] **Step 4: Verify the legacy guard is GREEN**

Run the same rg guard.

Expected: exit 0 with no output.

- [ ] **Step 5: Build after physical removal**

Run:

~~~shell
forge fmt
forge build --sizes
~~~

Expected: build succeeds without V2 remappings or source files.

### Task 14: Update Product and Contract Documentation

**Files:**
- Modify: README.md
- Modify: README.ko.md
- Modify: PRODUCT.md
- Modify: TEST.md
- Modify: CHANGELOG.md
- Modify: docs/ARCHITECTURE.md
- Modify: docs/CONTRACTS.md
- Modify: docs/PROTOCOL_FLOW.md
- Modify: docs/PROTOCOL_FLOW.ko.md
- Replace affected files under: docs/contracts/en/
- Replace affected files under: docs/contracts/ko/
- Modify: metadata/vaults/

**Interfaces:**
- Consumes: final selectors, events, errors, deployment wiring, and fee behavior.
- Produces: English/Korean documentation that describes only the implemented V3 lifecycle.

- [ ] **Step 1: Update lifecycle and fee documentation**

Document:

- pool creation and initialization at token creation;
- curveProtocolFee only during curve trading;
- no creator trade fee and no post-graduation dexProtocolFee;
- permanent dual-range positions;
- token-fee conversion to quote;
- per-quote lpFeeProtocolShareBps;
- direct feeReceiver and CreatorFeeProcessor distribution;
- multiple quote token and native-route restrictions.

- [ ] **Step 2: Update contract references**

Add V3PoolDeployer, V3LiquidityActor, V3SwapAdapter, V3 LPManager allocation/collect APIs, and CollectParams. Remove NadFunPair, NadFunFactory, FeeCollector, NadFunRouter02, creator fee rate, settlement threshold, and V2 LP token language.

- [ ] **Step 3: Validate documentation**

Run:

~~~shell
rg -n 'NadFunPair|NadFunFactory|creatorFeeRate|dexProtocolFeeRate|settlementThreshold|FeeCollector|NadFunRouter02' README.md README.ko.md PRODUCT.md TEST.md docs
git diff --check
~~~

Expected: no stale lifecycle references except an explicitly labeled changelog removal entry; no whitespace errors.

### Task 15: Final Validation and Review Gates

**Files:**
- Review: every changed file
- No new production files unless a failing test demonstrates a missing boundary

**Interfaces:**
- Consumes: completed Tasks 1-14.
- Produces: validated local implementation ready for an explicitly authorized publish workflow.

- [ ] **Step 1: Format and build**

Run:

~~~shell
forge fmt
forge fmt --check
forge build --sizes
~~~

Expected: all commands exit 0 with no warnings introduced by project code.

- [ ] **Step 2: Run focused V3 suites**

Run:

~~~shell
forge test --match-path test/core/V3PoolDeployer.t.sol -vvv
forge test --match-path test/integration/UniswapV3Compatibility.t.sol -vvv
forge test --match-path test/modules/V3LiquidityActor.t.sol -vvv
forge test --match-path test/modules/LPManagerV3.t.sol -vvv
forge test --match-path test/modules/LPManagerCollectV3.t.sol -vvv
forge test --match-path test/adapters/V3SwapAdapter.t.sol -vvv
forge test --match-path test/integration/FullLifecycleV3MultiQuote.t.sol -vvv
forge test --match-path test/invariant/LPPrincipalLock.invariant.t.sol -vvv
forge test --match-path test/invariant/LPFeeConservation.invariant.t.sol -vvv
~~~

Expected: every focused suite passes.

- [ ] **Step 3: Run the full suite**

Run:

~~~shell
forge test -vvv
~~~

Expected: all local tests pass. Fork tests remain gated unless their required non-secret RPC/factory/quoter configuration is already available through ignored environment values.

- [ ] **Step 4: Inspect UUPS and selector safety**

Check every UUPS implementation disables initializers, every initializer is single-use, all selector permissions match Task 12, and no public function can remove actor principal. Because this is a fresh deployment, report storage layouts for documentation but do not claim compatibility with the deleted V2 deployment.

- [ ] **Step 5: Run the required correctness review**

Use a code_reviewer agent to inspect correctness, regressions, maintainability, V3 formula fidelity, test gaps, and diff scope. Fix each confirmed issue with a new failing regression test.

- [ ] **Step 6: Run the required security review**

Use a security_reviewer agent to inspect callback authentication, canonical pool validation, reentrancy, balance-delta accounting, slippage, multi-quote isolation, role wiring, vault rollback, and permanent principal invariants. Use deep_security_reviewer only if authorization, callback trust, or principal-lock findings remain high risk. Fix each confirmed issue with a failing exploit/regression test first.

- [ ] **Step 7: Final diff and artifact audit**

Run:

~~~shell
git status --short
git diff --stat
git diff --check
rg -n 'NadFunPair|NadFunFactory|creatorFeeRate|dexProtocolFeeRate|settlementThreshold|FeeCollector|NadFunRouter02' src script
~~~

Expected: the legacy scan is empty; every changed/copied/deleted file is accounted for; no secret, build output, cache, broadcast, or local deployment payload is present.

- [ ] **Step 8: Report without publishing**

Report all copied, created, modified, and deleted paths; exact formatter/build/test results; skipped fork checks; dependency revisions; formula-parity evidence; reviewer findings; and remaining deployment uncertainty. Do not commit or push until the user explicitly requests it.

## Execution Notes

- The highest-risk implementation sequence is Tasks 3-5 and 8-9. Do not parallelize overlapping edits to ProtocolManager, TokenRegistry, LPManager, BondingCurve, or test/SetUp.t.sol.
- Tasks 4 and 6 can be implemented independently after Task 3 interfaces are stable.
- Documentation and ABI work starts only after selectors stop changing.
- The contract-v3 reference contains a broader actor registry and treasury split. Those parts are intentionally not ported because the approved design uses one actor and ProtocolManager/Vault distribution.
- Mathematical refactoring is prohibited until ContractV3MathReference parity tests are green. After parity is established, retain the reference expression order unless a failing overflow test proves a required Solidity 0.8.24 safety adaptation.
