// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for ProtocolManager.

import {SetUp} from "../SetUp.t.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract ProtocolManagerTest is SetUp {
    MockERC20 usdc;
    address notAdmin;

    function setUp() public override {
        super.setUp();
        notAdmin = makeAddr("notAdmin");
        usdc = new MockERC20("USDC", "USDC", 6);
    }

    function test_initialize_feeReceiver() public view {
        assertEq(protocolManager.feeReceiver(), feeReceiver);
    }

    function test_initialize_allowedCreatorFeeRates() public view {
        assertTrue(protocolManager.isCreatorFeeRateAllowed(100));
        assertTrue(protocolManager.isCreatorFeeRateAllowed(300));
        assertTrue(protocolManager.isCreatorFeeRateAllowed(500));
        assertFalse(protocolManager.isCreatorFeeRateAllowed(200));
        assertFalse(protocolManager.isCreatorFeeRateAllowed(0));
    }

    function test_initialize_settlementThreshold() public view {
        assertEq(protocolManager.settlementThreshold(address(quoteToken)), settlementThreshold);
    }

    function test_initialize_feesMatchDefaults() public view {
        assertEq(protocolManager.curveProtocolFeeRate(address(quoteToken)), defaultCurveProtocolFee);
        assertEq(protocolManager.dexProtocolFeeRate(address(quoteToken)), defaultDexProtocolFee);
        assertEq(protocolManager.deployFee(address(quoteToken)), defaultDeployFee);
        assertEq(protocolManager.graduateFee(address(quoteToken)), defaultGraduateFee);
    }

    function test_curveProtocolFeeRate_viaAddQuoteToken() public {
        vm.prank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1e9 ether, 800_000_000 ether, 0, 0, 100, 0, 0);
        assertEq(protocolManager.curveProtocolFeeRate(address(usdc)), 100);
    }

    function test_curveProtocolFeeRate_max() public {
        vm.prank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1e9 ether, 800_000_000 ether, 0, 0, 1000, 0, 0);
        assertEq(protocolManager.curveProtocolFeeRate(address(usdc)), 1000);
    }

    function test_curveProtocolFeeRate_exceedsMax_reverts() public {
        vm.prank(admin);
        vm.expectRevert("Protocol fee too high");
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1e9 ether, 800_000_000 ether, 0, 0, 1001, 0, 0);
    }

    function test_dexProtocolFeeRate_viaAddQuoteToken() public {
        vm.prank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1e9 ether, 800_000_000 ether, 0, 0, 0, 70, 0);
        assertEq(protocolManager.dexProtocolFeeRate(address(usdc)), 70);
    }

    function test_dexProtocolFeeRate_exceedsMax_reverts() public {
        vm.prank(admin);
        vm.expectRevert("Dex protocol fee too high");
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1e9 ether, 800_000_000 ether, 0, 0, 0, 1001, 0);
    }

    function test_updateQuoteToken_deployFee() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            0.01 ether,
            defaultGraduateFee,
            0,
            0,
            0
        );
        assertEq(protocolManager.deployFee(address(quoteToken)), 0.01 ether);
    }

    function test_updateQuoteToken_graduateFee() public {
        uint256 updatedGraduateFee = defaultGraduateFee + 1 ether;
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, updatedGraduateFee, 0, 0, 0
        );
        assertEq(protocolManager.graduateFee(address(quoteToken)), updatedGraduateFee);
    }

    function test_setFeeReceiver() public {
        address newReceiver = makeAddr("newReceiver");
        vm.prank(admin);
        protocolManager.setFeeReceiver(newReceiver);
        assertEq(protocolManager.feeReceiver(), newReceiver);
    }

    function test_setFeeReceiver_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert("Zero address");
        protocolManager.setFeeReceiver(address(0));
    }

    function test_setAllowedCreatorFeeRates() public {
        uint16[] memory rates = new uint16[](2);
        rates[0] = 100;
        rates[1] = 200;
        vm.prank(admin);
        protocolManager.setAllowedCreatorFeeRates(rates);
        assertTrue(protocolManager.isCreatorFeeRateAllowed(100));
        assertTrue(protocolManager.isCreatorFeeRateAllowed(200));
        // Previous rates still allowed (additive)
        assertTrue(protocolManager.isCreatorFeeRateAllowed(300));
    }

    function test_setAllowedCreatorFeeRates_allowsMaxRate() public {
        uint16[] memory rates = new uint16[](1);
        rates[0] = 1000;
        vm.prank(admin);
        protocolManager.setAllowedCreatorFeeRates(rates);
        assertTrue(protocolManager.isCreatorFeeRateAllowed(1000));
    }

    function test_setAllowedCreatorFeeRates_exceedsMax_reverts() public {
        uint16[] memory rates = new uint16[](1);
        rates[0] = 1001;
        vm.prank(admin);
        vm.expectRevert("Creator fee too high");
        protocolManager.setAllowedCreatorFeeRates(rates);
    }

    function test_removeCreatorFeeRate() public {
        vm.prank(admin);
        protocolManager.removeCreatorFeeRate(500);
        assertFalse(protocolManager.isCreatorFeeRateAllowed(500));
        assertTrue(protocolManager.isCreatorFeeRateAllowed(100));
    }

    function test_setSettlementThreshold() public {
        vm.prank(admin);
        protocolManager.setSettlementThreshold(address(quoteToken), 2_000_000 ether);
        assertEq(protocolManager.settlementThreshold(address(quoteToken)), 2_000_000 ether);
    }

    function test_setSnipingPenaltyTable_allowsMax100Percent() public {
        uint256[] memory table = new uint256[](2);
        table[0] = 10_000;
        table[1] = 5_000;

        vm.prank(admin);
        protocolManager.setSnipingPenaltyTable(table);

        assertEq(protocolManager.snipingPenaltyTableLength(), 2);
        assertEq(protocolManager.snipingPenaltyAt(0), 10_000);
        assertEq(protocolManager.snipingPenaltyAt(1), 5_000);
        assertEq(protocolManager.snipingPenaltyAt(2), 0);
    }

    function test_setSnipingPenaltyTable_revertsAbove100Percent() public {
        uint256[] memory table = new uint256[](1);
        table[0] = 10_001;

        vm.prank(admin);
        vm.expectRevert("Penalty exceeds BPS");
        protocolManager.setSnipingPenaltyTable(table);
    }

    // NOTE: quoteToken (WMON 18 decimals) is already registered by SetUp
    function test_addQuoteToken() public {
        vm.prank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1e9 ether, 200_000_000 ether, 0, 0, 0, 0, 0);
        assertTrue(protocolManager.isAllowed(address(usdc)));
        assertEq(protocolManager.getDecimals(address(usdc)), 6);
        assertEq(protocolManager.getVirtualReserve(address(usdc)), 15_000e6);
    }

    function test_addQuoteToken_usdc6decimals() public {
        vm.prank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1e9 ether, 200_000_000 ether, 0, 0, 0, 0, 0);
        assertEq(protocolManager.getDecimals(address(usdc)), 6);
        assertEq(protocolManager.getVirtualReserve(address(usdc)), 15_000e6);
    }

    function test_addQuoteToken_revertDuplicate() public {
        vm.startPrank(admin);
        // quoteToken already added by SetUp, so adding again should revert
        vm.expectRevert(IProtocolManager.QuoteTokenAlreadyAdded.selector);
        protocolManager.addQuoteToken(address(quoteToken), 5 ether, 1e9 ether, 200_000_000 ether, 0, 0, 0, 0, 0);
        vm.stopPrank();
    }

    function test_addQuoteToken_revertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IProtocolManager.ZeroAddress.selector);
        protocolManager.addQuoteToken(address(0), 5 ether, 1e9 ether, 200_000_000 ether, 0, 0, 0, 0, 0);
    }

    function test_addQuoteToken_revertZeroVirtualReserve() public {
        vm.prank(admin);
        vm.expectRevert("Zero virtual quote reserve");
        protocolManager.addQuoteToken(address(usdc), 0, 1e9 ether, 200_000_000 ether, 0, 0, 0, 0, 0);
    }

    function test_addQuoteToken_revertZeroVirtualTokenReserve() public {
        vm.prank(admin);
        vm.expectRevert("Zero virtual token reserve");
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 0, 0, 0, 0, 0, 0, 0);
    }

    function test_addQuoteToken_revertInvalidMinTokenReserve() public {
        vm.prank(admin);
        vm.expectRevert("Invalid min token reserve");
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1e9 ether, 1e9 ether, 0, 0, 0, 0, 0);
    }

    function test_addQuoteToken_revertsInvalidGraduationSupply() public {
        vm.prank(admin);
        vm.expectRevert("Invalid graduation supply");
        protocolManager.addQuoteToken(address(usdc), 100 ether, 2_000_000_000 ether, 1_200_000_000 ether, 0, 0, 0, 0, 0);
    }

    function test_removeQuoteToken() public {
        vm.startPrank(admin);
        // quoteToken already added by SetUp
        protocolManager.removeQuoteToken(address(quoteToken));
        assertFalse(protocolManager.isAllowed(address(quoteToken)));
        vm.stopPrank();
    }

    function test_updateQuoteToken() public {
        vm.startPrank(admin);
        // quoteToken already added by SetUp
        protocolManager.updateQuoteToken(
            address(quoteToken), 10 ether, 1e9 ether, 900_000_000 ether, 0.01 ether, 0.5 ether, 0, 0, 0
        );
        assertEq(protocolManager.getVirtualReserve(address(quoteToken)), 10 ether);
        assertEq(protocolManager.getMinTokenReserve(address(quoteToken)), 900_000_000 ether);
        assertEq(protocolManager.deployFee(address(quoteToken)), 0.01 ether);
        assertEq(protocolManager.graduateFee(address(quoteToken)), 0.5 ether);
        vm.stopPrank();
    }

    function test_updateQuoteToken_revertZeroVirtualReserve() public {
        vm.prank(admin);
        vm.expectRevert("Zero virtual quote reserve");
        protocolManager.updateQuoteToken(address(quoteToken), 0, virtualTokenReserve, minTokenReserve, 0, 0, 0, 0, 0);
    }

    function test_updateQuoteToken_revertZeroVirtualTokenReserve() public {
        vm.prank(admin);
        vm.expectRevert("Zero virtual token reserve");
        protocolManager.updateQuoteToken(address(quoteToken), virtualReserve, 0, 0, 0, 0, 0, 0, 0);
    }

    function test_updateQuoteToken_revertInvalidMinTokenReserve() public {
        vm.prank(admin);
        vm.expectRevert("Invalid min token reserve");
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, virtualTokenReserve, 0, 0, 0, 0, 0
        );
    }

    function test_updateQuoteToken_revertsInvalidGraduationSupply() public {
        vm.prank(admin);
        vm.expectRevert("Invalid graduation supply");
        protocolManager.updateQuoteToken(
            address(quoteToken), 100 ether, 2_000_000_000 ether, 1_200_000_000 ether, 0, 0, 0, 0, 0
        );
    }

    function test_getConfig() public view {
        // quoteToken already added by SetUp
        IProtocolManager.QuoteConfig memory config = protocolManager.getConfig(address(quoteToken));
        assertEq(config.decimals, 18);
        assertEq(config.virtualReserve, virtualReserve);
        assertEq(config.virtualTokenReserve, virtualTokenReserve);
        assertEq(config.minTokenReserve, minTokenReserve);
        assertEq(config.v3FeeTier, DEFAULT_V3_FEE_TIER);
        assertEq(config.lpFeeProtocolShareBps, DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS);
        assertTrue(config.active);
    }

    function test_isAllowed_returnsFalseForUnknown() public view {
        assertFalse(protocolManager.isAllowed(address(0x1234)));
    }

    function test_onlyOwner_updateQuoteToken() public {
        vm.prank(notAdmin);
        vm.expectRevert();
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, 0, 100, 0, 0
        );
    }

    function test_onlyOwner_setAllowedCreatorFeeRates() public {
        uint16[] memory rates = new uint16[](1);
        rates[0] = 100;
        vm.prank(notAdmin);
        vm.expectRevert();
        protocolManager.setAllowedCreatorFeeRates(rates);
    }

    function test_onlyOwner_addQuoteToken() public {
        vm.prank(notAdmin);
        vm.expectRevert();
        protocolManager.addQuoteToken(address(usdc), 5 ether, 1e9 ether, 200_000_000 ether, 0, 0, 0, 0, 0);
    }

    function test_onlyOwner_setSettlementThreshold() public {
        vm.prank(notAdmin);
        vm.expectRevert();
        protocolManager.setSettlementThreshold(address(quoteToken), 1 ether);
    }
}
