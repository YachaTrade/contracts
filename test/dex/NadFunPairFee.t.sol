// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for NadFunPairFee.

import {Test} from "forge-std/Test.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BPS} from "../../src/libraries/Constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import "forge-std/console.sol";

/// @notice Validates that protocol+creator fees are correctly deducted via FeeCollector.
contract NadFunPairFeeTest is Test {
    NadFunPair pair;
    NadFunFactory factory;
    FeeCollector fc;
    MockERC20 baseToken;
    MockERC20 quoteToken;
    address baseAddr; // could be token0 or token1 depending on sort order
    address quoteAddr;
    bool baseIsToken0;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address bondingCurve = makeAddr("bondingCurve");

    uint256 constant INITIAL_LIQUIDITY = 10e18;
    uint16 constant CREATOR_FEE_RATE = 300; // 3%
    uint16 constant PROTOCOL_FEE_RATE = 200; // 2%
    uint16 constant TOTAL_FEE_RATE = CREATOR_FEE_RATE + PROTOCOL_FEE_RATE; // 5%

    function setUp() public {
        baseToken = new MockERC20("Meme", "BASE", 18);
        quoteToken = new MockERC20("Quote", "QUOTE", 18);

        // Sort tokens
        baseIsToken0 = address(baseToken) < address(quoteToken);
        (address token0, address token1) =
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

        // Deploy real FeeCollector via proxy (threshold=max so settle() is always no-op)
        fc = FeeCollector(
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

        // Deploy real factory (protocolManager=this, feeCollector=fc)
        NadFunPair pairImpl = new NadFunPair();
        factory = new NadFunFactory(address(this), address(fc), address(pairImpl));
        pair = NadFunPair(factory.createPair(token0, token1));

        // Register pair in FeeCollector with per-pair config (must be called by bondingCurve)
        vm.prank(bondingCurve);
        fc.setup(address(pair), baseAddr, quoteAddr, CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE);

        // Add initial liquidity
        MockERC20(token0).mint(address(pair), INITIAL_LIQUIDITY);
        MockERC20(token1).mint(address(pair), INITIAL_LIQUIDITY);
        pair.mint(alice);
    }

    // Helpers

    /// @dev Execute a BUY: send quoteToken in, get baseToken out.
    function _executeBuy(uint256 quoteIn) internal returns (uint256 baseOut) {
        baseOut = pair.getAmountOut(quoteAddr, quoteIn);

        quoteToken.mint(address(pair), quoteIn);

        if (baseIsToken0) {
            pair.swap(baseOut, 0, bob, "");
        } else {
            pair.swap(0, baseOut, bob, "");
        }
    }

    /// @dev Execute a SELL: send baseToken in, get quoteToken out.
    function _executeSell(uint256 baseIn) internal returns (uint256 quoteOutRequested) {
        quoteOutRequested = pair.getAmountOut(baseAddr, baseIn);

        baseToken.mint(address(pair), baseIn);

        if (baseIsToken0) {
            pair.swap(0, quoteOutRequested, bob, "");
        } else {
            pair.swap(quoteOutRequested, 0, bob, "");
        }
    }

    // Buy tests (quoteToken in -> baseToken out)

    function test_swap_buy_deductsFee() public {
        uint256 quoteIn = 1e18;
        uint256 totalFee = (quoteIn * uint256(TOTAL_FEE_RATE)) / BPS;
        // Only creator fee portion stays in FeeCollector; protocol fee sent to feeReceiver
        uint256 expectedCreatorFee = totalFee * uint256(CREATOR_FEE_RATE) / uint256(TOTAL_FEE_RATE);

        uint256 fcBalBefore = quoteToken.balanceOf(address(fc));
        _executeBuy(quoteIn);
        uint256 fcBalAfter = quoteToken.balanceOf(address(fc));

        assertEq(
            fcBalAfter - fcBalBefore, expectedCreatorFee, "FeeCollector should receive creator fee portion from buy"
        );
    }

    function test_swap_buy_feeAccumulatesInFeeCollector() public {
        uint256 quoteIn = 1e18;
        uint256 totalFee = (quoteIn * uint256(TOTAL_FEE_RATE)) / BPS;
        uint256 expectedCreatorFee = totalFee * uint256(CREATOR_FEE_RATE) / uint256(TOTAL_FEE_RATE);

        _executeBuy(quoteIn);

        assertEq(
            fc.accumulatedFee(address(pair)), expectedCreatorFee, "Accumulated fee should match creator fee portion"
        );
    }

    function test_swap_buy_feeIsAlwaysQuoteToken() public {
        uint256 quoteIn = 1e18;

        uint256 baseBalBefore = baseToken.balanceOf(address(fc));
        _executeBuy(quoteIn);
        uint256 baseBalAfter = baseToken.balanceOf(address(fc));

        assertEq(baseBalAfter - baseBalBefore, 0, "FeeCollector should NOT receive baseToken");
        assertTrue(quoteToken.balanceOf(address(fc)) > 0, "FeeCollector should receive quoteToken");
    }

    function test_swap_buy_kInvariant_withFees() public {
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        _executeBuy(1e18);

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);

        assertTrue(kAfter >= kBefore, "k invariant should hold after buy with fees");
    }

    function test_swap_buy_feeCalculation_matchesExpected() public {
        uint256 quoteIn = 2e18;
        uint256 totalFee = (quoteIn * uint256(TOTAL_FEE_RATE)) / BPS; // 5% of 2e18 = 0.1e18
        uint256 expectedCreatorFee = totalFee * uint256(CREATOR_FEE_RATE) / uint256(TOTAL_FEE_RATE);

        _executeBuy(quoteIn);

        assertEq(
            quoteToken.balanceOf(address(fc)),
            expectedCreatorFee,
            "FeeCollector balance should be creator fee portion only"
        );
    }

    // Sell tests (baseToken in -> quoteToken out)

    function test_swap_sell_deductsFee() public {
        uint256 baseIn = 1e18;
        uint256 fcBalBefore = quoteToken.balanceOf(address(fc));

        _executeSell(baseIn);
        uint256 creatorFeeReceived = quoteToken.balanceOf(address(fc)) - fcBalBefore;

        assertGt(creatorFeeReceived, 0, "Creator fee must be positive");
        assertEq(creatorFeeReceived, fc.accumulatedFee(address(pair)), "Sell creator fee should be accumulated");
    }

    function test_swap_sell_feeAccumulatesInFeeCollector() public {
        uint256 baseIn = 1e18;
        uint256 accumulatedBefore = fc.accumulatedFee(address(pair));
        uint256 fcBalBefore = quoteToken.balanceOf(address(fc));

        _executeSell(baseIn);

        uint256 creatorFeeReceived = quoteToken.balanceOf(address(fc)) - fcBalBefore;
        assertGt(creatorFeeReceived, 0, "Creator fee must be positive");
        assertEq(
            fc.accumulatedFee(address(pair)) - accumulatedBefore,
            creatorFeeReceived,
            "Accumulated fee should match creator fee received"
        );
    }

    function test_swap_sell_userReceivesLess() public {
        uint256 baseIn = 1e18;
        // getAmountOut returns the net amount user receives (after fee)
        uint256 expectedUserReceives = pair.getAmountOut(baseAddr, baseIn);

        uint256 bobBalBefore = quoteToken.balanceOf(bob);
        _executeSell(baseIn);
        uint256 bobBalAfter = quoteToken.balanceOf(bob);

        assertEq(bobBalAfter - bobBalBefore, expectedUserReceives, "User should receive quoteOut minus fee");
    }

    function test_swap_sell_feeIsAlwaysQuoteToken() public {
        uint256 baseIn = 1e18;

        uint256 baseBalBefore = baseToken.balanceOf(address(fc));
        _executeSell(baseIn);
        uint256 baseBalAfter = baseToken.balanceOf(address(fc));

        assertEq(baseBalAfter - baseBalBefore, 0, "FeeCollector should NOT receive baseToken on sell");
        assertTrue(quoteToken.balanceOf(address(fc)) > 0, "FeeCollector should receive quoteToken on sell");
    }

    function test_swap_sell_kInvariant_withFees() public {
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        _executeSell(1e18);

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);

        assertTrue(kAfter >= kBefore, "k invariant should hold after sell with fees");
    }

    // Vanilla swap tests (no fee config)

    function test_swap_noFeeConfig_vanillaSwap() public {
        // Deploy a pair with feeCollector but no fee config
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        (address t0, address t1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        ProtocolManager pm2Impl = new ProtocolManager();
        ProtocolManager pm2 = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(pm2Impl),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), makeAddr("feeReceiver2")))
                )
            )
        );
        FeeCollector fc2 = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(new FeeCollector()),
                    abi.encodeCall(
                        FeeCollector.initialize, (address(pm2), makeAddr("tp2"), makeAddr("bc2"), makeAddr("router2"))
                    )
                )
            )
        );
        NadFunFactory factory2 = new NadFunFactory(address(this), address(fc2), address(new NadFunPair()));
        NadFunPair vanillaPair = NadFunPair(factory2.createPair(t0, t1));

        MockERC20(t0).mint(address(vanillaPair), INITIAL_LIQUIDITY);
        MockERC20(t1).mint(address(vanillaPair), INITIAL_LIQUIDITY);
        vanillaPair.mint(alice);

        uint256 swapIn = 1e18;
        // Source of truth: vanilla pair's own view
        uint256 expectedOut = vanillaPair.getAmountOut(t0, swapIn);
        MockERC20(t0).mint(address(vanillaPair), swapIn);

        uint256 bobBefore = MockERC20(t1).balanceOf(bob);
        vanillaPair.swap(0, expectedOut, bob, "");
        uint256 bobAfter = MockERC20(t1).balanceOf(bob);

        assertEq(bobAfter - bobBefore, expectedOut, "Vanilla swap should give full output");
    }

    function test_swap_noFeeConfig_onlyLpFee() public {
        // Deploy pair with FeeCollector but NO fee config for the pair
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        (address t0, address t1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        ProtocolManager pm3Impl = new ProtocolManager();
        ProtocolManager pm3 = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(pm3Impl),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), makeAddr("feeReceiver3")))
                )
            )
        );
        FeeCollector fc3 = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(new FeeCollector()),
                    abi.encodeCall(
                        FeeCollector.initialize, (address(pm3), makeAddr("tp3"), makeAddr("bc3"), makeAddr("router3"))
                    )
                )
            )
        );
        // No setup() called -> getFeeConfig returns empty FeeConfig for any pair
        NadFunFactory factory3 = new NadFunFactory(address(this), address(fc3), address(new NadFunPair()));
        NadFunPair pair2 = NadFunPair(factory3.createPair(t0, t1));

        MockERC20(t0).mint(address(pair2), INITIAL_LIQUIDITY);
        MockERC20(t1).mint(address(pair2), INITIAL_LIQUIDITY);
        pair2.mint(alice);

        uint256 swapIn = 1e18;
        // Source of truth: the vanilla pair's own view
        uint256 expectedOut = pair2.getAmountOut(t0, swapIn);
        MockERC20(t0).mint(address(pair2), swapIn);

        uint256 bobBefore = MockERC20(t1).balanceOf(bob);
        pair2.swap(0, expectedOut, bob, "");
        uint256 bobAfter = MockERC20(t1).balanceOf(bob);

        assertEq(bobAfter - bobBefore, expectedOut, "No fee config should behave like vanilla V2");
        assertEq(MockERC20(t0).balanceOf(address(fc3)), 0, "FeeCollector should receive nothing");
        assertEq(MockERC20(t1).balanceOf(address(fc3)), 0, "FeeCollector should receive nothing");
    }

    // Fee calculation accuracy

    function test_swap_feeCalculation_roundingFavorsProtocol() public {
        uint256 quoteIn = 99; // 99 wei
        uint256 totalFee = (quoteIn * uint256(TOTAL_FEE_RATE)) / BPS; // 99 * 500 / 10000 = 4 (floor)
        // FeeCollector splits with mulDivUp: protocol gets ceiling, creator gets remainder
        uint256 expectedProtocol =
            FixedPointMathLib.mulDivUp(totalFee, uint256(PROTOCOL_FEE_RATE), uint256(TOTAL_FEE_RATE));
        uint256 expectedCreatorFee = totalFee - expectedProtocol;

        uint256 baseOut = pair.getAmountOut(quoteAddr, quoteIn);
        quoteToken.mint(address(pair), quoteIn);

        if (baseIsToken0) {
            pair.swap(baseOut, 0, bob, "");
        } else {
            pair.swap(0, baseOut, bob, "");
        }

        assertEq(
            quoteToken.balanceOf(address(fc)),
            expectedCreatorFee,
            "FeeCollector should hold creator fee portion (rounding truncates)"
        );
    }

    function test_swap_multipleBuys_feesAccumulate() public {
        uint256 quoteIn1 = 1e18;
        uint256 quoteIn2 = 2e18;

        uint256 totalFee1 = (quoteIn1 * uint256(TOTAL_FEE_RATE)) / BPS;
        uint256 expectedCreatorFee1 = totalFee1 * uint256(CREATOR_FEE_RATE) / uint256(TOTAL_FEE_RATE);
        _executeBuy(quoteIn1);
        assertEq(fc.accumulatedFee(address(pair)), expectedCreatorFee1, "First buy creator fee");

        uint256 totalFee2 = (quoteIn2 * uint256(TOTAL_FEE_RATE)) / BPS;
        uint256 expectedCreatorFee2 = totalFee2 * uint256(CREATOR_FEE_RATE) / uint256(TOTAL_FEE_RATE);
        _executeBuy(quoteIn2);
        assertEq(
            fc.accumulatedFee(address(pair)),
            expectedCreatorFee1 + expectedCreatorFee2,
            "Accumulated creator fee after two buys"
        );
    }

    function test_swap_buyThenSell_feesAccumulate() public {
        // Measure the creator fee actually credited by doing the buy in isolation
        // rather than reimplementing FeeCollector's split math.
        uint256 quoteIn = 1e18;
        uint256 fcBefore = fc.accumulatedFee(address(pair));
        _executeBuy(quoteIn);
        uint256 buyCreatorFee = fc.accumulatedFee(address(pair)) - fcBefore;

        uint256 baseIn = 0.5e18;
        uint256 fcBeforeSell = fc.accumulatedFee(address(pair));
        _executeSell(baseIn);
        uint256 sellCreatorFee = fc.accumulatedFee(address(pair)) - fcBeforeSell;

        assertEq(
            fc.accumulatedFee(address(pair)),
            buyCreatorFee + sellCreatorFee,
            "Creator fee portions should accumulate across buy and sell"
        );
    }

    function test_getAmountOut_buy_swapReceivesExactAmount() public {
        uint256 quoteIn = 1e18;
        uint256 expectedBaseOut = pair.getAmountOut(quoteAddr, quoteIn);

        quoteToken.mint(address(pair), quoteIn);
        uint256 bobBefore = baseToken.balanceOf(bob);
        if (baseIsToken0) {
            pair.swap(expectedBaseOut, 0, bob, "");
        } else {
            pair.swap(0, expectedBaseOut, bob, "");
        }
        uint256 bobAfter = baseToken.balanceOf(bob);

        assertEq(bobAfter - bobBefore, expectedBaseOut, "Buy: user should receive exactly getAmountOut");
    }

    function test_getAmountOut_sell_swapReceivesExactAmount() public {
        uint256 baseIn = 1e18;
        uint256 expectedQuoteOut = pair.getAmountOut(baseAddr, baseIn);

        baseToken.mint(address(pair), baseIn);
        uint256 bobBefore = quoteToken.balanceOf(bob);
        if (baseIsToken0) {
            pair.swap(0, expectedQuoteOut, bob, "");
        } else {
            pair.swap(expectedQuoteOut, 0, bob, "");
        }
        uint256 bobAfter = quoteToken.balanceOf(bob);

        assertEq(bobAfter - bobBefore, expectedQuoteOut, "Sell: user should receive exactly getAmountOut");
    }

    function test_getAmountIn_buy_swapSucceedsWithExactInput() public {
        uint256 desiredBaseOut = 0.5e18;
        uint256 requiredQuoteIn = pair.getAmountIn(baseAddr, desiredBaseOut);

        quoteToken.mint(address(pair), requiredQuoteIn);
        uint256 bobBefore = baseToken.balanceOf(bob);
        if (baseIsToken0) {
            pair.swap(desiredBaseOut, 0, bob, "");
        } else {
            pair.swap(0, desiredBaseOut, bob, "");
        }
        uint256 bobAfter = baseToken.balanceOf(bob);

        assertEq(
            bobAfter - bobBefore, desiredBaseOut, "Buy: getAmountIn should provide enough input for desired output"
        );
    }

    function test_getAmountIn_sell_swapSucceedsWithExactInput() public {
        uint256 desiredQuoteOut = 0.5e18;
        uint256 requiredBaseIn = pair.getAmountIn(quoteAddr, desiredQuoteOut);

        baseToken.mint(address(pair), requiredBaseIn);
        uint256 bobBefore = quoteToken.balanceOf(bob);
        if (baseIsToken0) {
            pair.swap(0, desiredQuoteOut, bob, "");
        } else {
            pair.swap(desiredQuoteOut, 0, bob, "");
        }
        uint256 bobAfter = quoteToken.balanceOf(bob);

        assertEq(
            bobAfter - bobBefore, desiredQuoteOut, "Sell: getAmountIn should provide enough input for desired output"
        );
    }

    // getAmountIn / getAmountOut roundtrip

    function test_roundtrip_buy_getAmountOutThenGetAmountIn() public view {
        uint256 quoteIn = 1e18;
        uint256 baseOut = pair.getAmountOut(quoteAddr, quoteIn);
        uint256 quoteInReversed = pair.getAmountIn(baseAddr, baseOut);

        assertGe(quoteInReversed, quoteIn, "Buy roundtrip: getAmountIn should be >= original input");
        assertLe(quoteInReversed - quoteIn, 1, "Buy roundtrip: difference should be at most 1 wei");
    }

    function test_roundtrip_sell_getAmountOutThenGetAmountIn() public view {
        uint256 baseIn = 1e18;
        uint256 quoteOut = pair.getAmountOut(baseAddr, baseIn);
        uint256 baseInReversed = pair.getAmountIn(quoteAddr, quoteOut);

        uint256 diff = baseIn > baseInReversed ? baseIn - baseInReversed : baseInReversed - baseIn;
        assertLe(diff, 1, "Sell roundtrip: difference should be at most 1 wei");
    }
}
