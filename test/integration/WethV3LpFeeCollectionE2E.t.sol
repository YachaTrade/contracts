// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {WETH} from "solady/tokens/WETH.sol";

import {Deploy, GIWA_WETH} from "../../script/deploy/normal/Deploy.s.sol";
import {V3LiquidityActor} from "../../src/actors/V3LiquidityActor.sol";
import {BondingCurve} from "../../src/core/BondingCurve.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {Token} from "../../src/token/Token.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";

contract WethV3LpFeeCollectionDeployHarness is Deploy {
    function deployCanonicalFixture(address v3Factory, address feeReceiver, address collector)
        external
        returns (Deployed memory d)
    {
        d.v3Factory = v3Factory;
        (d.weth, d.protocolManager) = _deployCanonicalWethAndProtocolManager(address(this), feeReceiver, _testConfig());
        d.tokenRegistry = _deployTokenRegistry(d.protocolManager);
        d.creatorFeeProcessor = _deployCreatorFeeProcessor(d.protocolManager);
        d.v3SwapAdapter = _deployV3SwapAdapter(d.v3Factory, d.tokenRegistry);
        d.lpManager = _deployLPManager(d.protocolManager, d.tokenRegistry, d.creatorFeeProcessor, d.v3SwapAdapter);
        d.v3PoolDeployer = _deployV3PoolDeployer(d.protocolManager, d.v3Factory);
        d.v3LiquidityActor = address(new V3LiquidityActor(d.lpManager, d.v3Factory));
        LPManager(d.lpManager).setV3LiquidityActor(d.v3LiquidityActor, d.v3Factory);
        d.tokenImpl = address(new Token());
        d.bondingCurve = _deployBondingCurve(address(this), d.tokenImpl, d.protocolManager);
        (d.quoterV2, d.giwaRouter) =
            _deployV3Routing(d.protocolManager, d.bondingCurve, d.tokenRegistry, d.weth, d.v3SwapAdapter, d.v3Factory);
        d.vaultRegistry = _deployVaultRegistry(d.protocolManager);
        _deployVaults(d, "ipfs://creator-fee-vault");
        _registerModules(d);
        _setPermissions(d, address(0), collector);

        BondingCurve bondingCurve = BondingCurve(payable(d.bondingCurve));
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), d.giwaRouter);
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

