// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {INadFunFactory} from "../../src/dex/interfaces/INadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract NadFunFactoryTest is Test {
    NadFunFactory factory;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;

    function setUp() public {
        NadFunPair pairImpl = new NadFunPair();
        factory = new NadFunFactory(address(this), address(0), address(pairImpl));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        tokenC = new MockERC20("Token C", "TKC", 18);
    }

    function test_createPair() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));

        assertTrue(pair != address(0), "pair address should not be zero");

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        assertEq(NadFunPair(pair).token0(), token0, "token0 mismatch");
        assertEq(NadFunPair(pair).token1(), token1, "token1 mismatch");
        assertEq(NadFunPair(pair).factory(), address(factory), "factory mismatch");
    }

    function test_createPair_revertsOnDuplicate() public {
        factory.createPair(address(tokenA), address(tokenB));

        vm.expectRevert(NadFunFactory.PairExists.selector);
        factory.createPair(address(tokenA), address(tokenB));
    }

    function test_createPair_revertsOnDuplicate_reversedOrder() public {
        factory.createPair(address(tokenA), address(tokenB));

        vm.expectRevert(NadFunFactory.PairExists.selector);
        factory.createPair(address(tokenB), address(tokenA));
    }

    function test_createPair_revertsOnIdenticalTokens() public {
        vm.expectRevert(NadFunFactory.IdenticalAddresses.selector);
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_createPair_revertsOnZeroAddress() public {
        vm.expectRevert(NadFunFactory.ZeroAddress.selector);
        factory.createPair(address(0), address(tokenA));
    }

    function test_createPair_deterministicAddress() public {
        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        address predicted = Clones.predictDeterministicAddress(factory.implementation(), salt, address(factory));

        address actual = factory.createPair(address(tokenA), address(tokenB));

        assertEq(actual, predicted, "Clone address prediction mismatch");
    }

    function test_getPair_symmetry() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));

        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair, "getPair(A,B) mismatch");
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair, "getPair(B,A) mismatch");
        assertEq(
            factory.getPair(address(tokenA), address(tokenB)),
            factory.getPair(address(tokenB), address(tokenA)),
            "symmetry broken"
        );
    }

    function test_allPairsLength() public {
        assertEq(factory.allPairsLength(), 0, "should start at 0");

        factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.allPairsLength(), 1, "should be 1 after first pair");

        factory.createPair(address(tokenA), address(tokenC));
        assertEq(factory.allPairsLength(), 2, "should be 2 after second pair");
    }

    function test_allPairs_indexAccess() public {
        address pair0 = factory.createPair(address(tokenA), address(tokenB));
        address pair1 = factory.createPair(address(tokenA), address(tokenC));

        assertEq(factory.allPairs(0), pair0, "allPairs[0] mismatch");
        assertEq(factory.allPairs(1), pair1, "allPairs[1] mismatch");
    }

    function test_setFeeTo() public {
        address newFeeTo = makeAddr("newFeeTo");

        vm.expectEmit(true, true, false, true, address(factory));
        emit INadFunFactory.FeeToUpdate(address(0), newFeeTo);

        factory.setFeeTo(newFeeTo);
        assertEq(factory.feeTo(), newFeeTo, "feeTo not updated");
    }

    function test_setImplementation() public {
        address oldImplementation = factory.implementation();
        address newImplementation = address(new NadFunPair());

        vm.expectEmit(true, true, false, true, address(factory));
        emit INadFunFactory.ImplementationUpdate(oldImplementation, newImplementation);

        factory.setImplementation(newImplementation);
        assertEq(factory.implementation(), newImplementation, "implementation not updated");
    }

    function test_setFeeTo_revertsIfNotProtocolManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(NadFunFactory.Forbidden.selector);
        factory.setFeeTo(makeAddr("someone"));
    }

    function test_createPair_emitsPairCreatedEvent() public {
        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        vm.expectEmit(true, true, false, false);
        emit INadFunFactory.PairCreated(token0, token1, address(0), 1);

        factory.createPair(address(tokenA), address(tokenB));
    }
}
