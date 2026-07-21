// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {WETH} from "solady/tokens/WETH.sol";

import {Deploy, GIWA_WETH} from "../../script/deploy/normal/Deploy.s.sol";
import {V3LiquidityActor} from "../../src/actors/V3LiquidityActor.sol";
import {BondingCurve} from "../../src/core/BondingCurve.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {Token} from "../../src/token/Token.sol";

contract WethV3GraduationDeployHarness is Deploy {
    function deployCanonicalFixture(address v3Factory, address feeReceiver) external returns (Deployed memory d) {
        d.v3Factory = v3Factory;
        (d.weth, d.protocolManager) = _deployCanonicalWethAndProtocolManager(address(this), feeReceiver, _testConfig());
        d.tokenImpl = address(new Token());
        d.tokenRegistry = _deployTokenRegistry(d.protocolManager);
        d.lpManager = _deployLPManager(d.protocolManager, d.tokenRegistry);
        d.v3PoolDeployer = _deployV3PoolDeployer(d.protocolManager, d.v3Factory);
        d.v3LiquidityActor = address(new V3LiquidityActor(d.lpManager, d.v3Factory));
        LPManager(d.lpManager).setV3LiquidityActor(d.v3LiquidityActor, d.v3Factory);
        d.bondingCurve = _deployBondingCurve(address(this), d.tokenImpl, d.protocolManager);
        (d.v3SwapAdapter, d.quoterV2, d.giwaRouter) =
            _deployV3Routing(d.protocolManager, d.bondingCurve, d.tokenRegistry, d.weth, d.v3Factory);

        uint64 nonce = vm.getNonce(address(this));
        address predictedFeeCollector = vm.computeCreateAddress(address(this), nonce + 2);
        d.creatorFeeProcessor = _deployCreatorFeeProcessor(d.bondingCurve, predictedFeeCollector);
        d.feeCollector = _deployFeeCollector(d.protocolManager, d.creatorFeeProcessor, d.bondingCurve, d.giwaRouter);
        require(d.feeCollector == predictedFeeCollector, "fee collector prediction");

        d.vaultRegistry = _deployVaultRegistry(d.protocolManager);
        _deployVaults(d, "ipfs://creator-fee-vault");
        _registerModules(d);
        _setPermissions(d, address(0), address(0));

        BondingCurve bondingCurve = BondingCurve(payable(d.bondingCurve));
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), d.giwaRouter);
    }

    function _testConfig() private pure returns (ProtocolDeploymentConfig memory config) {
        config.quoteToken = QuoteTokenConfig({
            virtualReserve: 70_000 ether,
            virtualTokenReserve: 1_060_569_000 ether,
            minTokenReserve: 251_660_440_677_966_101_694_915_255,
            deployFee: 10 ether,
            graduateFee: 1_000 ether,
            curveProtocolFeeRate: 100,
            settlementThreshold: 1_000 ether,
            v3FeeTier: 3_000,
            lpFeeProtocolShareBps: 5_000
        });
        config.snipingPenaltyTable = new uint256[](1);
        config.creatorFeeRates = new uint16[](1);
        config.creatorFeeRates[0] = 100;
    }
}