contract WethV3LpFeeCollectionE2ETest is Test {
    uint256 private constant GRADUATION_QUOTE_IN = 800_000 ether;
    uint256 private constant POST_GRADUATION_QUOTE_IN = 100 ether;
    bytes32 private constant FEES_COLLECTED_TOPIC =
        keccak256("V3FeesCollected(address,address,uint256,uint256,uint256,uint256,uint256)");

    struct CollectedFees {
        uint256 tokenFee;
        uint256 directQuoteFee;
        uint256 swappedQuote;
        uint256 protocolQuote;
        uint256 creatorQuote;
    }

    struct CollectionSnapshot {
        bytes32 positions;
        uint256 oldReceiverQuote;
        uint256 newReceiverQuote;
        uint256 vaultQuote;
        uint256 creatorCredit;
    }

    Deploy.Deployed private deployed;
    WethV3LpFeeCollectionDeployHarness private harness;
    WETH private weth;
    GiwaRouter private giwaRouter;
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
        vm.etch(GIWA_WETH, type(WETH).runtimeCode);

        creator = makeAddr("creator");
        graduator = makeAddr("graduator");
        trader = makeAddr("postGraduationTrader");
        feeReceiverAtAccrual = makeAddr("feeReceiverAtAccrual");
        feeReceiverAtCollection = makeAddr("feeReceiverAtCollection");

        harness = new WethV3LpFeeCollectionDeployHarness();
        deployed = harness.deployCanonicalFixture(address(new UniswapV3Factory()), feeReceiverAtAccrual, address(this));
        weth = WETH(payable(deployed.weth));
        giwaRouter = GiwaRouter(payable(deployed.giwaRouter));
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

        assertEq(token < deployed.weth, launchTokenIsToken0, "deterministic token ordering");
        _assertGraduationSupplyAccounted(token, pool);
        _roundTripFullBalance(token);

        (uint256 fee0, uint256 fee1) = liquidityActor.viewFees(pool);
        uint256 pendingTokenFee = launchTokenIsToken0 ? fee0 : fee1;
        uint256 pendingQuoteFee = launchTokenIsToken0 ? fee1 : fee0;
        assertGt(pendingTokenFee, 0, "real launch-token fee did not accrue");
        assertGt(pendingQuoteFee, 0, "real quote fee did not accrue");

        _collectAndAssert(token);
    }

    function _collectAndAssert(address token) private {
        CollectionSnapshot memory snapshot = CollectionSnapshot({
            positions: _positionHash(token),
            oldReceiverQuote: weth.balanceOf(feeReceiverAtAccrual),
            newReceiverQuote: weth.balanceOf(feeReceiverAtCollection),
            vaultQuote: weth.balanceOf(deployed.creatorFeeVault),
            creatorCredit: creatorFeeVault.getBalance(token)
        });

        harness.updateFeeReceiver(deployed.protocolManager, feeReceiverAtCollection);
        assertEq(IProtocolManager(deployed.protocolManager).feeReceiver(), feeReceiverAtCollection);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        vm.recordLogs();
        lpManager.collect(tokens);
        CollectedFees memory fees = _decodeCollection(vm.getRecordedLogs(), token);

        assertGt(fees.tokenFee, 0, "collection omitted launch-token fees");
        assertGt(fees.directQuoteFee, 0, "collection omitted direct quote fees");
        assertGt(fees.swappedQuote, 0, "launch-token fees were not swapped to quote");
        uint256 distributedQuote = fees.directQuoteFee + fees.swappedQuote;
        assertEq(fees.protocolQuote, distributedQuote * 5_000 / 10_000, "protocol ratio");
        assertEq(fees.creatorQuote, distributedQuote - fees.protocolQuote, "creator ratio");

        assertEq(weth.balanceOf(feeReceiverAtAccrual), snapshot.oldReceiverQuote, "stale fee receiver paid");
        assertEq(
            weth.balanceOf(feeReceiverAtCollection) - snapshot.newReceiverQuote,
            fees.protocolQuote,
            "current fee receiver protocol share"
        );
        assertEq(
            weth.balanceOf(deployed.creatorFeeVault) - snapshot.vaultQuote, fees.creatorQuote, "vault quote receipt"
        );
        assertEq(
            creatorFeeVault.getBalance(token) - snapshot.creatorCredit, fees.creatorQuote, "creator vault accounting"
        );

        assertEq(_positionHash(token), snapshot.positions, "fee collection changed LP principal");
        _assertNoCallResidue(token);
    }

    function _createToken(bool launchTokenIsToken0) private returns (address token) {
        bytes32 salt = _saltForOrdering(launchTokenIsToken0);
        uint256 deployFee = IProtocolManager(deployed.protocolManager).deployFee(deployed.weth);
        _fundWeth(creator, deployFee);
        vm.prank(creator);
        weth.approve(deployed.giwaRouter, deployFee);

        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: deployed.creatorFeeVault, bps: 10_000, setupData: abi.encode(creator)
        });

        vm.prank(creator);
        (token,) = giwaRouter.create(
            IGiwaRouter.CreateParams({
                name: "Canonical WETH LP Fee",
                symbol: "CWLP",
                tokenURI: "",
                quoteToken: deployed.weth,
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
            salt = keccak256(abi.encode("weth-v3-lp-fee-e2e", launchTokenIsToken0, nonce));
            address predicted = Clones.predictDeterministicAddress(deployed.tokenImpl, salt, deployed.bondingCurve);
            if ((predicted < deployed.weth) == launchTokenIsToken0) return salt;
        }
        revert("ordering salt not found");
    }

    function _graduate(address token) private {
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

    function _roundTripFullBalance(address token) private {
        _fundWeth(trader, POST_GRADUATION_QUOTE_IN);
        vm.prank(trader);
        weth.approve(deployed.giwaRouter, POST_GRADUATION_QUOTE_IN);
        vm.prank(trader);
        uint256 tokenOut = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: POST_GRADUATION_QUOTE_IN, amountOutMin: 1, token: token, to: trader, deadline: block.timestamp
            })
        );
        assertGt(tokenOut, 0, "post-graduation buy output");

        uint256 fullBalance = IERC20(token).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(token).approve(deployed.giwaRouter, fullBalance);
        uint256 quoteOut = giwaRouter.sell(
            IGiwaRouter.SellParams({
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
            + IERC20(token).balanceOf(deployed.v3LiquidityActor) + IERC20(token).balanceOf(deployed.giwaRouter)
            + IERC20(token).balanceOf(deployed.v3SwapAdapter);
        assertEq(accounted, IERC20(token).totalSupply(), "graduation launch-token supply accounting");
    }

    function _assertNoCallResidue(address token) private view {
        assertEq(IERC20(token).balanceOf(deployed.lpManager), 0, "LPManager token residue");
        assertEq(weth.balanceOf(deployed.lpManager), 0, "LPManager quote residue");
        assertEq(IERC20(token).balanceOf(deployed.creatorFeeProcessor), 0, "processor token residue");
        assertEq(weth.balanceOf(deployed.creatorFeeProcessor), 0, "processor quote residue");
        assertEq(IERC20(token).balanceOf(deployed.v3LiquidityActor), 0, "actor token residue");
        assertEq(weth.balanceOf(deployed.v3LiquidityActor), 0, "actor quote residue");
        assertEq(IERC20(token).balanceOf(deployed.v3SwapAdapter), 0, "adapter token residue");
        assertEq(weth.balanceOf(deployed.v3SwapAdapter), 0, "adapter quote residue");
        assertEq(IERC20(token).allowance(deployed.lpManager, deployed.v3SwapAdapter), 0, "adapter token allowance");
        assertEq(weth.allowance(deployed.lpManager, deployed.creatorFeeProcessor), 0, "processor quote allowance");
        assertEq(IERC20(token).allowance(deployed.lpManager, deployed.v3LiquidityActor), 0, "actor token allowance");
        assertEq(weth.allowance(deployed.lpManager, deployed.v3LiquidityActor), 0, "actor quote allowance");
    }

    function _decodeCollection(Vm.Log[] memory logs, address token) private view returns (CollectedFees memory fees) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == deployed.lpManager && logs[i].topics.length == 3
                    && logs[i].topics[0] == FEES_COLLECTED_TOPIC
                    && address(uint160(uint256(logs[i].topics[1]))) == token
                    && address(uint160(uint256(logs[i].topics[2]))) == deployed.weth
            ) {
                (fees.tokenFee, fees.directQuoteFee, fees.swappedQuote, fees.protocolQuote, fees.creatorQuote) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                return fees;
            }
        }
        revert("V3FeesCollected missing");
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
        (uint128 liveQuoteLiquidity,,,,) = IUniswapV3Pool(pool).positions(quoteKey);
        (uint128 liveTokenLiquidity,,,,) = IUniswapV3Pool(pool).positions(tokenKey);
        assertEq(liveQuoteLiquidity, quoteLiquidity, "cached quote liquidity differs from canonical pool");
        assertEq(liveTokenLiquidity, tokenLiquidity, "cached token liquidity differs from canonical pool");
        return keccak256(
            abi.encode(
                quoteKey,
                quoteLower,
                quoteUpper,
                quoteLiquidity,
                liveQuoteLiquidity,
                tokenKey,
                tokenLower,
                tokenUpper,
                tokenLiquidity,
                liveTokenLiquidity
            )
        );
    }

    function _fundWeth(address account, uint256 amount) private {
        vm.deal(account, amount);
        vm.prank(account);
        weth.deposit{value: amount}();
    }
}
