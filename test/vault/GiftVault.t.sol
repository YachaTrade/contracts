// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for GiftVault (platform-id based, setReceiver streaming).

import {Test} from "forge-std/Test.sol";
import {GiftVault} from "../../src/vault/GiftVault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {NadSwapAdapter} from "../../src/adapters/NadSwapAdapter.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {BPS} from "../../src/libraries/Constants.sol";

/// @dev Helper that reverts on native receive — used to exercise NativeTransferFailed.
contract RevertingReceiver {
    receive() external payable {
        revert("RevertingReceiver");
    }
}

contract GiftVaultTest is Test {
    GiftVault public vault;
    MockERC20 public quoteToken;
    MockWMON public wmon;
    MockERC20 public creatorFeeToken;
    NadFunFactory public factory;
    TokenRegistry public tokenRegistry;
    FeeCollector public feeCollector;
    ProtocolManager public protocolManager;
    address public pair;

    address bondingCurve = makeAddr("bondingCurve");
    address feeReceiver = makeAddr("feeReceiver");
    address receiver = makeAddr("receiver");
    address relayer = makeAddr("relayer");

    string constant GIFT_ID = "alice";
    GiftVault.Platform constant GIFT_PLATFORM = GiftVault.Platform.X;
    uint256 constant EXPIRY_DURATION = 10 days;

    address constant BURN_ADDRESS = address(0xdead);
    uint256 constant LP_FEE_RATE = 25;
    uint256 constant INITIAL_TOKEN_LIQ = 100_000 ether;
    uint256 constant INITIAL_QUOTE_LIQ = 100 ether;

    function setUp() public {
        quoteToken = new MockERC20("WMON", "WMON", 18);
        wmon = new MockWMON();
        creatorFeeToken = new MockERC20("BASE", "BASE", 18);

        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), feeReceiver))
                )
            )
        );

        feeCollector = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(new FeeCollector()),
                    abi.encodeCall(
                        FeeCollector.initialize,
                        (address(protocolManager), makeAddr("creatorFeeProcessor"), bondingCurve, makeAddr("router"))
                    )
                )
            )
        );

        NadFunPair pairImpl = new NadFunPair();
        factory = new NadFunFactory(address(this), address(feeCollector), address(pairImpl));
        pair = factory.createPair(address(quoteToken), address(creatorFeeToken));

        _seedLiquidity(INITIAL_TOKEN_LIQ, INITIAL_QUOTE_LIQ);

        tokenRegistry = TokenRegistry(
            address(
                new ERC1967Proxy(
                    address(new TokenRegistry()), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager)))
                )
            )
        );
        protocolManager.setOperatorPermission(
            bondingCurve, address(tokenRegistry), TokenRegistry.register.selector, true
        );
        tokenRegistry.setAdapter(ITokenRegistry.DexType.UniswapV2, IDexAdapter(address(new NadSwapAdapter())));

        vm.prank(bondingCurve);
        tokenRegistry.register(address(creatorFeeToken), pair, address(quoteToken), ITokenRegistry.DexType.UniswapV2);

        vault = GiftVault(
            payable(address(
                    new ERC1967Proxy(
                        address(new GiftVault()),
                        abi.encodeCall(
                            GiftVault.initialize,
                            (
                                address(protocolManager),
                                address(this),
                                bondingCurve,
                                address(tokenRegistry),
                                EXPIRY_DURATION,
                                address(this),
                                address(wmon),
                                ""
                            )
                        )
                    )
                ))
        );

        // Grant the relayer operator permission to call setReceiver.
        protocolManager.setOperatorPermission(relayer, address(vault), GiftVault.setReceiver.selector, true);

        // Setup platform-id for creatorFeeToken
        vm.prank(bondingCurve);
        vault.setup(address(creatorFeeToken), _encodeTarget(GIFT_PLATFORM, GIFT_ID));

        vm.mockCall(address(creatorFeeToken), abi.encodeWithSignature("isGraduated()"), abi.encode(true));
    }

    // ── setup ──────────────────────────────────────────────────────

    function test_setup_registersPlatformAndId() public view {
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(uint8(info.platform), uint8(GIFT_PLATFORM), "platform should be stored");
        assertEq(info.id, GIFT_ID, "id should be registered");
    }

    function test_setup_emitsSetup() public {
        address newToken = makeAddr("newToken");
        string memory id = "bob";
        GiftVault.Platform platform = GiftVault.Platform.GitHub;

        vm.expectEmit(true, false, false, true);
        emit GiftVault.VaultSetup(newToken, platform, id);

        vm.prank(bondingCurve);
        vault.setup(newToken, _encodeTarget(platform, id));
    }

    function test_setup_revert_notBondingCurve() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(GiftVault.NotAuthorized.selector);
        vault.setup(makeAddr("newToken"), _encodeTarget(GIFT_PLATFORM, GIFT_ID));
    }

    function test_setup_revert_emptyId() public {
        vm.prank(bondingCurve);
        vm.expectRevert(GiftVault.EmptyId.selector);
        vault.setup(makeAddr("newToken"), _encodeTarget(GIFT_PLATFORM, ""));
    }

    function test_setup_revert_alreadyConfigured() public {
        vm.prank(bondingCurve);
        vm.expectRevert(GiftVault.AlreadyConfigured.selector);
        vault.setup(address(creatorFeeToken), _encodeTarget(GIFT_PLATFORM, GIFT_ID));
    }

    // ── afterDeposit (accumulation mode, no receiver set) ──────────

    function test_afterDeposit_accumulates() public {
        uint256 amount = 5 ether;
        quoteToken.mint(address(vault), amount);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, amount, "Balance should be accumulated");
    }

    function test_afterDeposit_secondDeposit_accumulates() public {
        quoteToken.mint(address(vault), 3 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 3 ether);

        uint256 createdAt = vault.getGiftInfo(address(creatorFeeToken)).createdAt;
        vm.warp(block.timestamp + 1 days);

        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 2 ether);

        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 5 ether, "Balance should be total");
        assertEq(info.createdAt, createdAt, "createdAt should stay pinned to setup time");
    }

    function test_setup_setsCreatedAt() public {
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.createdAt, block.timestamp, "createdAt should be set at setup");
    }

    function test_afterDeposit_expiresAfterSetupTimer_evenWithoutPriorDeposit() public {
        vm.warp(block.timestamp + EXPIRY_DURATION + 1);

        quoteToken.mint(address(vault), 4 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 4 ether);

        assertTrue(vault.isExpired(address(creatorFeeToken)), "Should expire when window elapses from setup");
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 0, "Balance should be zero");
    }

    function test_afterDeposit_emitsDeposit() public {
        uint256 amount = 1 ether;
        quoteToken.mint(address(vault), amount);

        vm.expectEmit(true, false, false, true);
        emit GiftVault.Deposit(address(creatorFeeToken), amount, amount);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);
    }

    function test_afterDeposit_zeroAmount_noOp() public {
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 0);
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 0, "No deposit should happen for zero amount");
    }

    function test_afterDeposit_revert_notCreatorFeeProcessor() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(GiftVault.NotAuthorized.selector);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);
    }

    // ── setReceiver ────────────────────────────────────────────────

    function test_setReceiver_byRelayer_noPendingBalance() public {
        vm.expectEmit(true, true, false, false);
        emit GiftVault.ReceiverSet(address(creatorFeeToken), receiver);

        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        assertEq(vault.getReceiver(address(creatorFeeToken)), receiver, "Receiver should be stored");
    }

    function test_setReceiver_firstBind_preservesBalance() public {
        uint256 amount = 7 ether;
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        // Balance stays in the vault for the new receiver to claim.
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        assertEq(quoteToken.balanceOf(receiver), 0, "First bind should NOT transfer to new receiver");
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, amount, "Balance should be preserved for the first receiver to claim");
    }

    function test_setReceiver_revert_notOperator() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        vault.setReceiver(address(creatorFeeToken), receiver);
    }

    function test_setReceiver_revert_zeroReceiver() public {
        vm.prank(relayer);
        vm.expectRevert(GiftVault.ZeroReceiver.selector);
        vault.setReceiver(address(creatorFeeToken), address(0));
    }

    function test_setReceiver_revert_notConfigured() public {
        address unknown = makeAddr("unknown");
        vm.prank(relayer);
        vm.expectRevert(GiftVault.NotConfigured.selector);
        vault.setReceiver(unknown, receiver);
    }

    function test_setReceiver_canRotate() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        address newReceiver = makeAddr("newReceiver");
        vm.expectEmit(true, true, false, false);
        emit GiftVault.ReceiverSet(address(creatorFeeToken), newReceiver);

        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), newReceiver);

        assertEq(vault.getReceiver(address(creatorFeeToken)), newReceiver, "Receiver should be rotated");
    }

    function test_setReceiver_rotate_newReceiverInheritsBalance() public {
        // Bind first receiver and let fees accumulate.
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 2 ether);
        assertEq(quoteToken.balanceOf(receiver), 0, "Active mode accumulates; no auto-transfer");

        // Rotate: pointer swaps. Accumulated balance stays in the vault.
        address newReceiver = makeAddr("newReceiver");
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), newReceiver);

        assertEq(quoteToken.balanceOf(receiver), 0, "Previous receiver gets nothing on rotate");
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 2 ether, "Balance persists through rotate - new receiver inherits");
        assertEq(info.receiver, newReceiver, "Receiver pointer swapped");

        // Previous receiver has no authority to claim anymore.
        vm.prank(receiver);
        vm.expectRevert(GiftVault.NotReceiver.selector);
        vault.claim(address(creatorFeeToken));

        // New receiver claims the inherited balance + any further accumulation.
        quoteToken.mint(address(vault), 3 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 3 ether);

        vm.prank(newReceiver);
        vault.claim(address(creatorFeeToken));
        assertEq(quoteToken.balanceOf(newReceiver), 5 ether, "New receiver claims inherited + post-rotate fees");
    }

    function test_setReceiver_rotate_zeroBalance_noop() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        // No deposits before rotate → nothing special. Pointer just swaps.
        address newReceiver = makeAddr("newReceiver");
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), newReceiver);

        assertEq(quoteToken.balanceOf(receiver), 0);
        assertEq(vault.getReceiver(address(creatorFeeToken)), newReceiver);
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 0);
    }

    function test_setReceiver_rotate_afterWindowClosed_stillAllowed() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        vm.warp(block.timestamp + EXPIRY_DURATION + 7 days);

        address newReceiver = makeAddr("newReceiver");
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), newReceiver);

        assertEq(vault.getReceiver(address(creatorFeeToken)), newReceiver, "Rotation bypasses bind window");
    }

    function test_setReceiver_revert_expired() public {
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);
        vm.warp(block.timestamp + EXPIRY_DURATION + 1);
        // Trigger permanent-expire.
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);

        vm.prank(relayer);
        vm.expectRevert(GiftVault.GiftExpiredError.selector);
        vault.setReceiver(address(creatorFeeToken), receiver);
    }

    function test_setReceiver_afterWindowClosed_butNotYetBurned_stillAllowed() public {
        // Window elapsed with NO deposits arriving — _expired never got flipped.
        vm.warp(block.timestamp + EXPIRY_DURATION + 30 days);

        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        assertEq(vault.getReceiver(address(creatorFeeToken)), receiver, "Rescue bind should work while not expired");
    }

    // ── afterDeposit (Active state — accumulate only) ──────────────

    function test_afterDeposit_active_accumulatesOnly() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        uint256 amount = 4 ether;
        quoteToken.mint(address(vault), amount);

        vm.expectEmit(true, false, false, true);
        emit GiftVault.Deposit(address(creatorFeeToken), amount, amount);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        assertEq(quoteToken.balanceOf(receiver), 0, "Receiver should NOT get auto-transfer in claim model");
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, amount, "Balance should accumulate");
    }

    function test_afterDeposit_active_skipsBindExpiry() public {
        // Bind before expiry window closes.
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        vm.warp(block.timestamp + EXPIRY_DURATION + 365 days);

        uint256 amount = 2 ether;
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        assertFalse(vault.isExpired(address(creatorFeeToken)), "Active state never expires");
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, amount, "Active mode accumulates past the bind window");
    }

    function test_afterDeposit_active_multipleDeposits_allAccumulate() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);

        quoteToken.mint(address(vault), 3 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 3 ether);

        assertEq(quoteToken.balanceOf(receiver), 0, "No direct transfers in claim model");
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 4 ether, "Active mode accumulates across deposits");
    }

    // ── claim ──────────────────────────────────────────────────────

    function test_claim_byReceiver_transfersFullBalance() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        uint256 amount = 10 ether;
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        vm.expectEmit(true, true, false, true);
        emit GiftVault.Claim(address(creatorFeeToken), receiver, amount);

        vm.prank(receiver);
        vault.claim(address(creatorFeeToken));

        assertEq(quoteToken.balanceOf(receiver), amount, "Receiver should get full balance");
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 0, "Balance zeroed after claim");
    }

    function test_claim_repeatable() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        // Round 1
        quoteToken.mint(address(vault), 5 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 5 ether);
        vm.prank(receiver);
        vault.claim(address(creatorFeeToken));
        assertEq(quoteToken.balanceOf(receiver), 5 ether);

        // Round 2 — new fees arrive, receiver claims again
        quoteToken.mint(address(vault), 3 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 3 ether);
        vm.prank(receiver);
        vault.claim(address(creatorFeeToken));
        assertEq(quoteToken.balanceOf(receiver), 8 ether, "Multiple claims accumulate at receiver");

        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 0, "Balance zeroed after second claim");
    }

    function test_claim_revert_notReceiver_relayer() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);

        // Even the relayer cannot claim on behalf of the receiver.
        vm.prank(relayer);
        vm.expectRevert(GiftVault.NotReceiver.selector);
        vault.claim(address(creatorFeeToken));
    }

    function test_claim_revert_notReceiver_attacker() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(GiftVault.NotReceiver.selector);
        vault.claim(address(creatorFeeToken));
    }

    function test_claim_revert_notReceiver_previousAfterRotate() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        // Accumulate under the first receiver.
        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 2 ether);

        // Rotate — balance is inherited by newReceiver, previous loses claim authority.
        address newReceiver = makeAddr("newReceiver");
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), newReceiver);

        vm.prank(receiver);
        vm.expectRevert(GiftVault.NotReceiver.selector);
        vault.claim(address(creatorFeeToken));
    }

    function test_claim_revert_zeroBalance() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        vm.prank(receiver);
        vm.expectRevert(GiftVault.ZeroBalance.selector);
        vault.claim(address(creatorFeeToken));
    }

    function test_claim_revert_beforeSetReceiver() public {
        // Receiver is address(0), so msg.sender can never match.
        vm.prank(receiver);
        vm.expectRevert(GiftVault.NotReceiver.selector);
        vault.claim(address(creatorFeeToken));
    }

    // ── auto-expire (via afterDeposit, no receiver) ────────────────

    function test_afterDeposit_autoExpires() public {
        quoteToken.mint(address(vault), 3 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 3 ether);

        vm.warp(block.timestamp + EXPIRY_DURATION + 1);

        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 2 ether);

        assertTrue(vault.isExpired(address(creatorFeeToken)), "Should be permanently expired");

        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 0, "Balance should be zero");

        assertGt(creatorFeeToken.balanceOf(BURN_ADDRESS), 0, "Tokens should be burned");
    }

    function test_afterDeposit_expired_immediatelyBurns() public {
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);
        vm.warp(block.timestamp + EXPIRY_DURATION + 1);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);

        uint256 burnedBefore = creatorFeeToken.balanceOf(BURN_ADDRESS);

        uint256 newAmount = 2 ether;
        quoteToken.mint(address(vault), newAmount);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), newAmount);

        uint256 burnedAfter = creatorFeeToken.balanceOf(BURN_ADDRESS);
        assertGt(burnedAfter, burnedBefore, "New deposit should be burned immediately");

        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 0, "Balance should remain zero in permanent burn mode");
    }

    function test_afterDeposit_expired_noLiquidity_keepsPendingForRetry() public {
        MockERC20 noLiqToken = new MockERC20("NOLIQ", "NL", 18);
        address emptyPair = factory.createPair(address(quoteToken), address(noLiqToken));
        vm.prank(bondingCurve);
        tokenRegistry.register(address(noLiqToken), emptyPair, address(quoteToken), ITokenRegistry.DexType.UniswapV2);
        vm.prank(bondingCurve);
        vault.setup(address(noLiqToken), _encodeTarget(GiftVault.Platform.GitHub, "no-liq"));
        vm.mockCall(address(noLiqToken), abi.encodeWithSignature("isGraduated()"), abi.encode(true));

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(noLiqToken), address(quoteToken), 1 ether);

        vm.warp(block.timestamp + EXPIRY_DURATION + 1);

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(noLiqToken), address(quoteToken), 1 ether);

        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(noLiqToken));
        assertEq(uint8(info.state), uint8(GiftVault.State.Burned), "gift should enter burned state");
        assertEq(info.balance, 0, "expired gift balance should move to pending burn");
        assertEq(vault.pendingQuote(address(noLiqToken)), 2 ether, "failed buyback should remain pending");
        assertEq(quoteToken.balanceOf(address(vault)), 2 ether, "quote should stay in vault");

        noLiqToken.mint(address(this), INITIAL_TOKEN_LIQ);
        quoteToken.mint(address(this), INITIAL_QUOTE_LIQ);
        IERC20(address(noLiqToken)).transfer(emptyPair, INITIAL_TOKEN_LIQ);
        IERC20(address(quoteToken)).transfer(emptyPair, INITIAL_QUOTE_LIQ);
        INadFunPair(emptyPair).mint(address(this));

        uint256 retryAmount = 0.5 ether;
        uint256 expectedOut = INadFunPair(emptyPair).getAmountOut(address(quoteToken), 2 ether + retryAmount);
        quoteToken.mint(address(vault), retryAmount);
        vault.afterDeposit(address(noLiqToken), address(quoteToken), retryAmount);

        assertEq(vault.pendingQuote(address(noLiqToken)), 0, "pending quote should be consumed on retry");
        assertEq(noLiqToken.balanceOf(BURN_ADDRESS), expectedOut, "retry should burn pending plus new amount");
    }

    function test_afterDeposit_expired_emitsBurn() public {
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);
        vm.warp(block.timestamp + EXPIRY_DURATION + 1);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);

        quoteToken.mint(address(vault), 2 ether);

        vm.expectEmit(true, false, false, false);
        emit GiftVault.Burn(address(creatorFeeToken), address(0), 0, 0);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 2 ether);
    }

    // ── setExpiryDuration ──────────────────────────────────────────

    function test_setExpiryDuration() public {
        uint256 newDuration = 30 days;

        vm.expectEmit(false, false, false, true);
        emit GiftVault.ExpiryUpdate(EXPIRY_DURATION, newDuration);
        vault.setExpiryDuration(newDuration);

        assertEq(vault.expiryDuration(), newDuration, "Duration should be updated");
    }

    function test_setExpiryDuration_affectsExistingGifts() public {
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);

        vault.setExpiryDuration(1 days);

        vm.warp(block.timestamp + 2 days);

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);
        assertTrue(vault.isExpired(address(creatorFeeToken)), "Should be expired with new duration");
    }

    function test_setExpiryDuration_revert_zeroDuration() public {
        vm.expectRevert(GiftVault.ZeroDuration.selector);
        vault.setExpiryDuration(0);
    }

    function test_setExpiryDuration_revert_notAdmin() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        vault.setExpiryDuration(1 days);
    }

    // ── multi-token isolation ──────────────────────────────────────

    function test_multipleTokens_independentGifts() public {
        MockERC20 creatorFeeToken2 = new MockERC20("BASE2", "BASE2", 18);
        address pair2 = factory.createPair(address(quoteToken), address(creatorFeeToken2));
        vm.prank(bondingCurve);
        tokenRegistry.register(address(creatorFeeToken2), pair2, address(quoteToken), ITokenRegistry.DexType.UniswapV2);

        creatorFeeToken2.mint(address(this), INITIAL_TOKEN_LIQ);
        quoteToken.mint(address(this), INITIAL_QUOTE_LIQ);
        IERC20(address(creatorFeeToken2)).transfer(pair2, INITIAL_TOKEN_LIQ);
        IERC20(address(quoteToken)).transfer(pair2, INITIAL_QUOTE_LIQ);
        INadFunPair(pair2).mint(address(this));

        vm.prank(bondingCurve);
        vault.setup(address(creatorFeeToken2), _encodeTarget(GiftVault.Platform.GitHub, "bob"));

        vm.mockCall(address(creatorFeeToken2), abi.encodeWithSignature("isGraduated()"), abi.encode(true));

        quoteToken.mint(address(vault), 5 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 5 ether);

        quoteToken.mint(address(vault), 3 ether);
        vault.afterDeposit(address(creatorFeeToken2), address(quoteToken), 3 ether);

        GiftVault.GiftInfo memory info1 = vault.getGiftInfo(address(creatorFeeToken));
        GiftVault.GiftInfo memory info2 = vault.getGiftInfo(address(creatorFeeToken2));
        assertEq(info1.balance, 5 ether, "Token1 balance");
        assertEq(info2.balance, 3 ether, "Token2 balance");
        assertEq(uint8(info2.platform), uint8(GiftVault.Platform.GitHub), "Token2 platform should be GitHub");

        vm.warp(block.timestamp + EXPIRY_DURATION + 1);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);

        assertTrue(vault.isExpired(address(creatorFeeToken)), "Token1 should be expired");
        assertFalse(vault.isExpired(address(creatorFeeToken2)), "Token2 should NOT be expired");

        info2 = vault.getGiftInfo(address(creatorFeeToken2));
        assertEq(info2.balance, 3 ether, "Token2 balance should be unchanged");
    }

    // ── initialize guards ──────────────────────────────────────────

    function test_initialize_zeroCreatorFeeProcessor() public {
        GiftVault impl = new GiftVault();
        vm.expectRevert(GiftVault.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GiftVault.initialize,
                (
                    address(protocolManager),
                    address(0),
                    bondingCurve,
                    address(tokenRegistry),
                    EXPIRY_DURATION,
                    address(this),
                    address(wmon),
                    ""
                )
            )
        );
    }

    function test_initialize_zeroBondingCurve() public {
        GiftVault impl = new GiftVault();
        vm.expectRevert(GiftVault.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GiftVault.initialize,
                (
                    address(protocolManager),
                    address(this),
                    address(0),
                    address(tokenRegistry),
                    EXPIRY_DURATION,
                    address(this),
                    address(wmon),
                    ""
                )
            )
        );
    }

    function test_initialize_zeroDuration() public {
        GiftVault impl = new GiftVault();
        vm.expectRevert(GiftVault.ZeroDuration.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GiftVault.initialize,
                (
                    address(protocolManager),
                    address(this),
                    bondingCurve,
                    address(tokenRegistry),
                    0,
                    address(this),
                    address(wmon),
                    ""
                )
            )
        );
    }

    function test_initialize_revert_onImplementation() public {
        GiftVault impl = new GiftVault();
        vm.expectRevert();
        impl.initialize(
            address(protocolManager),
            address(this),
            bondingCurve,
            address(tokenRegistry),
            EXPIRY_DURATION,
            address(this),
            address(wmon),
            ""
        );
    }

    function test_initialize_revert_doubleInit() public {
        vm.expectRevert();
        vault.initialize(
            address(protocolManager),
            address(this),
            bondingCurve,
            address(tokenRegistry),
            EXPIRY_DURATION,
            address(this),
            address(wmon),
            ""
        );
    }

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(type(IVault).interfaceId), "Should support IVault");
    }

    // ── helpers ────────────────────────────────────────────────────

    function _seedLiquidity(uint256 tokenAmount, uint256 quote) internal {
        creatorFeeToken.mint(address(this), tokenAmount);
        quoteToken.mint(address(this), quote);
        IERC20(address(creatorFeeToken)).transfer(pair, tokenAmount);
        IERC20(address(quoteToken)).transfer(pair, quote);
        INadFunPair(pair).mint(address(this));
    }

    function _encodeTarget(GiftVault.Platform platform, string memory id) internal pure returns (bytes memory) {
        return abi.encode(GiftVault.GiftTarget({platform: platform, id: id}));
    }

    // ── WMON unwrap ─────────────────────────────────────────────────

    function test_initialize_setsWmon() public view {
        assertEq(vault.wmon(), address(wmon), "wmon should be set from initialize");
    }

    /// @notice claim() unwraps and forwards native MON when registered quote == wmon.
    function test_claim_unwrapsWhenQuoteIsWmon() public {
        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), receiver);

        uint256 amount = 10 ether;

        // Fund vault with WMON (simulates afterDeposit accumulation).
        vm.deal(address(this), amount);
        wmon.deposit{value: amount}();
        wmon.transfer(address(vault), amount);
        vault.afterDeposit(address(creatorFeeToken), address(wmon), amount);

        // Override the registered quote so claim() reads wmon.
        vm.mockCall(
            address(tokenRegistry),
            abi.encodeWithSelector(ITokenRegistry.getQuoteToken.selector, address(creatorFeeToken)),
            abi.encode(address(wmon))
        );

        uint256 nativeBefore = receiver.balance;

        vm.prank(receiver);
        vault.claim(address(creatorFeeToken));

        assertEq(receiver.balance - nativeBefore, amount, "receiver should get native MON");
        assertEq(wmon.balanceOf(receiver), 0, "receiver should not get WMON");
        assertEq(wmon.balanceOf(address(vault)), 0, "vault drained");
        GiftVault.GiftInfo memory info = vault.getGiftInfo(address(creatorFeeToken));
        assertEq(info.balance, 0, "gift.balance cleared");
    }

    /// @notice Native transfer failure (receiver reverts in receive) reverts the whole claim.
    function test_claim_revertsWhenNativeTransferFails() public {
        RevertingReceiver bad = new RevertingReceiver();

        vm.prank(relayer);
        vault.setReceiver(address(creatorFeeToken), address(bad));

        uint256 amount = 5 ether;
        vm.deal(address(this), amount);
        wmon.deposit{value: amount}();
        wmon.transfer(address(vault), amount);
        vault.afterDeposit(address(creatorFeeToken), address(wmon), amount);

        vm.mockCall(
            address(tokenRegistry),
            abi.encodeWithSelector(ITokenRegistry.getQuoteToken.selector, address(creatorFeeToken)),
            abi.encode(address(wmon))
        );

        vm.prank(address(bad));
        vm.expectRevert(GiftVault.NativeTransferFailed.selector);
        vault.claim(address(creatorFeeToken));
    }

    /// @notice receive() rejects native sent from any address other than the configured wmon.
    function test_receive_revertsFromNonWmon() public {
        vm.deal(address(this), 1 ether);

        (bool ok, bytes memory ret) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "non-wmon native transfer must fail");
        assertEq(bytes4(ret), GiftVault.UnexpectedNative.selector, "should revert with UnexpectedNative");
    }
}
