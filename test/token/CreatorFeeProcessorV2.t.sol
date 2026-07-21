// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for CreatorFeeProcessorV2.

import {Test} from "forge-std/Test.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ICreatorFeeProcessor} from "../../src/interfaces/ICreatorFeeProcessor.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract SelectiveTaxQuoteToken is ERC20 {
    address public taxedSender;
    uint16 public taxBps;

    constructor() ERC20("Selective Tax Quote", "STQ") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureTax(address taxedSender_, uint16 taxBps_) external {
        taxedSender = taxedSender_;
        taxBps = taxBps_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == taxedSender && from != address(0) && to != address(0) && taxBps != 0) {
            uint256 tax = amount * taxBps / 10_000;
            super._update(from, to, amount - tax);
            super._update(from, address(0xdead), tax);
            return;
        }
        super._update(from, to, amount);
    }
}

contract MockVaultV2 is IVault {
    uint256 public totalReceived;
    bool public shouldRevert;

    address public lastToken;
    address public lastQuoteToken;
    uint256 public lastAmount;
    uint256 public callCount;

    function afterDeposit(address token, address quoteToken, uint256 amount) external {
        if (shouldRevert) revert("MockVaultV2: revert");
        totalReceived += amount;
        lastToken = token;
        lastQuoteToken = quoteToken;
        lastAmount = amount;
        callCount++;
    }

    function setup(address, bytes calldata) external {}

    function setRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract CreatorFeeProcessorV2Test is Test {
    ProtocolManager protocolManager;
    CreatorFeeProcessor processor;
    MockERC20 quoteToken;

    address admin = makeAddr("admin");
    address bondingCurve = makeAddr("bondingCurve");
    address lpManager = makeAddr("lpManager");
    address token = makeAddr("token");

    MockVaultV2 vault1;
    MockVaultV2 vault2;
    MockVaultV2 vault3;

    function setUp() public {
        quoteToken = new MockERC20("Quote", "QT", 18);
        vault1 = new MockVaultV2();
        vault2 = new MockVaultV2();
        vault3 = new MockVaultV2();

        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()),
                    abi.encodeCall(ProtocolManager.initialize, (admin, makeAddr("feeReceiver")))
                )
            )
        );
        processor = new CreatorFeeProcessor(address(protocolManager));

        vm.startPrank(admin);
        protocolManager.setOperatorPermission(
            bondingCurve, address(processor), ICreatorFeeProcessor.setup.selector, true
        );
        protocolManager.setOperatorPermission(
            lpManager, address(processor), ICreatorFeeProcessor.processCreatorFee.selector, true
        );
        vm.stopPrank();

        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](3);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(vault1), bps: 3000});
        vaults[1] = ICreatorFeeProcessor.VaultSlot({vault: address(vault2), bps: 3000});
        vaults[2] = ICreatorFeeProcessor.VaultSlot({vault: address(vault3), bps: 4000});

        vm.prank(bondingCurve);
        processor.setup(token, vaults);
    }

    function _processCreatorFeeAsLPManager(uint256 amount) internal {
        quoteToken.mint(lpManager, amount);
        vm.startPrank(lpManager);
        quoteToken.approve(address(processor), amount);
        processor.processCreatorFee(token, address(quoteToken), amount);
        vm.stopPrank();
    }

    function test_setup_configuresVaults() public view {
        assertEq(processor.vaultCount(token), 3);

        ICreatorFeeProcessor.VaultSlot[] memory vaults = processor.getVaults(token);
        assertEq(vaults[0].vault, address(vault1));
        assertEq(vaults[0].bps, 3000);
        assertEq(vaults[1].vault, address(vault2));
        assertEq(vaults[1].bps, 3000);
        assertEq(vaults[2].vault, address(vault3));
        assertEq(vaults[2].bps, 4000);
    }

    function test_protocolManagerInterface_exposesCanCall() public view {
        (bool allowed, uint32 delay) = IProtocolManager(address(protocolManager))
            .canCall(bondingCurve, address(processor), ICreatorFeeProcessor.setup.selector);

        assertTrue(allowed);
        assertEq(delay, 0);
    }

    function test_setup_onlyBondingCurvePermission() public {
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](1);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(vault1), bps: 10000});

        vm.prank(admin);
        protocolManager.setOperatorPermission(
            lpManager, address(p), ICreatorFeeProcessor.processCreatorFee.selector, true
        );

        vm.prank(lpManager);
        vm.expectRevert(ICreatorFeeProcessor.NotAuthorized.selector);
        p.setup(token, vaults);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(ICreatorFeeProcessor.NotAuthorized.selector);
        p.setup(token, vaults);

        vm.prank(admin);
        protocolManager.setOperatorPermission(bondingCurve, address(p), ICreatorFeeProcessor.setup.selector, true);
        vm.prank(bondingCurve);
        p.setup(token, vaults);

        assertEq(p.vaultCount(token), 1);
    }

    function test_setup_revertsOnDuplicate() public {
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](1);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(vault1), bps: 10000});

        vm.prank(bondingCurve);
        vm.expectRevert(ICreatorFeeProcessor.AlreadyConfigured.selector);
        processor.setup(token, vaults);
    }

    function test_setup_bpsSumMustBe10000() public {
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](2);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(vault1), bps: 3000});
        vaults[1] = ICreatorFeeProcessor.VaultSlot({vault: address(vault2), bps: 3000}); // total 6000

        vm.prank(admin);
        vm.expectRevert(ICreatorFeeProcessor.InvalidBpsTotal.selector);
        p.setup(makeAddr("token2"), vaults);
    }

    function test_setup_maxFiveVaults() public {
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](6);
        for (uint256 i = 0; i < 6; i++) {
            vaults[i] = ICreatorFeeProcessor.VaultSlot({vault: makeAddr(string(abi.encodePacked("v", i))), bps: 1667});
        }

        vm.prank(admin);
        vm.expectRevert(ICreatorFeeProcessor.TooManyVaults.selector);
        p.setup(makeAddr("token3"), vaults);
    }

    function test_setup_revertsOnNoVaults() public {
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](0);

        vm.prank(admin);
        vm.expectRevert(ICreatorFeeProcessor.NoVaults.selector);
        p.setup(makeAddr("token4"), vaults);
    }

    function test_setup_revertsOnZeroBps() public {
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](2);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(vault1), bps: 10000});
        vaults[1] = ICreatorFeeProcessor.VaultSlot({vault: address(vault2), bps: 0});

        vm.prank(admin);
        vm.expectRevert(ICreatorFeeProcessor.ZeroBps.selector);
        p.setup(makeAddr("token5"), vaults);
    }

    function test_setup_revertsOnZeroAddress() public {
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](1);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(0), bps: 10000});

        vm.prank(admin);
        vm.expectRevert(ICreatorFeeProcessor.ZeroAddress.selector);
        p.setup(makeAddr("token6"), vaults);
    }

    function test_setup_emitsEvent() public {
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](1);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(vault1), bps: 10000});

        vm.expectEmit(true, false, false, true);
        emit ICreatorFeeProcessor.Setup(makeAddr("token7"), vaults);

        vm.prank(admin);
        p.setup(makeAddr("token7"), vaults);
    }

    function test_processCreatorFee_distributesToVaults() public {
        uint256 amount = 100 ether;
        _processCreatorFeeAsLPManager(amount);

        uint256 expectedV1 = (amount * 3000) / 10_000; // 30 ether
        uint256 expectedV2 = (amount * 3000) / 10_000; // 30 ether
        uint256 expectedV3 = amount - expectedV1 - expectedV2; // 40 ether (remainder)

        assertEq(quoteToken.balanceOf(address(vault1)), expectedV1);
        assertEq(quoteToken.balanceOf(address(vault2)), expectedV2);
        assertEq(quoteToken.balanceOf(address(vault3)), expectedV3);
    }

    function test_processCreatorFee_correctBpsAllocation() public {
        uint256 amount = 1_000_000 ether;
        _processCreatorFeeAsLPManager(amount);

        // 30% = 300_000 ether, 30% = 300_000 ether, 40% = 400_000 ether
        assertEq(quoteToken.balanceOf(address(vault1)), 300_000 ether);
        assertEq(quoteToken.balanceOf(address(vault2)), 300_000 ether);
        assertEq(quoteToken.balanceOf(address(vault3)), 400_000 ether);
    }

    function test_processCreatorFee_lastVaultGetsDust() public {
        address token2 = makeAddr("token2");
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));

        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](3);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(vault1), bps: 3333});
        vaults[1] = ICreatorFeeProcessor.VaultSlot({vault: address(vault2), bps: 3333});
        vaults[2] = ICreatorFeeProcessor.VaultSlot({vault: address(vault3), bps: 3334});

        vm.prank(admin);
        p.setup(token2, vaults);

        uint256 amount = 100 ether;
        quoteToken.mint(admin, amount);

        vm.startPrank(admin);
        quoteToken.approve(address(p), amount);
        p.processCreatorFee(token2, address(quoteToken), amount);
        vm.stopPrank();

        // vault1: 100 * 3333 / 10000 = 33.33 ether
        // vault2: 100 * 3333 / 10000 = 33.33 ether
        // vault3: 100 - 33.33 - 33.33 = 33.34 ether (remainder)
        uint256 v1 = quoteToken.balanceOf(address(vault1));
        uint256 v2 = quoteToken.balanceOf(address(vault2));
        uint256 v3 = quoteToken.balanceOf(address(vault3));

        // Total must equal the original amount exactly (no dust lost)
        assertEq(v1 + v2 + v3, amount, "Rounding dust lost");

        // Last vault gets slightly more due to remainder logic
        assertGe(v3, v1, "Last vault should get remainder");
    }

    function test_processCreatorFee_callsAfterDeposit() public {
        uint256 amount = 100 ether;
        _processCreatorFeeAsLPManager(amount);

        uint256 expectedV1 = (amount * 3000) / 10_000;
        uint256 expectedV2 = (amount * 3000) / 10_000;
        uint256 expectedV3 = amount - expectedV1 - expectedV2;

        // afterDeposit callback should track amounts
        assertEq(vault1.totalReceived(), expectedV1);
        assertEq(vault2.totalReceived(), expectedV2);
        assertEq(vault3.totalReceived(), expectedV3);

        // Verify callback parameters
        assertEq(vault1.lastToken(), token);
        assertEq(vault1.lastQuoteToken(), address(quoteToken));
        assertEq(vault1.lastAmount(), expectedV1);
        assertEq(vault1.callCount(), 1);
    }

    function test_processCreatorFee_afterDepositFailure_reverts() public {
        uint256 amount = 100 ether;

        // Make vault2 revert on afterDeposit
        vault2.setRevert(true);

        quoteToken.mint(lpManager, amount);
        vm.startPrank(lpManager);
        quoteToken.approve(address(processor), amount);
        vm.expectRevert("MockVaultV2: revert");
        processor.processCreatorFee(token, address(quoteToken), amount);
        vm.stopPrank();

        assertEq(quoteToken.balanceOf(address(vault1)), 0);
        assertEq(quoteToken.balanceOf(address(vault2)), 0);
        assertEq(quoteToken.balanceOf(address(vault3)), 0);
        assertEq(vault1.totalReceived(), 0);
        assertEq(vault2.totalReceived(), 0);
        assertEq(vault3.totalReceived(), 0);
        assertEq(quoteToken.balanceOf(lpManager), amount);
        assertEq(quoteToken.balanceOf(address(processor)), 0);
    }

    function test_processCreatorFee_onlyLPManagerPermission() public {
        quoteToken.mint(bondingCurve, 100 ether);
        vm.startPrank(bondingCurve);
        quoteToken.approve(address(processor), 100 ether);
        vm.expectRevert(ICreatorFeeProcessor.NotAuthorized.selector);
        processor.processCreatorFee(token, address(quoteToken), 100 ether);
        vm.stopPrank();

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(ICreatorFeeProcessor.NotAuthorized.selector);
        processor.processCreatorFee(token, address(quoteToken), 100 ether);

        _processCreatorFeeAsLPManager(100 ether);
        assertEq(quoteToken.balanceOf(address(vault1)), 30 ether);
    }

    function test_processCreatorFee_zeroAmount_noOp() public {
        vm.prank(lpManager);
        processor.processCreatorFee(token, address(quoteToken), 0);
        // Should not revert, no transfers should happen
        assertEq(quoteToken.balanceOf(address(vault1)), 0);
        assertEq(quoteToken.balanceOf(address(vault2)), 0);
        assertEq(quoteToken.balanceOf(address(vault3)), 0);
    }

    function test_processCreatorFee_emitsCreatorFeeProcessedEvent() public {
        uint256 amount = 50 ether;
        quoteToken.mint(lpManager, amount);

        vm.startPrank(lpManager);
        quoteToken.approve(address(processor), amount);

        vm.expectEmit(true, true, false, true);
        emit ICreatorFeeProcessor.Distribute(token, address(vault1), (amount * 3000) / 10_000);
        processor.processCreatorFee(token, address(quoteToken), amount);
        vm.stopPrank();
    }

    function test_processCreatorFee_emitsVaultDistributedEvents() public {
        uint256 amount = 100 ether;
        quoteToken.mint(lpManager, amount);

        uint256 expectedV1 = (amount * 3000) / 10_000;

        vm.startPrank(lpManager);
        quoteToken.approve(address(processor), amount);

        vm.expectEmit(true, false, false, true);
        emit ICreatorFeeProcessor.Distribute(token, address(vault1), expectedV1);
        processor.processCreatorFee(token, address(quoteToken), amount);
        vm.stopPrank();
    }

    function test_processCreatorFee_singleVault() public {
        address token2 = makeAddr("singleVaultToken");
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));

        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](1);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(vault1), bps: 10000});

        vm.prank(admin);
        p.setup(token2, vaults);

        uint256 amount = 200 ether;
        quoteToken.mint(admin, amount);

        vm.startPrank(admin);
        quoteToken.approve(address(p), amount);
        p.processCreatorFee(token2, address(quoteToken), amount);
        vm.stopPrank();

        // Single vault gets 100%
        assertEq(quoteToken.balanceOf(address(vault1)), amount);
        assertEq(vault1.totalReceived(), amount);
    }

    function test_processCreatorFee_noResidualBalance() public {
        uint256 amount = 100 ether;
        _processCreatorFeeAsLPManager(amount);

        // CreatorFeeProcessor should have zero balance after distribution
        assertEq(quoteToken.balanceOf(address(processor)), 0);
    }

    function test_processCreatorFee_protocolManagerOwnerOverride() public {
        address ownerToken = makeAddr("ownerToken");
        CreatorFeeProcessor p = new CreatorFeeProcessor(address(protocolManager));
        ICreatorFeeProcessor.VaultSlot[] memory vaults = new ICreatorFeeProcessor.VaultSlot[](1);
        vaults[0] = ICreatorFeeProcessor.VaultSlot({vault: address(vault1), bps: 10_000});

        vm.startPrank(admin);
        p.setup(ownerToken, vaults);
        quoteToken.mint(admin, 50 ether);
        quoteToken.approve(address(p), 50 ether);
        p.processCreatorFee(ownerToken, address(quoteToken), 50 ether);
        vm.stopPrank();

        assertEq(quoteToken.balanceOf(address(vault1)), 50 ether);
    }

    function test_processCreatorFee_revertsAndRollsBackTaxedPull() public {
        SelectiveTaxQuoteToken taxedQuoteToken = new SelectiveTaxQuoteToken();
        uint256 donation = 7 ether;
        uint256 amount = 100 ether;
        taxedQuoteToken.mint(address(processor), donation);
        taxedQuoteToken.mint(lpManager, amount);
        taxedQuoteToken.configureTax(lpManager, 1_000);

        vm.startPrank(lpManager);
        taxedQuoteToken.approve(address(processor), amount);
        vm.expectPartialRevert(ICreatorFeeProcessor.InvalidBalanceDelta.selector);
        processor.processCreatorFee(token, address(taxedQuoteToken), amount);
        vm.stopPrank();

        assertEq(taxedQuoteToken.balanceOf(lpManager), amount);
        assertEq(taxedQuoteToken.balanceOf(address(processor)), donation);
        assertEq(taxedQuoteToken.balanceOf(address(vault1)), 0);
        assertEq(taxedQuoteToken.balanceOf(address(vault2)), 0);
        assertEq(taxedQuoteToken.balanceOf(address(vault3)), 0);
    }

    function test_processCreatorFee_revertsAndRollsBackShortCreditToVault() public {
        SelectiveTaxQuoteToken taxedQuoteToken = new SelectiveTaxQuoteToken();
        uint256 donation = 7 ether;
        uint256 amount = 100 ether;
        taxedQuoteToken.mint(address(processor), donation);
        taxedQuoteToken.mint(lpManager, amount);
        taxedQuoteToken.configureTax(address(processor), 1_000);

        vm.startPrank(lpManager);
        taxedQuoteToken.approve(address(processor), amount);
        vm.expectPartialRevert(ICreatorFeeProcessor.InvalidBalanceDelta.selector);
        processor.processCreatorFee(token, address(taxedQuoteToken), amount);
        vm.stopPrank();

        assertEq(taxedQuoteToken.balanceOf(lpManager), amount);
        assertEq(taxedQuoteToken.balanceOf(address(processor)), donation);
        assertEq(taxedQuoteToken.balanceOf(address(vault1)), 0);
        assertEq(taxedQuoteToken.balanceOf(address(vault2)), 0);
        assertEq(taxedQuoteToken.balanceOf(address(vault3)), 0);
        assertEq(vault1.callCount(), 0);
    }

    function test_processCreatorFee_preservesPreexistingDonation() public {
        uint256 donation = 7 ether;
        quoteToken.mint(address(processor), donation);

        _processCreatorFeeAsLPManager(100 ether);

        assertEq(quoteToken.balanceOf(address(processor)), donation);
    }

    function test_constructor_revertsOnNonContractProtocolManager() public {
        vm.expectRevert(ICreatorFeeProcessor.InvalidProtocolManager.selector);
        new CreatorFeeProcessor(address(0));

        vm.expectRevert(ICreatorFeeProcessor.InvalidProtocolManager.selector);
        new CreatorFeeProcessor(makeAddr("notProtocolManager"));
    }

    function test_constructor_setsImmutableProtocolManager() public view {
        assertEq(address(processor.protocolManager()), address(protocolManager));
    }
}
