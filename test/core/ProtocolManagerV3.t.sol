// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract ProtocolManagerV3Test is SetUp {
    event V3QuoteConfigUpdate(address indexed quoteToken, uint24 v3FeeTier, uint16 lpFeeProtocolShareBps);

    MockERC20 private secondQuoteToken;

    function setUp() public override {
        super.setUp();
        secondQuoteToken = new MockERC20("USDC", "USDC", 6);
    }

    function test_addQuoteToken_storesV3FeeTierAndLpProtocolShare() public {
        vm.startPrank(admin);
        _addSecondQuoteToken();
        protocolManager.setV3QuoteConfig(address(secondQuoteToken), 10_000, 5_000);
        vm.stopPrank();

        IProtocolManager.QuoteConfig memory config = protocolManager.getConfig(address(secondQuoteToken));
        assertEq(config.v3FeeTier, 10_000);
        assertEq(config.lpFeeProtocolShareBps, 5_000);
        assertTrue(config.active);
        assertEq(protocolManager.v3FeeTier(address(secondQuoteToken)), 10_000);
        assertEq(protocolManager.lpFeeProtocolShareBps(address(secondQuoteToken)), 5_000);
    }

    function test_addQuoteToken_revertsWhenLpProtocolShareExceedsBps() public {
        vm.startPrank(admin);
        _addSecondQuoteToken();
        vm.expectRevert(IProtocolManager.InvalidLpFeeShare.selector);
        protocolManager.setV3QuoteConfig(address(secondQuoteToken), 10_000, 10_001);
        vm.stopPrank();
    }

    function test_addQuoteToken_revertsWhenFeeTierIsZero() public {
        vm.startPrank(admin);
        _addSecondQuoteToken();
        vm.expectRevert(IProtocolManager.InvalidFeeTier.selector);
        protocolManager.setV3QuoteConfig(address(secondQuoteToken), 0, 5_000);
        vm.stopPrank();
    }

    function test_setV3QuoteConfig_onlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        protocolManager.setV3QuoteConfig(address(quoteToken), 3_000, 5_000);
    }

    function test_setV3QuoteConfig_revertsForUnregisteredQuoteToken() public {
        vm.prank(admin);
        vm.expectRevert("Not active");
        protocolManager.setV3QuoteConfig(address(secondQuoteToken), 3_000, 5_000);
    }

    function test_setV3QuoteConfig_revertsForInactiveQuoteToken() public {
        vm.startPrank(admin);
        protocolManager.removeQuoteToken(address(quoteToken));
        vm.expectRevert("Not active");
        protocolManager.setV3QuoteConfig(address(quoteToken), 3_000, 5_000);
        vm.stopPrank();
    }

    function test_setV3QuoteConfig_allowsBoundaryShares() public {
        vm.startPrank(admin);
        protocolManager.setV3QuoteConfig(address(quoteToken), 3_000, 0);
        assertEq(protocolManager.lpFeeProtocolShareBps(address(quoteToken)), 0);

        protocolManager.setV3QuoteConfig(address(quoteToken), 3_000, 10_000);
        assertEq(protocolManager.lpFeeProtocolShareBps(address(quoteToken)), 10_000);
        vm.stopPrank();
    }

    function test_setV3QuoteConfig_overwritesExistingValues() public {
        vm.startPrank(admin);
        protocolManager.setV3QuoteConfig(address(quoteToken), 500, 1_000);
        protocolManager.setV3QuoteConfig(address(quoteToken), 10_000, 7_500);
        vm.stopPrank();

        assertEq(protocolManager.v3FeeTier(address(quoteToken)), 10_000);
        assertEq(protocolManager.lpFeeProtocolShareBps(address(quoteToken)), 7_500);
    }

    function test_setV3QuoteConfig_isIsolatedPerQuoteToken() public {
        vm.startPrank(admin);
        _addSecondQuoteToken();
        protocolManager.setV3QuoteConfig(address(quoteToken), 500, 2_500);
        protocolManager.setV3QuoteConfig(address(secondQuoteToken), 10_000, 7_500);
        vm.stopPrank();

        assertEq(protocolManager.v3FeeTier(address(quoteToken)), 500);
        assertEq(protocolManager.lpFeeProtocolShareBps(address(quoteToken)), 2_500);
        assertEq(protocolManager.v3FeeTier(address(secondQuoteToken)), 10_000);
        assertEq(protocolManager.lpFeeProtocolShareBps(address(secondQuoteToken)), 7_500);
    }

    function test_setV3QuoteConfig_emitsConfiguration() public {
        vm.expectEmit(true, false, false, true, address(protocolManager));
        emit V3QuoteConfigUpdate(address(quoteToken), 3_000, 5_000);

        vm.prank(admin);
        protocolManager.setV3QuoteConfig(address(quoteToken), 3_000, 5_000);
    }

    function _addSecondQuoteToken() private {
        protocolManager.addQuoteToken(
            address(secondQuoteToken), 30 ether, 1_000_000_000 ether, 200_000_000 ether, 1 ether, 5 ether, 100, 0, 0
        );
    }
}
