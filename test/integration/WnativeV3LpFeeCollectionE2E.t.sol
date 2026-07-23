// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {MockWrappedNative} from "../mocks/MockWrappedNative.sol";

import {Deploy, GIWA_WNATIVE} from "../../script/deploy/normal/Deploy.s.sol";
import {V3LiquidityActor} from "../../src/actors/V3LiquidityActor.sol";
import {BondingCurve} from "../../src/core/BondingCurve.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IYachaRouter} from "../../src/interfaces/IYachaRouter.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {YachaRouter} from "../../src/router/YachaRouter.sol";
import {Token} from "../../src/token/Token.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";

contract WnativeV3LpFeeCollectionDeployHarness is Deploy {
    function deployCanonicalFixture(address v3Factory, address feeReceiver, address collector)
        external
        returns (Deployed memory d)
    {
        d.v3Factory = v3Factory;
        (d.wnative, d.protocolManager) =
            _deployCanonicalWnativeAndProtocolManager(address(this), feeReceiver, _testConfig());
        d.tokenRegistry = _deployTokenRegistry(d.protocolManager);
        d.creatorFeeProcessor = _deployCreatorFeeProcessor(d.protocolManager);
        d.v3SwapAdapter = _deployV3SwapAdapter(d.v3Factory, d.tokenRegistry);
        d.lpManager = _deployLPManager(d.protocolManager, d.tokenRegistry, d.creatorFeeProcessor, d.v3SwapAdapter);
        d.v3PoolDeployer = _deployV3PoolDeployer(d.protocolManager, d.v3Factory);
        d.v3LiquidityActor = address(new V3LiquidityActor(d.lpManager, d.v3Factory));
        LPManager(d.lpManager).setV3LiquidityActor(d.v3LiquidityActor, d.v3Factory);
        d.tokenImpl = address(new Token());
        d.bondingCurve = _deployBondingCurve(address(this), d.tokenImpl, d.protocolManager);
        (d.quoterV2, d.yachaRouter) = _deployV3Routing(
            d.protocolManager, d.bondingCurve, d.tokenRegistry, d.wnative, d.v3SwapAdapter, d.v3Factory
        );
        d.vaultRegistry = _deployVaultRegistry(d.protocolManager);
        _deployVaults(d, "ipfs://creator-fee-vault");
        _registerModules(d);
        _setPermissions(d, address(0), collector);

        BondingCurve bondingCurve = BondingCurve(payable(d.bondingCurve));
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), d.yachaRouter);
    }

    function updateFeeReceiver(address protocolManager, address feeReceiver) external {
        ProtocolManager(protocolManager).setFeeReceiver(feeReceiver);
    }

    function _testConfig() private pure returns (ProtocolDeploymentConfig memory config) {
        config.quoteToken = QuoteTokenConfig({
            virtualReserve: 70_000 ether,
            virtualTokenReserve: 1_060_569_000 ether,
            minTokenReserve: 251_660_440_677_966_101_694_915_255,
            deployFee: 10 ether,
            graduateFee: 1_000 ether,
            curveProtocolFeeRate: 100,
            v3FeeTier: 3_000,
            lpFeeProtocolShareBps: 5_000
        });
        config.snipingPenaltyTable = new uint256[](1);
    }
}

