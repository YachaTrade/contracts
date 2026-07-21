// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";
import {ICreatorFeeProcessor} from "../../src/interfaces/ICreatorFeeProcessor.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {Token} from "../../src/token/Token.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";

contract MockRouter {
    uint256 public amountOut;

    function setAmountOut(uint256 amountOut_) external {
        amountOut = amountOut_;
    }

    function getAmountOut(address, uint256, bool) external view returns (uint256) {
        return amountOut;
    }
}

contract MockV3LockPool {
    bool public unlocked;

    constructor(bool unlocked_) {
        unlocked = unlocked_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (1, 0, 0, 0, 0, 0, unlocked);
    }
}

contract MalformedLockPool {
    fallback(bytes calldata) external returns (bytes memory) {
        return hex"00";
    }
}

contract FeeCollectorTest is Test {
    FeeCollector public collector;
    MockERC20 public quoteToken;
    MockWMON public wmon;
    CreatorFeeProcessor public creatorFeeProcessor;
    CreatorFeeVault public creatorFeeVault;
    TokenRegistry public localTokenRegistry;
    NadFunFactory public nadFunFactory;

    ProtocolManager public protocolManager;
    MockRouter public router;
    address public owner = address(this);
    address public bondingCurve = makeAddr("bondingCurve");
    address public feeReceiver = makeAddr("feeReceiver");
    address public pair;
    Token public tokenContract;
    address public token;
    address public alice = makeAddr("alice");
    address public creator = makeAddr("creator");

    uint16 constant CREATOR_FEE_RATE = 200; // 2%
    uint16 constant PROTOCOL_FEE_RATE = 100; // 1%
    uint256 constant THRESHOLD = 1 ether;

    function setUp() public {
        quoteToken = new MockERC20("Quote", "QT", 18);
        wmon = new MockWMON();

        // Deploy real ProtocolManager (authority for AccessManaged contracts)
        ProtocolManager pmImpl = new ProtocolManager();
        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(ProtocolManager.initialize, (address(this), feeReceiver))
                )
            )
        );
        router = new MockRouter();
        router.setAmountOut(type(uint256).max);

        // Resolve circular dependency: CreatorFeeProcessor needs feeCollector address,
        // FeeCollector.initialize needs creatorFeeProcessor address.
        // Use vm.computeCreateAddress to predict the FeeCollector proxy address.
        FeeCollector impl = new FeeCollector();

        uint64 nonce = vm.getNonce(address(this));
        // Next deploys: CreatorFeeProcessor (nonce), then ERC1967Proxy for FeeCollector (nonce+1)
        address predictedFeeCollector = vm.computeCreateAddress(address(this), nonce + 1);

        creatorFeeProcessor = new CreatorFeeProcessor(bondingCurve, predictedFeeCollector);

        bytes memory initData = abi.encodeCall(
            FeeCollector.initialize,
            (address(protocolManager), address(creatorFeeProcessor), bondingCurve, address(router))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        collector = FeeCollector(address(proxy));
        require(address(collector) == predictedFeeCollector, "FeeCollector address prediction failed");

        // Deploy TokenRegistry for CreatorFeeVault.claim()
        TokenRegistry trImpl = new TokenRegistry();
        localTokenRegistry = TokenRegistry(
            address(
                new ERC1967Proxy(address(trImpl), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager))))
            )
        );

        // Deploy CreatorFeeVault via UUPS proxy
        creatorFeeVault = CreatorFeeVault(
            payable(address(
                    new ERC1967Proxy(
                        address(new CreatorFeeVault()),
                        abi.encodeCall(
                            CreatorFeeVault.initialize,
                            (
                                address(protocolManager),
                                bondingCurve,
                                address(creatorFeeProcessor),
                                address(localTokenRegistry),
                                address(wmon),
                                ""
                            )
                        )
                    )
                ))
        );

        // Deploy real Token so settle() can call isGraduated()
        // Token impl disables initializers in constructor; use clone pattern like production.
        Token tokenImpl = new Token();
        token = Clones.clone(address(tokenImpl));
        Token(token).initialize("Test", "TST", "", bondingCurve, address(0));
        tokenContract = Token(token);
        // Mark token as graduated so settle() doesn't early-return
        vm.prank(bondingCurve);
        tokenContract.setIsGraduated();

        // Deploy NadFunFactory and create real pair
        NadFunPair pairImpl = new NadFunPair();
        nadFunFactory = new NadFunFactory(address(this), address(collector), address(pairImpl));
        pair = nadFunFactory.createPair(token, address(quoteToken));

        // Register token in localTokenRegistry so CreatorFeeVault.claim() can look up quoteToken
        protocolManager.setOperatorPermission(
            address(this), address(localTokenRegistry), TokenRegistry.register.selector, true
        );
        // Test contract acts as the settler keeper so it can trigger FeeCollector.settle directly.
        protocolManager.setOperatorPermission(address(this), address(collector), FeeCollector.settle.selector, true);
        localTokenRegistry.register(token, pair, address(quoteToken), ITokenRegistry.DexType.UniswapV2);

        // Configure CreatorFeeProcessor vaults for `token`: 100% to creatorFeeVault
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](1);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(creatorFeeVault), bps: 10_000});
        vm.prank(bondingCurve);
        creatorFeeProcessor.setup(token, vaults);

        // Configure CreatorFeeVault recipient for `token`
        vm.prank(bondingCurve);
        creatorFeeVault.setup(token, abi.encode(creator));

        // Set settlement threshold on ProtocolManager (default is 1_000_000 ether)
        protocolManager.setSettlementThreshold(address(quoteToken), THRESHOLD);
    }

    // ─── Helpers ────────────────────────────────────────────

    function _setupPair() internal {
        vm.prank(bondingCurve);
        collector.setup(pair, token, address(quoteToken), CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE);
    }

    function _setupPool(address pool) internal {
        vm.prank(bondingCurve);
        collector.setup(pool, token, address(quoteToken), CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE);
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }

    function _fundAndCollect(uint256 amount) internal {
        IFeeCollector.FeeConfig memory config = collector.getFeeConfig(pair);
        uint256 totalRate = uint256(config.creatorFeeRate) + uint256(config.dexProtocolFeeRate);
        uint256 protocolFee = _mulDivUp(amount, uint256(config.dexProtocolFeeRate), totalRate);
        uint256 creatorFee = amount - protocolFee;

        quoteToken.mint(address(collector), amount);
        vm.prank(pair);
        collector.collectFee(pair, protocolFee, creatorFee);
    }

    // ─── Setup Tests ────────────────────────────────────────

    function test_setup_storesFeeConfig() public {
        _setupPair();

        IFeeCollector.FeeConfig memory cfg = collector.getFeeConfig(pair);
        assertEq(cfg.creatorFeeRate, CREATOR_FEE_RATE);
        assertEq(cfg.curveProtocolFeeRate, PROTOCOL_FEE_RATE);
        assertEq(cfg.dexProtocolFeeRate, PROTOCOL_FEE_RATE);
    }

    function test_setup_revertsOnDuplicate() public {
        _setupPair();

        vm.prank(bondingCurve);
        vm.expectRevert(IFeeCollector.AlreadyConfigured.selector);
        collector.setup(pair, token, address(quoteToken), CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE);
    }

    function test_setup_revertsOnZeroRates() public {
        vm.prank(bondingCurve);
        vm.expectRevert(IFeeCollector.InvalidRates.selector);
        collector.setup(pair, token, address(quoteToken), 0, 0, 0);
    }

    function test_setup_onlyBondingCurve() public {
        vm.prank(alice);
        vm.expectRevert(IFeeCollector.NotAuthorized.selector);
        collector.setup(pair, token, address(quoteToken), CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE);
    }

    function test_setup_revertsOnZeroPair() public {
        vm.prank(bondingCurve);
        vm.expectRevert(IFeeCollector.ZeroAddress.selector);
        collector.setup(address(0), token, address(quoteToken), CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE);
    }

    function test_setup_revertsOnZeroMemeToken() public {
        vm.prank(bondingCurve);
        vm.expectRevert(IFeeCollector.ZeroAddress.selector);
        collector.setup(pair, address(0), address(quoteToken), CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE);
    }

    function test_setup_revertsOnZeroQuoteToken() public {
        vm.prank(bondingCurve);
        vm.expectRevert(IFeeCollector.ZeroAddress.selector);
        collector.setup(pair, token, address(0), CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE);
    }

    // ─── getFeeConfig Tests ─────────────────────────────────

    function test_getFeeConfig() public {
        _setupPair();

        IFeeCollector.FeeConfig memory config = collector.getFeeConfig(pair);
        assertEq(config.creatorFeeRate + config.curveProtocolFeeRate, CREATOR_FEE_RATE + PROTOCOL_FEE_RATE);
        assertEq(config.creatorFeeRate + config.dexProtocolFeeRate, CREATOR_FEE_RATE + PROTOCOL_FEE_RATE);
        assertEq(config.quoteToken, address(quoteToken));
    }

    function test_getFeeConfig_unconfiguredPair_returnsZero() public {
        IFeeCollector.FeeConfig memory config = collector.getFeeConfig(makeAddr("unknownPair"));
        assertEq(config.creatorFeeRate + config.curveProtocolFeeRate + config.dexProtocolFeeRate, 0);
        assertEq(config.quoteToken, address(0));
    }

    // ─── Collection Tests ───────────────────────────────────

    function test_collectFee_accumulatesFees() public {
        _setupPair();

        // Only creator fee portion is accumulated: amount - protocolAmount
        // protocolAmount = amount * dexProtocolFeeRate / totalRate (rounded up) for pair collection
        // creatorFeeAmount = amount - protocolAmount
        uint256 totalRate = uint256(CREATOR_FEE_RATE) + uint256(PROTOCOL_FEE_RATE);

        _fundAndCollect(0.5 ether);
        uint256 protocol1 = _mulDivUp(0.5 ether, uint256(PROTOCOL_FEE_RATE), totalRate);
        uint256 expectedCreatorFee1 = 0.5 ether - protocol1;
        assertEq(collector.accumulatedFee(pair), expectedCreatorFee1);

        _fundAndCollect(0.3 ether);
        uint256 protocol2 = _mulDivUp(0.3 ether, uint256(PROTOCOL_FEE_RATE), totalRate);
        uint256 expectedCreatorFee2 = 0.3 ether - protocol2;
        assertEq(collector.accumulatedFee(pair), expectedCreatorFee1 + expectedCreatorFee2);
    }

    function test_collectFee_emitsEvent() public {
        _setupPair();

        quoteToken.mint(address(collector), 1 ether);
        uint256 totalRate = uint256(CREATOR_FEE_RATE) + uint256(PROTOCOL_FEE_RATE);
        uint256 protocolFee = _mulDivUp(1 ether, uint256(PROTOCOL_FEE_RATE), totalRate);

        vm.expectEmit(true, true, false, true);
        emit IFeeCollector.Collect(token, pair, 1 ether);
        vm.prank(pair);
        collector.collectFee(pair, protocolFee, 1 ether - protocolFee);
    }

    function test_collectFee_revertsIfNotConfigured() public {
        vm.expectRevert(IFeeCollector.NotConfigured.selector);
        vm.prank(pair);
        collector.collectFee(pair, 0, 0);
    }

    function test_collectFee_revertsOnInsufficientFeeAmount() public {
        _setupPair();

        quoteToken.mint(address(collector), 0.89 ether);

        vm.expectRevert(IFeeCollector.InvalidFeeAmount.selector);
        vm.prank(pair);
        collector.collectFee(pair, 0.4 ether, 0.5 ether);
    }

    function test_collectFee_sendsExcessToFeeReceiver() public {
        _setupPair();

        quoteToken.mint(address(collector), 1 ether);

        vm.prank(pair);
        collector.collectFee(pair, 0.4 ether, 0.5 ether);

        assertEq(quoteToken.balanceOf(feeReceiver), 0.5 ether);
        assertEq(collector.accumulatedFee(pair), 0.5 ether);
    }

    function test_collectFee_doesNotResplitExactCurveFees() public {
        vm.prank(bondingCurve);
        collector.setup(pair, token, address(quoteToken), 500, 50, 50);

        quoteToken.mint(address(collector), 100);

        vm.prank(bondingCurve);
        collector.collectFee(pair, 50, 50);

        assertEq(quoteToken.balanceOf(feeReceiver), 50, "protocol fee should use caller-provided amount");
        assertEq(collector.accumulatedFee(pair), 50, "creator fee should use caller-provided amount");
    }

    // ─── Settlement Tests ───────────────────────────────────

    function test_settle_allowsUnlockedV3Pool() public {
        MockV3LockPool pool = new MockV3LockPool(true);
        _setupPool(address(pool));

        collector.settle(address(pool), 0);
    }

    function test_settle_revertsForLockedV3Pool() public {
        MockV3LockPool pool = new MockV3LockPool(false);
        _setupPool(address(pool));

        vm.expectRevert(IFeeCollector.PairLocked.selector);
        collector.settle(address(pool), 0);
    }

    function test_settle_revertsForMalformedPoolLockResponse() public {
        MalformedLockPool pool = new MalformedLockPool();
        _setupPool(address(pool));

        vm.expectRevert(IFeeCollector.PairLocked.selector);
        collector.settle(address(pool), 0);
    }

    function test_settle_splitsCorrectly() public {
        _setupPair();
        _fundAndCollect(3 ether);

        // Protocol fee already sent during collectFee: 3 ether * 100/300 = 1 ether
        // Accumulated (creator fee only): 3 ether * 200/300 = 2 ether
        assertEq(quoteToken.balanceOf(feeReceiver), 1 ether);

        collector.settle(pair, 0);

        // settle() sends accumulated creator fee through creatorFeeProcessor to vault
        // CreatorFeeVault now accumulates — creator must claim()
        assertEq(quoteToken.balanceOf(feeReceiver), 1 ether);
        assertEq(creatorFeeVault.getBalance(token), 2 ether, "Vault should accumulate creator fee");

        // Creator claims
        vm.prank(creator);
        creatorFeeVault.claim(token);
        assertEq(quoteToken.balanceOf(creator), 2 ether);
    }

    function test_settle_noOpUnderThreshold() public {
        _setupPair();
        _fundAndCollect(0.5 ether); // accumulated creator fee below 1 ether threshold

        // Protocol fee was already sent during collectFee
        uint256 protocolAmount =
            _mulDivUp(0.5 ether, uint256(PROTOCOL_FEE_RATE), uint256(CREATOR_FEE_RATE) + uint256(PROTOCOL_FEE_RATE));

        uint256 accBefore = collector.accumulatedFee(pair);
        collector.settle(pair, 0);
        uint256 accAfter = collector.accumulatedFee(pair);

        assertEq(accAfter, accBefore, "Accumulated fee should be unchanged (no-op)");
        // feeReceiver already received protocol fee during collectFee
        assertEq(quoteToken.balanceOf(feeReceiver), protocolAmount, "Protocol fee sent during collectFee");
        assertEq(quoteToken.balanceOf(creator), 0, "Creator should not receive fees (no-op)");
    }

    function test_settle_protocolFeeToFeeReceiver() public {
        _setupPair();
        _fundAndCollect(3 ether);

        // Protocol fee already sent during collectFee: 3 ether * 100/300 = 1 ether
        assertEq(quoteToken.balanceOf(feeReceiver), 1 ether);

        collector.settle(pair, 0);

        // settle() does not send additional protocol fees
        assertEq(quoteToken.balanceOf(feeReceiver), 1 ether);
    }

    function test_settle_creatorFeeToProcessor() public {
        _setupPair();
        _fundAndCollect(3 ether);

        collector.settle(pair, 0);

        // Creator fee (2 ether) flows through CreatorFeeProcessor -> CreatorFeeVault (accumulated)
        // Vault holds the balance until creator claims
        assertEq(creatorFeeVault.getBalance(token), 2 ether, "Vault should hold accumulated creator fee");
        assertEq(quoteToken.balanceOf(address(creatorFeeProcessor)), 0, "Processor should be pass-through");
        assertEq(quoteToken.balanceOf(address(creatorFeeVault)), 2 ether, "Vault should hold quoteToken");

        // Creator claims
        vm.prank(creator);
        creatorFeeVault.claim(token);
        assertEq(quoteToken.balanceOf(creator), 2 ether);
        assertEq(quoteToken.balanceOf(address(creatorFeeVault)), 0, "Vault should be empty after claim");
    }

    function test_settle_revertsWhenRouterQuoteBelowMinAmountOut() public {
        _setupPair();
        _fundAndCollect(3 ether);
        uint256 accumulatedBefore = collector.accumulatedFee(pair);

        router.setAmountOut(99 ether);
        vm.expectRevert(IFeeCollector.InsufficientOutput.selector);
        collector.settle(pair, 100 ether);

        assertEq(collector.accumulatedFee(pair), accumulatedBefore, "Accumulated fee should remain after revert");
        assertFalse(collector.isSettling(pair), "settling flag should roll back");
        assertEq(creatorFeeVault.getBalance(token), 0, "Vault should not receive fees");
    }

    function test_settle_allowsRouterQuoteAtMinAmountOut() public {
        _setupPair();
        _fundAndCollect(3 ether);

        router.setAmountOut(100 ether);
        collector.settle(pair, 100 ether);

        assertEq(collector.accumulatedFee(pair), 0);
        assertEq(creatorFeeVault.getBalance(token), 2 ether, "Vault should receive fees");
    }

    function test_settle_restrictedToAuthorizedSettler() public {
        _setupPair();
        // Need to fund enough so accumulated creator fee exceeds threshold (1 ether)
        // Creator fee portion = amount * 200/300. For creator fee >= 1 ether, need amount >= 1.5 ether
        _fundAndCollect(1.5 ether);

        // A random address cannot call settle — only authorized operators.
        vm.prank(alice);
        vm.expectRevert();
        collector.settle(pair, 0);

        // The authorized settler (test contract, granted in SetUp) can.
        collector.settle(pair, 0);
        assertEq(collector.accumulatedFee(pair), 0);
    }

    function test_settle_resetsAccumulated() public {
        _setupPair();
        _fundAndCollect(2 ether);

        collector.settle(pair, 0);

        assertEq(collector.accumulatedFee(pair), 0);
        assertFalse(collector.isSettleable(pair));
    }

    function test_settle_emitsEvent() public {
        _setupPair();
        _fundAndCollect(3 ether);

        // Accumulated creatorFee = 3 ether * 200/300 = 2 ether
        // settle() emits Settle(pair, creatorFeeAmount, 0, creatorFeeAmount)
        vm.expectEmit(true, false, false, true);
        emit IFeeCollector.Settle(token, pair, 2 ether, 2 ether);
        collector.settle(pair, 0);
    }

    // ─── Edge Cases ─────────────────────────────────────────

    function test_settle_zeroCreatorFeeRate_allToProtocol() public {
        vm.prank(bondingCurve);
        collector.setup(pair, token, address(quoteToken), 0, 500, 500); // only protocol fee

        _fundAndCollect(2 ether);
        collector.settle(pair, 0);

        assertEq(quoteToken.balanceOf(feeReceiver), 2 ether);
        assertEq(quoteToken.balanceOf(creator), 0, "Creator should not receive fees when creatorFeeRate is 0");
    }

    function test_settle_zeroProtocolFee_allToCreatorFee() public {
        vm.prank(bondingCurve);
        collector.setup(pair, token, address(quoteToken), 500, 0, 0); // only creator fee

        _fundAndCollect(2 ether);
        collector.settle(pair, 0);

        assertEq(quoteToken.balanceOf(feeReceiver), 0);
        // All 2 ether flows through CreatorFeeProcessor -> CreatorFeeVault (accumulated)
        assertEq(creatorFeeVault.getBalance(token), 2 ether, "Vault should accumulate all creator fee");

        // Creator claims
        vm.prank(creator);
        creatorFeeVault.claim(token);
        assertEq(quoteToken.balanceOf(creator), 2 ether);
    }

    function test_getFeeConfig_unregisteredPair_returnsZero() public {
        IFeeCollector.FeeConfig memory cfg = collector.getFeeConfig(address(0xdead));
        assertEq(cfg.creatorFeeRate, 0);
        assertEq(cfg.curveProtocolFeeRate, 0);
        assertEq(cfg.dexProtocolFeeRate, 0);
    }

    function test_isSettleable() public {
        _setupPair();

        assertFalse(collector.isSettleable(pair));

        // Creator fee portion = amount * 200/300. Need accumulated creator fee >= 1 ether (threshold).
        // 0.75 ether -> creatorFee = 0.5 ether (below threshold)
        _fundAndCollect(0.75 ether);
        assertFalse(collector.isSettleable(pair));

        // Another 0.75 ether -> accumulated creatorFee = 1.0 ether (meets threshold)
        _fundAndCollect(0.75 ether);
        assertTrue(collector.isSettleable(pair));
    }

    // ─── Admin Tests ────────────────────────────────────────

    function test_settlementThreshold_readsProtocolManager() public {
        _setupPair();
        protocolManager.setSettlementThreshold(address(quoteToken), 2 ether);
        assertEq(collector.settlementThreshold(pair), 2 ether);

        vm.prank(alice);
        vm.expectRevert();
        protocolManager.setSettlementThreshold(address(quoteToken), 3 ether);
    }

    function test_setProtocolFeeRates_onlyOwner() public {
        _setupPair();

        collector.setCurveProtocolFeeRate(pair, 300);
        collector.setDexProtocolFeeRate(pair, 400);
        IFeeCollector.FeeConfig memory cfg = collector.getFeeConfig(pair);
        assertEq(cfg.curveProtocolFeeRate, 300);
        assertEq(cfg.dexProtocolFeeRate, 400);

        vm.prank(alice);
        vm.expectRevert();
        collector.setCurveProtocolFeeRate(pair, 500);

        vm.prank(alice);
        vm.expectRevert();
        collector.setDexProtocolFeeRate(pair, 500);
    }

    function test_setProtocolFeeRates_revertIfNotConfigured() public {
        vm.expectRevert(IFeeCollector.NotConfigured.selector);
        collector.setCurveProtocolFeeRate(makeAddr("unregistered"), 300);

        vm.expectRevert(IFeeCollector.NotConfigured.selector);
        collector.setDexProtocolFeeRate(makeAddr("unregistered"), 300);
    }

    function test_setCurveProtocolFeeRate_revertsAboveMax() public {
        _setupPair();

        vm.expectRevert("Protocol fee too high");
        collector.setCurveProtocolFeeRate(pair, 1001);
    }

    function test_setDexProtocolFeeRate_revertsAboveMax() public {
        _setupPair();

        vm.expectRevert("Dex protocol fee too high");
        collector.setDexProtocolFeeRate(pair, 1001);
    }

    // ─── Initialize Validation ──────────────────────────────

    function test_initialize_revertsOnZeroAddress() public {
        FeeCollector impl = new FeeCollector();

        vm.expectRevert(IFeeCollector.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                FeeCollector.initialize, (address(protocolManager), address(0), bondingCurve, address(router))
            )
        );

        vm.expectRevert(IFeeCollector.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                FeeCollector.initialize,
                (address(protocolManager), address(creatorFeeProcessor), address(0), address(router))
            )
        );

        vm.expectRevert(IFeeCollector.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                FeeCollector.initialize,
                (address(protocolManager), address(creatorFeeProcessor), bondingCurve, address(0))
            )
        );
    }
}
