# Protocol WETH Quote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy one permissionless, fully backed WETH contract, register it as the default Uniswap V3 quote, wire every native-aware protocol component to that address, and prove the create-to-graduation-to-full-sell lifecycle.

**Architecture:** `WrappedEther` is a thin, non-upgradeable inheritance wrapper around Solady `WETH`, with no custom accounting or admin surface. The deployment script creates it before all proxy modules, registers it in `ProtocolManager`, configures its V3 fee tier and LP fee split, then uses the same address for Router and vault wiring. The existing V3 pool deployer, registry, LP manager, actor, and adapter form the post-graduation path.

**Tech Stack:** Solidity 0.8.24, Foundry, Solady WETH/ERC20, OpenZeppelin UUPS/AccessManaged, Uniswap V3 core and periphery libraries.

## Global Constraints

- Deploy exactly one protocol WETH instance per deployment run.
- WETH must not expose owner, privileged mint, privileged burn, pause, blacklist, fee, or recovery functions.
- The WETH address must come from the deployment result, never from a `WETH` or `WMON` environment variable.
- `deposit()` and direct native transfer mint 1:1; `withdraw(uint256)` burns before sending native value.
- The new V3 quote configuration must set `dexProtocolFeeRate` to `0`.
- All Router, vault, Treasury, V3 pool, registry, and lifecycle paths must use the same WETH address.
- Preserve unrelated user changes, including the in-progress V3 `BondingCurve` graduation branch.
- LP fee collection/swap/distribution is outside this plan; only its quote-token compatibility is required.
- The user-facing deployment target is `GiwaRouter` from `origin/giwarouter` commit `db4bc8e`, not `NadFunRouter`.
- Graduated swaps use `V3SwapAdapter`. `GiwaRouter.initialize` receives ProtocolManager, BondingCurve, TokenRegistry, deployed WETH, V3SwapAdapter, and a QuoterV2 whose factory matches the adapter factory.
- Legacy `NadFunRouter` source may remain for compatibility, but deployment, permissions, vault wiring, lifecycle tests, ABIs, and documentation must target `GiwaRouter`.
- Fresh deployments are V3-only: remove the V2 `createPair/register/addLiquidity` graduation path and convert or delete every test that graduates through V2. `BondingCurve` token creation must reject a non-V3 `dexType`.

## File Structure

- Create `src/token/WrappedEther.sol`: protocol-owned wrapped-native token with no custom state or privileged API.
- Create `test/token/WrappedEther.t.sol`: unit and invariant-style backing tests.
- Modify `script/deploy/normal/Deploy.s.sol`: deploy WETH once, configure quote/V3 fields, deploy and wire V3 modules, permissions, `V3SwapAdapter`, QuoterV2, and `GiwaRouter`.
- Modify `src/core/BondingCurve.sol`: complete the already-started V3 create/register and graduation/allocate branch.
- Modify `test/SetUp.t.sol`: provide a real local V3 factory, deployer, actor, adapter, permissions, and WETH quote fixture without replacing existing V2 fixtures.
- Create `test/integration/WethV3GraduationE2E.t.sol`: create, graduate, inspect liquidity positions, buy post-graduation, and sell the seller's entire token balance.
- Modify `script/deploy/normal/WrapMon.s.sol`: remove reliance on the obsolete `WMON` environment name or replace it with the deployed-address artifact input used by operational scripts.
- Modify deployment documentation/environment examples discovered through `rg -n "WMON|DEX_PROTOCOL_FEE_RATE|V3_FEE_TIER|LP_FEE_PROTOCOL_SHARE_BPS" script docs .env.example` so operators cannot configure two wrapped-native addresses.

---

### Task 1: Add the permissionless WETH contract

**Files:**
- Create: `src/token/WrappedEther.sol`
- Create: `test/token/WrappedEther.t.sol`

**Interfaces:**
- Consumes: Solady `WETH.deposit()`, `WETH.withdraw(uint256)`, ERC20 `transfer`, `approve`, and `transferFrom`.
- Produces: `WrappedEther` with inherited `deposit()`, `withdraw(uint256)`, `receive()`, `name()`, `symbol()`, `decimals()`, `totalSupply()`, and ERC20 balance/allowance functions.

