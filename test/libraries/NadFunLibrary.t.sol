// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NadFunLibrary} from "../../src/libraries/NadFunLibrary.sol";

/// @dev Thin wrapper so we can call internal library functions and expect reverts.
contract LibHarness {
    function sortTokens(address a, address b) external pure returns (address, address) {
        return NadFunLibrary.sortTokens(a, b);
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256) {
        return NadFunLibrary.quote(amountA, reserveA, reserveB);
    }
}

contract NadFunLibraryTest is Test {
    LibHarness harness;

    function setUp() public {
        harness = new LibHarness();
    }

    function test_sortTokens_ordersByAddress() public view {
        address lo = address(0x1);
        address hi = address(0x2);
        (address t0, address t1) = harness.sortTokens(hi, lo);
        assertEq(t0, lo);
        assertEq(t1, hi);
    }

    function test_sortTokens_revertsOnIdentical() public {
        vm.expectRevert(NadFunLibrary.IdenticalAddresses.selector);
        harness.sortTokens(address(0x1), address(0x1));
    }

    function test_sortTokens_revertsOnZero() public {
        vm.expectRevert(NadFunLibrary.ZeroAddress.selector);
        harness.sortTokens(address(0), address(0x1));
    }

    function test_quote_proportional() public view {
        assertEq(harness.quote(100, 1000, 5000), 500);
    }

    function test_quote_revertsOnZeroAmount() public {
        vm.expectRevert(NadFunLibrary.InsufficientAmount.selector);
        harness.quote(0, 1000, 5000);
    }

    function test_quote_revertsOnZeroReserve() public {
        vm.expectRevert(NadFunLibrary.InsufficientLiquidity.selector);
        harness.quote(100, 0, 5000);
    }
}