contract WethV3GraduationE2ETest is Test {
    uint256 private constant GRADUATION_QUOTE_IN = 800_000 ether;

    struct SettlementSnapshot {
        uint128 quoteLiquidity;
        uint128 tokenLiquidity;
        uint256 poolToken;
        uint256 poolWeth;
        uint256 lpToken;
        uint256 lpWeth;
        uint256 actorToken;
        uint256 actorWeth;
        uint256 feeReceiverToken;
        uint256 feeReceiverWeth;
        uint256 routerToken;
        uint256 routerWeth;
        uint256 adapterToken;
        uint256 adapterWeth;
    }

    Deploy.Deployed private deployed;
    UniswapV3Factory private v3Factory;
    WETH private weth;
    GiwaRouter private giwaRouter;
    BondingCurve private bondingCurve;
    TokenRegistry private tokenRegistry;
    LPManager private lpManager;

    address private creator;
    address private graduator;
    address private trader;
    address private feeReceiver;
    address private token;
    address private pool;

    function setUp() public {
        vm.etch(GIWA_WETH, type(WETH).runtimeCode);

        creator = makeAddr("creator");
        graduator = makeAddr("graduator");
        trader = makeAddr("postGraduationTrader");
        feeReceiver = makeAddr("feeReceiver");

        v3Factory = new UniswapV3Factory();
        WethV3GraduationDeployHarness harness = new WethV3GraduationDeployHarness();
        deployed = harness.deployCanonicalFixture(address(v3Factory), feeReceiver);

        weth = WETH(payable(deployed.weth));
        giwaRouter = GiwaRouter(payable(deployed.giwaRouter));
        bondingCurve = BondingCurve(payable(deployed.bondingCurve));
        tokenRegistry = TokenRegistry(deployed.tokenRegistry);
        lpManager = LPManager(deployed.lpManager);

        token = _createToken();
        _graduateToken();
        pool = tokenRegistry.getPool(token);

        assertEq(deployed.weth, GIWA_WETH, "canonical WETH");
        assertEq(giwaRouter.wrappedNative(), GIWA_WETH, "router WETH");
        assertEq(tokenRegistry.getQuoteToken(token), GIWA_WETH, "registry WETH");
        assertEq(CreatorFeeProcessor(deployed.creatorFeeProcessor).vaultCount(token), 1, "CreatorFeeVault only");
        assertEq(IERC20(token).balanceOf(deployed.lpManager), 0, "graduation token remainder");
        assertEq(weth.balanceOf(deployed.lpManager), 0, "graduation WETH remainder");
    }

    function test_wethV3_createGraduateBuyAndSellFullBalance() public {
        _buyAndSellFullBalance(1 ether);
    }

    function testFuzz_postGraduationFullBalanceSellLeavesNoDust(uint96 rawQuoteIn) public {
        uint256 quoteIn = bound(uint256(rawQuoteIn), 1e15, 5 ether);
        _buyAndSellFullBalance(quoteIn);
    }

    function _buyAndSellFullBalance(uint256 quoteIn) private {
        SettlementSnapshot memory beforeSwap = _snapshotSettlement();

        _fundWeth(trader, quoteIn);
        assertEq(IERC20(token).balanceOf(trader), 0, "fresh trader token balance");
        assertEq(weth.balanceOf(trader), quoteIn, "funded trader WETH balance");
        vm.prank(trader);
        weth.approve(deployed.giwaRouter, quoteIn);

        vm.prank(trader);
        uint256 tokenOut = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: quoteIn, amountOutMin: 1, token: token, to: trader, deadline: block.timestamp
            })
        );
        assertGt(tokenOut, 0, "post-graduation token output");

        uint256 fullBalance = IERC20(token).balanceOf(trader);
        assertEq(fullBalance, tokenOut, "buyer token balance");
        vm.prank(trader);
        IERC20(token).approve(deployed.giwaRouter, fullBalance);

        uint256 quoteBefore = weth.balanceOf(trader);
        vm.prank(trader);
        uint256 quoteOut = giwaRouter.sell(
            IGiwaRouter.SellParams({
                amountIn: fullBalance, amountOutMin: 1, token: token, to: trader, deadline: block.timestamp
            })
        );

        assertGt(quoteOut, 0, "post-graduation WETH output");
        assertEq(IERC20(token).balanceOf(trader), 0, "seller token dust");
        assertEq(weth.balanceOf(trader), quoteBefore + quoteOut, "same deployed WETH output");

        _assertSettlement(beforeSwap);
    }

    function _assertSettlement(SettlementSnapshot memory beforeSwap) private view {
        ITokenRegistry.TokenInfo memory infoAfter = tokenRegistry.getTokenInfo(token);
        assertEq(infoAfter.pool, pool, "registry pool changed");
        assertEq(infoAfter.quoteToken, deployed.weth, "quote token changed");
        assertEq(v3Factory.getPool(token, deployed.weth, infoAfter.feeTier), pool, "factory pool changed");

        (uint128 quoteLiquidityAfter, uint128 tokenLiquidityAfter) = _positionLiquidities();
        assertGt(quoteLiquidityAfter, 0, "quote position liquidity");
        assertGt(tokenLiquidityAfter, 0, "token position liquidity");
        assertEq(quoteLiquidityAfter, beforeSwap.quoteLiquidity, "quote position changed");
        assertEq(tokenLiquidityAfter, beforeSwap.tokenLiquidity, "token position changed");

        assertEq(IERC20(token).balanceOf(pool), beforeSwap.poolToken, "pool token round trip");
        assertGt(weth.balanceOf(pool), beforeSwap.poolWeth, "pool WETH fees");
        assertEq(beforeSwap.lpToken, 0, "LPManager token before swap");
        assertEq(beforeSwap.lpWeth, 0, "LPManager WETH before swap");
        assertEq(IERC20(token).balanceOf(deployed.lpManager), 0, "LPManager token dust");
        assertEq(weth.balanceOf(deployed.lpManager), 0, "LPManager WETH dust");
        assertEq(beforeSwap.actorToken, 0, "actor token before swap");
        assertEq(beforeSwap.actorWeth, 0, "actor WETH before swap");
        assertEq(IERC20(token).balanceOf(deployed.v3LiquidityActor), 0, "actor token dust");
        assertEq(weth.balanceOf(deployed.v3LiquidityActor), 0, "actor WETH dust");
        assertEq(IERC20(token).balanceOf(feeReceiver), beforeSwap.feeReceiverToken, "fee receiver token delta");
        assertEq(weth.balanceOf(feeReceiver), beforeSwap.feeReceiverWeth, "fee receiver WETH delta");
        assertEq(beforeSwap.routerToken, 0, "router token before swap");
        assertEq(beforeSwap.routerWeth, 0, "router WETH before swap");
        assertEq(IERC20(token).balanceOf(deployed.giwaRouter), 0, "router token dust");
        assertEq(weth.balanceOf(deployed.giwaRouter), 0, "router WETH dust");
        assertEq(beforeSwap.adapterToken, 0, "adapter token before swap");
        assertEq(beforeSwap.adapterWeth, 0, "adapter WETH before swap");
        assertEq(IERC20(token).balanceOf(deployed.v3SwapAdapter), 0, "adapter token dust");
        assertEq(weth.balanceOf(deployed.v3SwapAdapter), 0, "adapter WETH dust");
        assertEq(IERC20(token).allowance(deployed.giwaRouter, deployed.v3SwapAdapter), 0, "router token allowance dust");
        assertEq(weth.allowance(deployed.giwaRouter, deployed.v3SwapAdapter), 0, "router WETH allowance dust");
    }

    function _snapshotSettlement() private view returns (SettlementSnapshot memory snapshot) {
        (snapshot.quoteLiquidity, snapshot.tokenLiquidity) = _positionLiquidities();
        snapshot.poolToken = IERC20(token).balanceOf(pool);
        snapshot.poolWeth = weth.balanceOf(pool);
        snapshot.lpToken = IERC20(token).balanceOf(deployed.lpManager);
        snapshot.lpWeth = weth.balanceOf(deployed.lpManager);
        snapshot.actorToken = IERC20(token).balanceOf(deployed.v3LiquidityActor);
        snapshot.actorWeth = weth.balanceOf(deployed.v3LiquidityActor);
        snapshot.feeReceiverToken = IERC20(token).balanceOf(feeReceiver);
        snapshot.feeReceiverWeth = weth.balanceOf(feeReceiver);
        snapshot.routerToken = IERC20(token).balanceOf(deployed.giwaRouter);
        snapshot.routerWeth = weth.balanceOf(deployed.giwaRouter);
        snapshot.adapterToken = IERC20(token).balanceOf(deployed.v3SwapAdapter);
        snapshot.adapterWeth = weth.balanceOf(deployed.v3SwapAdapter);
    }

    function _createToken() private returns (address createdToken) {
        uint256 deployFee = IProtocolManager(deployed.protocolManager).deployFee(deployed.weth);
        _fundWeth(creator, deployFee);
        vm.prank(creator);
        weth.approve(deployed.giwaRouter, deployFee);

        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: deployed.creatorFeeVault, bps: 10_000, setupData: abi.encode(creator)
        });

        vm.prank(creator);
        (createdToken,) = giwaRouter.create(
            IGiwaRouter.CreateParams({
                name: "Canonical WETH Launch",
                symbol: "CWETH",
                tokenURI: "",
                quoteToken: deployed.weth,
                creatorFeeRate: 100,
                vaults: vaults,
                salt: keccak256("canonical-weth-graduation-e2e"),
                dexType: ITokenRegistry.DexType.UniswapV3,
                buyQuoteAmount: 0,
                deadline: block.timestamp
            })
        );
    }

    function _graduateToken() private {
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 100 minutes);
        _fundWeth(graduator, GRADUATION_QUOTE_IN);
        vm.prank(graduator);
        weth.approve(deployed.giwaRouter, GRADUATION_QUOTE_IN);

        vm.prank(graduator);
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: GRADUATION_QUOTE_IN, amountOutMin: 1, token: token, to: graduator, deadline: block.timestamp
            })
        );

        assertTrue(bondingCurve.getCurve(token).graduated, "curve not graduated");
    }

    function _fundWeth(address account, uint256 amount) private {
        vm.deal(account, amount);
        vm.prank(account);
        weth.deposit{value: amount}();
    }

    function _positionLiquidities() private view returns (uint128 quoteLiquidity, uint128 tokenLiquidity) {
        (,,, quoteLiquidity,,,, tokenLiquidity) = lpManager.getPositions(token);
    }
}