- [ ] **Step 1: Write the failing WETH tests**

Create `test/token/WrappedEther.t.sol` with explicit deposit, receive, withdrawal, transfer/allowance, insufficient withdrawal, and backing checks:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WrappedEther} from "../../src/token/WrappedEther.sol";

contract WrappedEtherTest is Test {
    WrappedEther internal weth;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        weth = new WrappedEther();
        vm.deal(alice, 100 ether);
    }

    function test_depositAndReceiveMintOneToOne() public {
        vm.prank(alice);
        weth.deposit{value: 3 ether}();
        vm.prank(alice);
        (bool ok,) = address(weth).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(weth.balanceOf(alice), 5 ether);
        assertEq(weth.totalSupply(), 5 ether);
        assertEq(address(weth).balance, 5 ether);
    }

    function test_withdrawBurnsBeforeReturningNative() public {
        vm.prank(alice);
        weth.deposit{value: 5 ether}();
        uint256 nativeBefore = alice.balance;
        vm.prank(alice);
        weth.withdraw(2 ether);
        assertEq(weth.balanceOf(alice), 3 ether);
        assertEq(alice.balance, nativeBefore + 2 ether);
        assertEq(weth.totalSupply(), address(weth).balance);
    }

    function test_transferAndTransferFromPreserveBacking() public {
        vm.prank(alice);
        weth.deposit{value: 5 ether}();
        vm.prank(alice);
        weth.approve(bob, 2 ether);
        vm.prank(bob);
        weth.transferFrom(alice, bob, 2 ether);
        assertEq(weth.balanceOf(bob), 2 ether);
        assertEq(weth.totalSupply(), address(weth).balance);
    }

    function test_withdrawAboveBalanceRevertsWithoutChangingBacking() public {
        vm.prank(alice);
        weth.deposit{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert();
        weth.withdraw(2 ether);
        assertEq(weth.balanceOf(alice), 1 ether);
        assertEq(weth.totalSupply(), address(weth).balance);
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
forge test --match-path test/token/WrappedEther.t.sol -vv
```

Expected: compilation fails because `src/token/WrappedEther.sol` does not exist.

- [ ] **Step 3: Add the minimal WETH implementation**

Create `src/token/WrappedEther.sol` without overrides or privileged functions:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WETH} from "solady/tokens/WETH.sol";

/// @title WrappedEther
/// @notice Permissionless 1:1 wrapper for the chain's native ETH.
contract WrappedEther is WETH {}
```

- [ ] **Step 4: Verify WETH behavior and formatting**

Run:

```bash
forge fmt src/token/WrappedEther.sol test/token/WrappedEther.t.sol
forge test --match-path test/token/WrappedEther.t.sol -vv
forge inspect src/token/WrappedEther.sol:WrappedEther methods
```

Expected: 4 tests pass; the method list contains inherited WETH/ERC20 functions and no owner/admin/mint/recovery method.

- [ ] **Step 5: Commit Task 1**

```bash
git add src/token/WrappedEther.sol test/token/WrappedEther.t.sol
git commit -m "feat: add protocol wrapped ether"
```

---

### Task 2: Make WETH the single deployment-owned quote

**Files:**
- Modify: `script/deploy/normal/Deploy.s.sol`
- Modify: `script/deploy/normal/WrapMon.s.sol`
- Create: `test/integration/ProtocolWethQuote.t.sol`

**Interfaces:**
- Consumes: `WrappedEther`, `ProtocolManager.addQuoteToken(...)`, and `ProtocolManager.setV3QuoteConfig(address,uint24,uint16)`.
- Produces: `Deployed.weth`, one active WETH quote config, and downstream deployment calls that receive `d.weth`.

- [ ] **Step 1: Write a failing quote configuration test**

Create `test/integration/ProtocolWethQuote.t.sol` using a proxy-backed `ProtocolManager` and the real WETH:

```solidity
function test_wethIsActiveV3QuoteWithNoDexTradeFee() public {
    WrappedEther weth = new WrappedEther();
    ProtocolManager pm = _deployProtocolManager(address(this), feeReceiver);
    pm.addQuoteToken(address(weth), 30_000 ether, 1_073_000_000 ether, 273_000_000 ether, 0, 1 ether, 100, 0, 1 ether);
    pm.setV3QuoteConfig(address(weth), 3000, 5000);

    IProtocolManager.QuoteConfig memory config = pm.getConfig(address(weth));
    assertTrue(config.active);
    assertEq(config.dexProtocolFeeRate, 0);
    assertEq(config.v3FeeTier, 3000);
    assertEq(config.lpFeeProtocolShareBps, 5000);
}
```

Also add a source-level deployment assertion that calls a small `DeployHarness` exposing the internal WETH/configuration helper and asserts the returned WETH address is reused, not read from `WMON`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
forge test --match-path test/integration/ProtocolWethQuote.t.sol -vv
```

Expected: fails because `Deploy.Deployed` has no `weth` field and the deploy script still reads `WMON`.

- [ ] **Step 3: Change deployment inputs and deployed-address storage**

In `Deploy.s.sol`:

```solidity
import {WrappedEther} from "../../../src/token/WrappedEther.sol";

struct QuoteTokenConfig {
    uint256 virtualReserve;
    uint256 virtualTokenReserve;
    uint256 minTokenReserve;
    uint256 deployFee;
    uint256 graduateFee;
    uint16 curveProtocolFeeRate;
    uint256 settlementThreshold;
    uint24 v3FeeTier;
    uint16 lpFeeProtocolShareBps;
}

struct Deployed {
    address weth;
    // retain the existing fields in their current order after this field
}
```

Remove `vm.envAddress("WMON")`, deploy exactly once immediately after `vm.startBroadcast`, and pass `d.weth` everywhere that currently receives `wmon`:

```solidity
d.weth = address(new WrappedEther());
d.protocolManager = _deployProtocolManager(deployer, feeReceiver, d.weth, lvmon);
d.giwaRouter = _deployGiwaRouter(
    d.protocolManager,
    d.bondingCurve,
    d.tokenRegistry,
    d.weth,
    d.v3SwapAdapter,
    d.quoterV2
);
```

Do not deploy a second wrapped token in any helper.

- [ ] **Step 4: Register the WETH V3 quote atomically during deployment**

Change `_deployProtocolManager` so WETH is registered with zero post-graduation DEX fee and then gets its V3 config:

```solidity
QuoteTokenConfig memory config = _quoteTokenConfig();
pm.addQuoteToken(
    weth,
    config.virtualReserve,
    config.virtualTokenReserve,
    config.minTokenReserve,
    config.deployFee,
    config.graduateFee,
    config.curveProtocolFeeRate,
    0,
    config.settlementThreshold
);
pm.setV3QuoteConfig(weth, config.v3FeeTier, config.lpFeeProtocolShareBps);
```

Read `V3_FEE_TIER` and `LP_FEE_PROTOCOL_SHARE_BPS` with checked conversions. Keep LV_MON registration separate and do not silently apply the WETH V3 configuration to LV_MON. Add the checked fee-tier helper next to `_readUint16`:

```solidity
function _readUint24(string memory key) internal view returns (uint24 value) {
    uint256 rawValue = vm.envUint(key);
    require(rawValue <= type(uint24).max, "Deploy: uint24 env overflow");
    value = uint24(rawValue);
}
```

- [ ] **Step 5: Update the operational wrap script**

Change `WrapMon.s.sol` to read the deployed WETH address from the deployment artifact key selected for this repository, named `WETH_ADDRESS`, and rename local variables and logs from `wmon` to `weth`. This script may wrap native ETH but must never deploy another WETH.

- [ ] **Step 6: Verify quote and WETH deployment behavior**

Run:

```bash
forge fmt script/deploy/normal/Deploy.s.sol script/deploy/normal/WrapMon.s.sol test/integration/ProtocolWethQuote.t.sol
forge test --match-path test/integration/ProtocolWethQuote.t.sol -vv
forge build
rg -n 'envAddress\("WMON"\)|new WrappedEther' script/deploy/normal
```

Expected: focused tests pass; build passes; `new WrappedEther` occurs once in `Deploy.s.sol`; no deployment code reads `WMON`.

- [ ] **Step 7: Commit Task 2**

```bash
git add script/deploy/normal/Deploy.s.sol script/deploy/normal/WrapMon.s.sol test/integration/ProtocolWethQuote.t.sol
git commit -m "feat: configure deployed WETH as V3 quote"
```

---

### Task 3: Complete V3 creation and graduation wiring

**Files:**
- Modify: `src/core/BondingCurve.sol`
- Modify: `script/deploy/normal/Deploy.s.sol`
- Modify: `test/SetUp.t.sol`
- Create: `test/integration/WethV3GraduationE2E.t.sol`

**Interfaces:**
- Consumes: `IV3PoolDeployer.createPool(address,address)`, `ITokenRegistry.registerV3(address,address,address,uint24)`, and `ILPManager.allocate(AllocateParams)`.
- Produces: `BondingCurve.MODULE_V3_POOL_DEPLOYER`, V3-aware `_create`, V3-aware `_graduateV1`, and selector permissions for all three calls.

- [ ] **Step 1: Write the failing creation/graduation integration assertions**

Start `WethV3GraduationE2E.t.sol` from the repository `SetUp` fixture and add assertions for:

```solidity
assertEq(tokenRegistry.getQuoteToken(token), address(weth));
assertEq(uint256(tokenRegistry.getDexType(token)), uint256(ITokenRegistry.DexType.UniswapV3));
assertEq(tokenRegistry.getPool(token), factory.getPool(token, address(weth), V3_FEE_TIER));
assertTrue(IToken(token).isGraduated());
(bytes32 quoteKey,,, uint128 quoteLiquidity, bytes32 tokenKey,,, uint128 tokenLiquidity) =
    lpManager.getPositions(token);
assertNotEq(quoteKey, bytes32(0));
assertNotEq(tokenKey, bytes32(0));
assertGt(quoteLiquidity, 0);
assertGt(tokenLiquidity, 0);
```

- [ ] **Step 2: Run the lifecycle test and verify RED at missing V3 wiring**

Run:

```bash
forge test --match-path test/integration/WethV3GraduationE2E.t.sol -vv
```

Expected: fails because the default setup lacks `V3_POOL_DEPLOYER`, actor/factory wiring, or one of the three selector permissions.

- [ ] **Step 3: Finish and review the in-progress BondingCurve V3 branch**

Retain the V2 branch and use this exact V3 call structure:

```solidity
if (params.dexType == ITokenRegistry.DexType.UniswapV3) {
    address deployer = _modules[MODULE_V3_POOL_DEPLOYER];
    if (deployer == address(0)) revert ZeroModule();
    pair = IV3PoolDeployer(deployer).createPool(token, params.quoteToken);
    uint24 feeTier = _protocolManager.getConfig(params.quoteToken).v3FeeTier;
    ITokenRegistry(registry).registerV3(token, pair, params.quoteToken, feeTier);
} else {
    pair = _deployPairViaFactory(token, params.quoteToken);
    ITokenRegistry(registry).register(token, pair, params.quoteToken, params.dexType);
}
```

At graduation, call `allocate` only for V3 and retain `addLiquidity` only for legacy V2:

```solidity
ILPManager(lpManager).allocate(
    ILPManager.AllocateParams({
        token: token,
        quoteAmount: quoteBalanceAfterGraduateFee,
        tokenAmount: tokenForLiquidity,
        virtualQuoteReserve: curve.virtualQuoteReserve,
        virtualTokenReserve: curve.virtualTokenReserve,
        graduateFee: curve.graduateFee
    })
);
```

- [ ] **Step 4: Deploy and wire the V3 modules**

Extend `Deploy.Deployed` and deploy:

```solidity
address v3Factory;
address v3PoolDeployer;
address v3LiquidityActor;
address v3SwapAdapter;
address quoterV2;
address giwaRouter;
```

The canonical V3 factory and QuoterV2 addresses must be explicit deployment inputs appropriate for the target chain; `Deploy.s.sol` must validate both have code and that `IPeripheryImmutableState(quoterV2).factory() == v3Factory`. Deploy `V3PoolDeployer` behind `ERC1967Proxy`, deploy `V3LiquidityActor(d.lpManager, d.v3Factory)`, deploy `V3SwapAdapter(d.v3Factory, d.tokenRegistry)`, then call:

```solidity
LPManager(d.lpManager).setV3LiquidityActor(d.v3LiquidityActor, d.v3Factory);
BondingCurve(payable(d.bondingCurve)).setModule(keccak256("V3_POOL_DEPLOYER"), d.v3PoolDeployer);
```

- [ ] **Step 5: Install exact selector permissions and V3 adapter**

Add:

```solidity
pm.setOperatorPermission(d.bondingCurve, d.v3PoolDeployer, V3PoolDeployer.createPool.selector, true);
pm.setOperatorPermission(d.bondingCurve, d.tokenRegistry, TokenRegistry.registerV3.selector, true);
pm.setOperatorPermission(d.bondingCurve, d.lpManager, LPManager.allocate.selector, true);
```

Wire the deployed `V3SwapAdapter` into `GiwaRouter`; do not register it as the legacy `IDexAdapter`, because `GiwaRouter` calls the typed `IV3SwapAdapter` directly:

```solidity
d.v3SwapAdapter = address(new V3SwapAdapter(d.v3Factory, d.tokenRegistry));
d.giwaRouter = _deployProxy(
    address(new GiwaRouter()),
    abi.encodeCall(
        GiwaRouter.initialize,
        (d.protocolManager, d.bondingCurve, d.tokenRegistry, d.weth, d.v3SwapAdapter, d.quoterV2)
    )
);
```

The deployment admin also needs temporary permission to call `LPManager.setV3LiquidityActor`; revoke that permission after the one-time call or perform wiring while the deployment admin is the direct allowed operator.

- [ ] **Step 6: Mirror the real V3 wiring in `test/SetUp.t.sol`**

Deploy a real local `UniswapV3Factory`, compatible QuoterV2 test dependency, proxy-backed `V3PoolDeployer`, `V3LiquidityActor`, `V3SwapAdapter`, and proxy-backed `GiwaRouter`; register WETH's quote config; add the same three BondingCurve selector permissions; register `MODULE_V3_POOL_DEPLOYER`; keep legacy V2 fixtures only for tests that explicitly exercise them.

- [ ] **Step 7: Run focused and regression tests**

Run:

```bash
forge fmt src/core/BondingCurve.sol script/deploy/normal/Deploy.s.sol test/SetUp.t.sol test/integration/WethV3GraduationE2E.t.sol
forge test --match-path test/integration/WethV3GraduationE2E.t.sol -vv
forge test --match-path test/core/V3PoolDeployer.t.sol -q
forge test --match-path test/modules/LPManagerV3.t.sol -q
forge test --match-path test/modules/V3LiquidityActor.t.sol -q
forge build
```

Expected: all focused suites and build pass.

- [ ] **Step 8: Commit Task 3**

```bash
git add src/core/BondingCurve.sol script/deploy/normal/Deploy.s.sol test/SetUp.t.sol test/integration/WethV3GraduationE2E.t.sol
git commit -m "feat: wire V3 token graduation lifecycle"
```

---

### Task 4: Prove post-graduation buy and full-balance sell

**Files:**
- Modify: `test/integration/WethV3GraduationE2E.t.sol`
- Modify: `src/adapters/V3SwapAdapter.sol` only if the failing real-pool test demonstrates a concrete adapter defect.
- Modify: `src/router/GiwaRouter.sol` only if the failing real-pool test demonstrates a concrete V3 routing defect.

**Interfaces:**
- Consumes: `GiwaRouter.buy`, `GiwaRouter.sell`, TokenRegistry V3 metadata, `V3SwapAdapter.exactInput`, and WETH ERC20 operations.
- Produces: an end-to-end proof that a post-graduation holder can sell their full token balance without token dust.

- [ ] **Step 1: Add the post-graduation exact-input scenario**

After graduation, fund a fresh trader with WETH, perform a Router buy, then sell the entire received token balance:

```solidity
uint256 quoteIn = 1 ether;
vm.prank(trader);
weth.deposit{value: quoteIn}();
vm.prank(trader);
weth.approve(address(giwaRouter), quoteIn);

vm.prank(trader);
uint256 tokenOut = giwaRouter.buy(
    IGiwaRouter.BuyParams({
        amountIn: quoteIn,
        amountOutMin: 1,
        token: token,
        to: trader,
        deadline: block.timestamp
    })
);
assertGt(tokenOut, 0);

uint256 fullBalance = IERC20(token).balanceOf(trader);
vm.prank(trader);
IERC20(token).approve(address(giwaRouter), fullBalance);
uint256 quoteBefore = weth.balanceOf(trader);
vm.prank(trader);
uint256 quoteOut = giwaRouter.sell(
    IGiwaRouter.SellParams({
        amountIn: fullBalance,
        amountOutMin: 1,
        token: token,
        to: trader,
        deadline: block.timestamp
    })
);

assertGt(quoteOut, 0);
assertEq(IERC20(token).balanceOf(trader), 0, "seller token dust");
assertEq(weth.balanceOf(trader), quoteBefore + quoteOut);
```

- [ ] **Step 2: Add settlement and pool integrity assertions**

Snapshot pool, LPManager, actor, fee receiver, and trader balances. Assert:

- the canonical pool address remains unchanged;
- both protocol positions remain non-zero after swaps;
- LPManager holds no per-call token or quote remainder from graduation;
- the seller ends with exactly zero launch-token balance;
- quote output is delivered in the same deployed WETH;
- neither adapter nor Router retains token or WETH dust after the completed exact-input calls.

- [ ] **Step 3: Run the real-pool test and diagnose failures before editing production routing**

Run:

```bash
forge test --match-test test_wethV3_createGraduateBuyAndSellFullBalance --match-path test/integration/WethV3GraduationE2E.t.sol -vvvv
```

Expected: PASS. If it fails, use the trace to identify the first violated production boundary. Do not replace the real pool/actor with mocks and do not loosen amount or balance assertions.

- [ ] **Step 4: Add bounded fuzz coverage for full-balance selling**

Add a fuzz test that bounds `quoteIn` to a range that stays inside available V3 liquidity:

```solidity
function testFuzz_postGraduationFullBalanceSellLeavesNoDust(uint96 rawQuoteIn) public {
    uint256 quoteIn = bound(uint256(rawQuoteIn), 1e15, 5 ether);
    // use the same real graduated fixture, buy with quoteIn, sell the entire token balance
    assertEq(IERC20(token).balanceOf(trader), 0);
}
```

Run 256 fuzz cases:

```bash
forge test --match-test testFuzz_postGraduationFullBalanceSellLeavesNoDust --fuzz-runs 256 -vv
```

Expected: 256 runs pass with no seller token dust.

- [ ] **Step 5: Run final validation**

Run:

```bash
forge fmt --check
forge build
forge test --match-path test/token/WrappedEther.t.sol -vv
forge test --match-path test/integration/ProtocolWethQuote.t.sol -vv
forge test --match-path test/integration/WethV3GraduationE2E.t.sol --fuzz-runs 256 -vv
forge test --match-path test/modules/LPManagerV3.t.sol -q
forge test --match-path test/modules/V3LiquidityActor.t.sol -q
git diff --check
```

Expected: build and all focused tests pass. If repository-wide `forge fmt --check` fails in untouched baseline files, report the exact filenames and verify every touched file separately with `forge fmt --check <paths>`.

- [ ] **Step 6: Commit Task 4**

```bash
git add test/integration/WethV3GraduationE2E.t.sol src/adapters/V3SwapAdapter.sol src/router/GiwaRouter.sol
git commit -m "test: prove WETH V3 graduation and full sell"
```

---

### Task 5: Deployment verification and operator documentation

**Files:**
- Modify: `script/deploy/normal/Deploy.s.sol`
- Modify: the repository deployment environment example returned by `rg --files -g '*.example' -g '*.md' script docs | sort`
- Create: `docs/deployment/WETH_V3_DEPLOYMENT.md` if no single existing deployment guide owns these variables.

**Interfaces:**
- Consumes: the complete `Deploy.Deployed` struct and all deployed contract getters.
- Produces: deterministic post-deployment checks and an operator checklist containing no obsolete WMON input.

- [ ] **Step 1: Extend `_verify` with exact WETH/V3 invariants**

Add checks equivalent to:

```solidity
IProtocolManager.QuoteConfig memory config = ProtocolManager(d.protocolManager).getConfig(d.weth);
require(config.active, "Deploy: WETH quote inactive");
require(config.dexProtocolFeeRate == 0, "Deploy: WETH dex fee nonzero");
require(config.v3FeeTier == _readUint24("V3_FEE_TIER"), "Deploy: V3 fee tier mismatch");
require(
    config.lpFeeProtocolShareBps == _readUint16("LP_FEE_PROTOCOL_SHARE_BPS"),
    "Deploy: LP split mismatch"
);
require(GiwaRouter(payable(d.giwaRouter)).wrappedNative() == d.weth, "Deploy: Router WETH mismatch");
require(LPManager(d.lpManager).v3Factory() == d.v3Factory, "Deploy: LP factory mismatch");
require(LPManager(d.lpManager).v3LiquidityActor() == d.v3LiquidityActor, "Deploy: actor mismatch");
require(GiwaRouter(payable(d.giwaRouter)).v3SwapAdapter() == d.v3SwapAdapter, "Deploy: V3 adapter mismatch");
require(GiwaRouter(payable(d.giwaRouter)).quoterV2() == d.quoterV2, "Deploy: Quoter mismatch");
```

Also verify the three BondingCurve selector permissions with `ProtocolManager.canCall`.

- [ ] **Step 2: Update deployment logs and operator inputs**

Log `WETH`, V3 factory, pool deployer, actor, adapter, V3 fee tier, and LP protocol share. Remove `WMON` and nonzero `DEX_PROTOCOL_FEE_RATE` from the WETH deployment instructions. Document:

```text
V3_FACTORY=<canonical deployed factory>
V3_FEE_TIER=3000
LP_FEE_PROTOCOL_SHARE_BPS=5000
```

State that WETH is deployed by the script and therefore has no address input.

- [ ] **Step 3: Validate configuration drift checks**

Run:

```bash
rg -n 'WMON|WETH_ADDRESS|V3_FEE_TIER|LP_FEE_PROTOCOL_SHARE_BPS|DEX_PROTOCOL_FEE_RATE' script docs .env.example 2>/dev/null
forge build
git diff --check
```

Expected: no deployment path consumes `WMON`; `WETH_ADDRESS` appears only in post-deployment operational scripts; V3 fee tier and LP share are documented; WETH DEX protocol fee is hard-set to zero.

- [ ] **Step 4: Commit Task 5**

```bash
git add script/deploy/normal/Deploy.s.sol script/deploy/normal/WrapMon.s.sol docs/deployment
git commit -m "docs: finalize WETH V3 deployment checks"
```

## Plan Self-Review

- Spec coverage: WETH behavior, no privileged API, single deployment, quote configuration, downstream address reuse, V3 permissions, pool/actor/adapter wiring, graduation, post-graduation buy, full-balance sell, deployment verification, and operator documentation are assigned to Tasks 1–5.
- Scope boundary: LP fee collection and swap/distribution remain explicitly outside this plan; this plan only fixes their quote-token dependency.
- Type consistency: `WrappedEther`, `Deployed.weth`, `V3_FEE_TIER`, `LP_FEE_PROTOCOL_SHARE_BPS`, `MODULE_V3_POOL_DEPLOYER`, `registerV3`, `allocate`, and V3 actor/factory names are consistent across tasks.
- Every production edit is specified; Router or adapter changes are permitted only when a real-pool trace first proves a concrete defect.
