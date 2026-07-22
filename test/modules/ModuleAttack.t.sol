// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for ModuleAttack.

import {SetUp} from "../SetUp.t.sol";

/// @notice ProtocolManager extreme-fee and authorization regression tests.
contract ModuleAttackTest is SetUp {
    function setUp() public override {
        super.setUp();
        // Grant ROUTER_ROLE to creator for direct bondingCurve.create() calls in tests
        bytes32 routerRole = bondingCurve.ROUTER_ROLE();
        vm.prank(admin);
        bondingCurve.grantRole(routerRole, creator);
    }

    /// @notice protocolFee beyond max (1000 = 10%) -> revert
    function test_attack_feeManagerExtremeFees_blocksCreation() public {
        vm.startPrank(admin);
        // 10% -> allowed
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 1000, 0
        );
        assertEq(protocolManager.curveProtocolFeeRate(address(quoteToken)), 1000);

        // 10.01% -> revert
        vm.expectRevert("Protocol fee too high");
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 1001, 0
        );

        // dexProtocolFee 10% -> allowed
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 1000, 1000
        );
        assertEq(protocolManager.dexProtocolFeeRate(address(quoteToken)), 1000);

        // dexProtocolFee 10.01% -> revert
        vm.expectRevert("Dex protocol fee too high");
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 0, 1001
        );
        vm.stopPrank();

        // Caller without operator permission -> revert
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, 0, 0, 0
        );
    }
}
