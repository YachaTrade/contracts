// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WrappedEther} from "../../src/token/WrappedEther.sol";

contract WrappedEtherTest is Test {
    WrappedEther internal weth;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        weth = new WrappedEther();
        vm.deal(alice, 100 ether);
    }

    function test_depositAndReceiveMintOneToOne() public {
        vm.prank(alice);
        weth.deposit{value: 3 ether}();
        vm.prank(alice);
        (bool ok,) = address(weth).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(weth.balanceOf(alice), 5 ether);
        assertEq(weth.totalSupply(), 5 ether);
        assertEq(address(weth).balance, 5 ether);
    }

    function test_withdrawBurnsBeforeReturningNative() public {
        vm.prank(alice);
        weth.deposit{value: 5 ether}();
        uint256 nativeBefore = alice.balance;
        vm.prank(alice);
        weth.withdraw(2 ether);
        assertEq(weth.balanceOf(alice), 3 ether);
        assertEq(alice.balance, nativeBefore + 2 ether);
        assertEq(weth.totalSupply(), address(weth).balance);
    }

    function test_transferAndTransferFromPreserveBacking() public {
        vm.prank(alice);
        weth.deposit{value: 5 ether}();
        vm.prank(alice);
        weth.approve(bob, 2 ether);
        vm.prank(bob);
        weth.transferFrom(alice, bob, 2 ether);
        assertEq(weth.balanceOf(bob), 2 ether);
        assertEq(weth.totalSupply(), address(weth).balance);
    }

    function test_withdrawAboveBalanceRevertsWithoutChangingBacking() public {
        vm.prank(alice);
        weth.deposit{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert();
        weth.withdraw(2 ether);
        assertEq(weth.balanceOf(alice), 1 ether);
        assertEq(weth.totalSupply(), address(weth).balance);
    }
}