contract WnativeV3LpFeeCollectionE2ETest is Test {
    uint256 private constant GRADUATION_QUOTE_IN = 800_000 ether;
    uint256 private constant POST_GRADUATION_QUOTE_IN = 100 ether;
    bytes32 private constant COLLECT_TOPIC = keccak256("Collect(address,address,uint256,uint256,uint256)");

    struct CollectedFees {
        uint256 tokenFee;
        uint256 directQuoteFee;
        uint256 timestamp;
    }

    struct CollectionSnapshot {
        bytes32 positions;
        uint256 oldReceiverQuote;
        uint256 newReceiverQuote;
        uint256 vaultQuote;
        uint256 creatorCredit;
    }

    Deploy.Deployed private deployed;
    WnativeV3LpFeeCollectionDeployHarness private harness;
    MockWrappedNative private wnative;
    YachaRouter private yachaRouter;
    BondingCurve private bondingCurve;
    TokenRegistry private tokenRegistry;
    LPManager private lpManager;
    V3LiquidityActor private liquidityActor;
    CreatorFeeVault private creatorFeeVault;

    address private creator;
    address private graduator;
    address private trader;
    address private feeReceiverAtAccrual;
    address private feeReceiverAtCollection;

    function setUp() public {
        vm.etch(GIWA_WNATIVE, type(MockWrappedNative).runtimeCode);

        creator = makeAddr("creator");
        graduator = makeAddr("graduator");
        trader = makeAddr("postGraduationTrader");
        feeReceiverAtAccrual = makeAddr("feeReceiverAtAccrual");
        feeReceiverAtCollection = makeAddr("feeReceiverAtCollection");

        harness = new WnativeV3LpFeeCollectionDeployHarness();
        deployed = harness.deployCanonicalFixture(address(new UniswapV3Factory()), feeReceiverAtAccrual, address(this));
        wnative = MockWrappedNative(payable(deployed.wnative));
        yachaRouter = YachaRouter(payable(deployed.yachaRouter));
        bondingCurve = BondingCurve(payable(deployed.bondingCurve));
        tokenRegistry = TokenRegistry(deployed.tokenRegistry);
        lpManager = LPManager(deployed.lpManager);
        liquidityActor = V3LiquidityActor(deployed.v3LiquidityActor);
        creatorFeeVault = CreatorFeeVault(payable(deployed.creatorFeeVault));
    }

    function test_collectsAndDistributesRealV3Fees_whenLaunchTokenIsToken0() public {
        _runLifecycle(true);
    }

    function test_collectsAndDistributesRealV3Fees_whenQuoteTokenIsToken0() public {
        _runLifecycle(false);
    }

    function _runLifecycle(bool launchTokenIsToken0) private {
        address token = _createToken(launchTokenIsToken0);
        _graduate(token);
        address pool = tokenRegistry.getPool(token);

        assertEq(token < deployed.wnative, launchTokenIsToken0, "deterministic token ordering");
        _assertGraduationSupplyAccounted(token, pool);
        _roundTripFullBalance(token);

        (uint256 fee0, uint256 fee1) = liquidityActor.viewFees(pool);
        uint256 pendingTokenFee = launchTokenIsToken0 ? fee0 : fee1;
        uint256 pendingQuoteFee = launchTokenIsToken0 ? fee1 : fee0;
        assertGt(pendingTokenFee, 0, "real launch-token fee did not accrue");
        assertGt(pendingQuoteFee, 0, "real quote fee did not accrue");

        _collectAndAssert(token, pendingTokenFee, pendingQuoteFee);
    }

    function _collectAndAssert(address token, uint256 pendingTokenFee, uint256 pendingQuoteFee) private {
        CollectionSnapshot memory snapshot = CollectionSnapshot({
            positions: _positionHash(token),
            oldReceiverQuote: wnative.balanceOf(feeReceiverAtAccrual),
            newReceiverQuote: wnative.balanceOf(feeReceiverAtCollection),
            vaultQuote: wnative.balanceOf(deployed.creatorFeeVault),
            creatorCredit: creatorFeeVault.getBalance(token)
        });

        harness.updateFeeReceiver(deployed.protocolManager, feeReceiverAtCollection);
        assertEq(IProtocolManager(deployed.protocolManager).feeReceiver(), feeReceiverAtCollection);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        vm.recordLogs();
        lpManager.collect(tokens);
        CollectedFees memory fees = _decodeCollection(vm.getRecordedLogs(), token);

        assertEq(wnative.balanceOf(feeReceiverAtAccrual), snapshot.oldReceiverQuote, "stale fee receiver paid");
        uint256 receiverQuoteDelta = wnative.balanceOf(feeReceiverAtCollection) - snapshot.newReceiverQuote;
        uint256 vaultQuoteDelta = wnative.balanceOf(deployed.creatorFeeVault) - snapshot.vaultQuote;
        uint256 creatorCreditDelta = creatorFeeVault.getBalance(token) - snapshot.creatorCredit;
        uint256 actualDistributedQuote = receiverQuoteDelta + vaultQuoteDelta;
        assertGe(actualDistributedQuote, pendingQuoteFee, "distribution omitted independently observed quote fee");
        uint256 actualSwappedQuote = actualDistributedQuote - pendingQuoteFee;
        uint256 expectedProtocolQuote = actualDistributedQuote * 5_000 / 10_000;
        uint256 expectedCreatorQuote = actualDistributedQuote - expectedProtocolQuote;

        assertEq(fees.tokenFee, pendingTokenFee, "event token fee differs from pre-collection oracle");
        assertEq(fees.directQuoteFee, pendingQuoteFee, "event quote fee differs from pre-collection oracle");
        assertEq(fees.timestamp, block.timestamp, "event collection timestamp");
        assertEq(receiverQuoteDelta, expectedProtocolQuote, "protocol ratio from independent deltas");
        assertEq(vaultQuoteDelta, expectedCreatorQuote, "creator ratio from independent deltas");
        assertEq(creatorCreditDelta, vaultQuoteDelta, "creator vault accounting differs from vault receipt");
        assertGt(actualSwappedQuote, 0, "launch-token fees were not swapped to quote");

        assertEq(_positionHash(token), snapshot.positions, "fee collection changed LP principal");
        _assertNoCallResidue(token);
    }

    function _createToken(bool launchTokenIsToken0) private returns (address token) {
        bytes32 salt = _saltForOrdering(launchTokenIsToken0);
        uint256 deployFee = IProtocolManager(deployed.protocolManager).deployFee(deployed.wnative);
        _fundWnative(creator, deployFee);
        vm.prank(creator);
        wnative.approve(deployed.yachaRouter, deployFee);

        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: deployed.creatorFeeVault, bps: 10_000, setupData: abi.encode(creator)
        });

        vm.prank(creator);
        (token,) = yachaRouter.create(
            IYachaRouter.CreateParams({
                name: "Canonical WNATIVE LP Fee",
                symbol: "CWLP",
                tokenURI: "",
                quoteToken: deployed.wnative,
                vaults: vaults,
                salt: salt,
                dexType: ITokenRegistry.DexType.UniswapV3,
                buyQuoteAmount: 0,
                deadline: block.timestamp
            })
        );
    }

    function _saltForOrdering(bool launchTokenIsToken0) private view returns (bytes32 salt) {
        for (uint256 nonce; nonce < 256; ++nonce) {
            salt = keccak256(abi.encode("wnative-v3-lp-fee-e2e", launchTokenIsToken0, nonce));
            address predicted = Clones.predictDeterministicAddress(deployed.tokenImpl, salt, deployed.bondingCurve);
            if ((predicted < deployed.wnative) == launchTokenIsToken0) return salt;
        }
        revert("ordering salt not found");
    }

    function _graduate(address token) private {
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 100 minutes);
        _fundWnative(graduator, GRADUATION_QUOTE_IN);
        vm.prank(graduator);
        wnative.approve(deployed.yachaRouter, GRADUATION_QUOTE_IN);
        vm.prank(graduator);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: GRADUATION_QUOTE_IN, amountOutMin: 1, token: token, to: graduator, deadline: block.timestamp
            })
        );
        assertTrue(bondingCurve.getCurve(token).graduated, "curve not graduated");
    }

    function _roundTripFullBalance(address token) private {
        _fundWnative(trader, POST_GRADUATION_QUOTE_IN);
        vm.prank(trader);
        wnative.approve(deployed.yachaRouter, POST_GRADUATION_QUOTE_IN);
        vm.prank(trader);
        uint256 tokenOut = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: POST_GRADUATION_QUOTE_IN, amountOutMin: 1, token: token, to: trader, deadline: block.timestamp
            })
        );
        assertGt(tokenOut, 0, "post-graduation buy output");

        uint256 fullBalance = IERC20(token).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(token).approve(deployed.yachaRouter, fullBalance);
        uint256 quoteOut = yachaRouter.sell(
            IYachaRouter.SellParams({
                amountIn: fullBalance, amountOutMin: 1, token: token, to: trader, deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertGt(quoteOut, 0, "post-graduation sell output");
        assertEq(IERC20(token).balanceOf(trader), 0, "full-balance seller dust");
    }

    function _assertGraduationSupplyAccounted(address token, address pool) private view {
        uint256 accounted = IERC20(token).balanceOf(graduator) + IERC20(token).balanceOf(feeReceiverAtAccrual)
            + IERC20(token).balanceOf(creator) + IERC20(token).balanceOf(pool)
            + IERC20(token).balanceOf(deployed.bondingCurve) + IERC20(token).balanceOf(deployed.lpManager)
            + IERC20(token).balanceOf(deployed.v3LiquidityActor) + IERC20(token).balanceOf(deployed.yachaRouter)
            + IERC20(token).balanceOf(deployed.v3SwapAdapter);
        assertEq(accounted, IERC20(token).totalSupply(), "graduation launch-token supply accounting");
    }

    function _assertNoCallResidue(address token) private view {
        assertEq(IERC20(token).balanceOf(deployed.lpManager), 0, "LPManager token residue");
        assertEq(wnative.balanceOf(deployed.lpManager), 0, "LPManager quote residue");
        assertEq(IERC20(token).balanceOf(deployed.creatorFeeProcessor), 0, "processor token residue");
        assertEq(wnative.balanceOf(deployed.creatorFeeProcessor), 0, "processor quote residue");
        assertEq(IERC20(token).balanceOf(deployed.v3LiquidityActor), 0, "actor token residue");
        assertEq(wnative.balanceOf(deployed.v3LiquidityActor), 0, "actor quote residue");
        assertEq(IERC20(token).balanceOf(deployed.v3SwapAdapter), 0, "adapter token residue");
        assertEq(wnative.balanceOf(deployed.v3SwapAdapter), 0, "adapter quote residue");
        assertEq(IERC20(token).allowance(deployed.lpManager, deployed.v3SwapAdapter), 0, "adapter token allowance");
        assertEq(wnative.allowance(deployed.lpManager, deployed.creatorFeeProcessor), 0, "processor quote allowance");
        assertEq(IERC20(token).allowance(deployed.lpManager, deployed.v3LiquidityActor), 0, "actor token allowance");
        assertEq(wnative.allowance(deployed.lpManager, deployed.v3LiquidityActor), 0, "actor quote allowance");
    }

    function _decodeCollection(Vm.Log[] memory logs, address token) private view returns (CollectedFees memory fees) {
        address pool = tokenRegistry.getPool(token);
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == deployed.lpManager && logs[i].topics.length == 3
                    && logs[i].topics[0] == COLLECT_TOPIC && address(uint160(uint256(logs[i].topics[1]))) == token
                    && address(uint160(uint256(logs[i].topics[2]))) == pool
            ) {
                (fees.directQuoteFee, fees.tokenFee, fees.timestamp) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                return fees;
            }
        }
        revert("Collect missing");
    }

    function _positionHash(address token) private view returns (bytes32) {
        (
            bytes32 quoteKey,
            int24 quoteLower,
            int24 quoteUpper,
            uint128 quoteLiquidity,
            bytes32 tokenKey,
            int24 tokenLower,
            int24 tokenUpper,
            uint128 tokenLiquidity
        ) = lpManager.getPositions(token);
        address pool = tokenRegistry.getPool(token);
        bytes32 recomputedQuoteKey = keccak256(abi.encodePacked(address(liquidityActor), quoteLower, quoteUpper));
        bytes32 recomputedTokenKey = keccak256(abi.encodePacked(address(liquidityActor), tokenLower, tokenUpper));
        assertEq(quoteKey, recomputedQuoteKey, "actor returned unexpected quote position key");
        assertEq(tokenKey, recomputedTokenKey, "actor returned unexpected token position key");
        (uint128 liveQuoteLiquidity,,,,) = IUniswapV3Pool(pool).positions(recomputedQuoteKey);
        (uint128 liveTokenLiquidity,,,,) = IUniswapV3Pool(pool).positions(recomputedTokenKey);
        assertEq(liveQuoteLiquidity, quoteLiquidity, "cached quote liquidity differs from canonical pool");
        assertEq(liveTokenLiquidity, tokenLiquidity, "cached token liquidity differs from canonical pool");
        return keccak256(
            abi.encode(
                quoteKey,
                quoteLower,
                quoteUpper,
                quoteLiquidity,
                recomputedQuoteKey,
                liveQuoteLiquidity,
                tokenKey,
                tokenLower,
                tokenUpper,
                tokenLiquidity,
                recomputedTokenKey,
                liveTokenLiquidity
            )
        );
    }

    function _fundWnative(address account, uint256 amount) private {
        vm.deal(account, amount);
        vm.prank(account);
        wnative.deposit{value: amount}();
    }
}
