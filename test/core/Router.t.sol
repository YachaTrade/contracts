// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for Router.

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";

contract BondingCurveAdminTest is SetUp {
    function setUp() public override {
        super.setUp();

        // Grant ROUTER_ROLE to test contract for direct bondingCurve.create() calls
        bytes32 routerRole = bondingCurve.ROUTER_ROLE();
        vm.prank(admin);
        bondingCurve.grantRole(routerRole, address(this));
    }

    function test_initialize() public view {
        assertFalse(bondingCurve.isHalted());
    }

    function test_createToken() public {
        address token = _createToken();

        assertNotEq(token, address(0));

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertEq(info.creator, creator);
        assertEq(info.quoteToken, address(quoteToken));
        assertEq(
            info.virtualQuoteReserve,
            info.initialQuoteReserve,
            "Initial virtualQuoteReserve should equal initialQuoteReserve"
        );
        assertEq(info.virtualTokenReserve, info.initialTokenReserve);
        assertFalse(info.graduated);
        assertGt(info.createdAtBlock, 0, "createdAtBlock should be set");
    }

    function test_halt() public {
        vm.prank(admin);
        bondingCurve.halt(true);
        assertTrue(bondingCurve.isHalted());

        vm.expectRevert(IBondingCurve.ProtocolHalted.selector);
        bondingCurve.create(_defaultParams());
    }

    function test_halt_revertsForNonGuardian() public {
        vm.prank(user1);
        vm.expectRevert();
        bondingCurve.halt(true);
    }

    function test_setModule() public {
        bytes32 moduleId = keccak256("CREATOR_FEE_MODULE");
        address module = makeAddr("creatorFeeModule");
        vm.prank(admin);
        bondingCurve.setModule(moduleId, module);
    }

    function test_setModule_revertsForZeroModule() public {
        vm.prank(admin);
        vm.expectRevert(IBondingCurve.ZeroModule.selector);
        bondingCurve.setModule(keccak256("CREATOR_FEE_MODULE"), address(0));
    }

    function test_setModule_revertsWhenAlreadySet() public {
        bytes32 moduleId = keccak256("FEE_COLLECTOR");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.ModuleAlreadySet.selector, moduleId));
        bondingCurve.setModule(moduleId, makeAddr("newFeeCollector"));
    }

    function test_setModule_revertsForNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        bondingCurve.setModule(keccak256("CREATOR_FEE_MODULE"), makeAddr("creatorFeeModule"));
    }

    function test_createToken_revertsWithDisallowedQuoteToken() public {
        IBondingCurve.CreateTokenParams memory params = _defaultParams();
        params.quoteToken = makeAddr("unknownQuote");

        vm.expectRevert("Quote token not allowed");
        bondingCurve.create(params);
    }
}
