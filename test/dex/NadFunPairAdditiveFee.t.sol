// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for NadFunPairAdditiveFee.

import {Test} from "forge-std/Test.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import "forge-std/console.sol";

/// @notice Sanity check for additive sell fee model
contract AdditiveFeeCheckTest is Test {
    NadFunPair pair;
    NadFunFactory factory;
    FeeCollector fc;
    MockERC20 baseToken;
    MockERC20 quoteToken;
    address baseAddr;
    address quoteAddr;
    bool baseIsToken0;

    address bob = makeAddr("bob");
    address bondingCurve = makeAddr("bondingCurve");

    // Very deep liquidity (1:1) so AMM slippage is negligible
    uint256 constant LIQ = 1e30;

    // Test fees: creator 1%, protocol 1% -> feeRate = 200
    uint16 constant CREATOR_FEE_RATE = 100; // 1%
    uint16 constant PROTOCOL_FEE_RATE = 100; // 1%

    function setUp() public {
        baseToken = new MockERC20("Meme", "BASE", 18);
        quoteToken = new MockERC20("Quote", "QUOTE", 18);

        baseIsToken0 = address(baseToken) < address(quoteToken);
        (address t0, address t1) =
            baseIsToken0 ? (address(baseToken), address(quoteToken)) : (address(quoteToken), address(baseToken));
        baseAddr = address(baseToken);
        quoteAddr = address(quoteToken);

        // Deploy real ProtocolManager (authority for AccessManaged contracts)
        ProtocolManager pmImpl = new ProtocolManager();
        ProtocolManager protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), makeAddr("feeReceiver")))
                )
            )
        );

        fc = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(new FeeCollector()),
                    abi.encodeCall(
                        FeeCollector.initialize,
                        (address(protocolManager), makeAddr("processor"), bondingCurve, makeAddr("router"))
                    )
                )
            )
        );

        NadFunPair pairImpl = new NadFunPair();
        factory = new NadFunFactory(address(this), address(fc), address(pairImpl));
        pair = NadFunPair(factory.createPair(t0, t1));

        vm.prank(bondingCurve);
        fc.setup(address(pair), baseAddr, quoteAddr, CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE);

        MockERC20(t0).mint(address(pair), LIQ);
        MockERC20(t1).mint(address(pair), LIQ);
        pair.mint(address(this));
    }

    /// @notice 100 base in, deep 1:1, pair quote must execute exactly.
    function test_sell_100_additive() public {
        uint256 amountIn = 100e18;
        uint256 viewOut = pair.getAmountOut(baseAddr, amountIn);

        console.log("===== SELL 100 (deep 1:1, fees: LP 0.25% + Creator 1% + Protocol 1%) =====");
        console.log("amountIn          :", amountIn);
        console.log("view amountOut    :", viewOut);

        // Execute swap to verify K check passes
        baseToken.mint(address(pair), amountIn);
        if (baseIsToken0) {
            pair.swap(0, viewOut, bob, "");
        } else {
            pair.swap(viewOut, 0, bob, "");
        }

        uint256 received = quoteToken.balanceOf(bob);
        console.log("actual swap output:", received);
        assertEq(received, viewOut, "view should match swap");
    }

    /// @notice Buy 100 quote in, pair quote must execute exactly.
    function test_buy_100_additive() public {
        uint256 amountIn = 100e18;
        uint256 viewOut = pair.getAmountOut(quoteAddr, amountIn);

        console.log("===== BUY 100 (deep 1:1, same fees) =====");
        console.log("amountIn          :", amountIn);
        console.log("view amountOut    :", viewOut);

        quoteToken.mint(address(pair), amountIn);
        if (baseIsToken0) {
            pair.swap(viewOut, 0, bob, "");
        } else {
            pair.swap(0, viewOut, bob, "");
        }

        uint256 received = baseToken.balanceOf(bob);
        console.log("actual swap output:", received);
        assertEq(received, viewOut, "view should match swap");
    }

    function test_buy_getAmountIn_minimum() public {
        uint256 desiredOut = 50e18; // base 50 want
        uint256 amountIn = pair.getAmountIn(baseAddr, desiredOut);

        console.log("===== BUY: desiredOut = 50, getAmountIn =", amountIn);

        quoteToken.mint(address(pair), amountIn);
        if (baseIsToken0) {
            pair.swap(desiredOut, 0, bob, "");
        } else {
            pair.swap(0, desiredOut, bob, "");
        }
        console.log("exact amountIn -> swap success");
    }

    function test_buy_getAmountIn_minus1_reverts() public {
        uint256 desiredOut = 50e18;
        uint256 amountIn = pair.getAmountIn(baseAddr, desiredOut);

        quoteToken.mint(address(pair), amountIn - 1);

        vm.expectRevert(bytes("NadFunPair: K"));
        if (baseIsToken0) {
            pair.swap(desiredOut, 0, bob, "");
        } else {
            pair.swap(0, desiredOut, bob, "");
        }
        console.log("amountIn - 1 -> K check reverted as expected");
    }

    function test_sell_getAmountIn_minimum() public {
        uint256 desiredOut = 50e18; // quote 50 want
        uint256 amountIn = pair.getAmountIn(quoteAddr, desiredOut);

        console.log("===== SELL: desiredOut = 50, getAmountIn =", amountIn);

        baseToken.mint(address(pair), amountIn);
        if (baseIsToken0) {
            pair.swap(0, desiredOut, bob, "");
        } else {
            pair.swap(desiredOut, 0, bob, "");
        }
        console.log("exact amountIn -> swap success");
    }

    function test_sell_getAmountIn_marginScan() public {
        uint256 desiredOut = 50e18;
        uint256 amountIn = pair.getAmountIn(quoteAddr, desiredOut);
        console.log("getAmountIn (sell):", amountIn);

        // Try amountIn - 1, -2, -3, -4, -5 ...
        for (uint256 delta = 1; delta <= 10; delta++) {
            uint256 snap = vm.snapshotState();
            baseToken.mint(address(pair), amountIn - delta);

            try this._executeSwap(desiredOut) {
                console.log("delta =", delta, " -> SUCCESS (no K revert)");
            } catch {
                console.log("delta =", delta, " -> REVERTED");
            }
            vm.revertToState(snap);
        }
    }

    function _executeSwap(uint256 desiredOut) external {
        if (baseIsToken0) {
            pair.swap(0, desiredOut, bob, "");
        } else {
            pair.swap(desiredOut, 0, bob, "");
        }
    }

    function test_roundtrip_buy() public view {
        uint256 desiredOut = 50e18;
        uint256 amountIn = pair.getAmountIn(baseAddr, desiredOut);
        uint256 actualOut = pair.getAmountOut(quoteAddr, amountIn);

        console.log("=== BUY round-trip ===");
        console.log("desiredOut    :", desiredOut);
        console.log("getAmountIn   :", amountIn);
        console.log("getAmountOut  :", actualOut);
        console.log("delta (out-desired):", actualOut > desiredOut ? actualOut - desiredOut : desiredOut - actualOut);
    }

    function test_roundtrip_sell() public view {
        uint256 desiredOut = 50e18;
        uint256 amountIn = pair.getAmountIn(quoteAddr, desiredOut);
        uint256 actualOut = pair.getAmountOut(baseAddr, amountIn);

        console.log("=== SELL round-trip ===");
        console.log("desiredOut    :", desiredOut);
        console.log("getAmountIn   :", amountIn);
        console.log("getAmountOut  :", actualOut);
        console.log("delta (out-desired):", actualOut > desiredOut ? actualOut - desiredOut : desiredOut - actualOut);
    }
}
