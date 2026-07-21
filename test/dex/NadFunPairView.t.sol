// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice NadFunPair.getAmountOut/getAmountIn view function tests
/// @dev Uses real NadFunFactory + NadFunPair with MockFeeCollector.
contract NadFunPairViewTest is Test {
    MockERC20 public quoteToken;
    MockERC20 public baseToken;
    NadFunFactory public factory;
    FeeCollector public feeCollector;
    address public pair;

    address bondingCurve = makeAddr("bondingCurve");

    uint256 constant INITIAL_BASE_LIQ = 100_000 ether;
    uint256 constant INITIAL_QUOTE_LIQ = 100 ether;

    function setUp() public {
        quoteToken = new MockERC20("WMON", "WMON", 18);
        baseToken = new MockERC20("BASE", "BASE", 18);

        feeCollector = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(new FeeCollector()),
                    abi.encodeCall(
                        FeeCollector.initialize,
                        (makeAddr("protocolManager"), makeAddr("creatorFeeProcessor"), bondingCurve, makeAddr("router"))
                    )
                )
            )
        );
        NadFunPair pairImpl = new NadFunPair();
        factory = new NadFunFactory(address(this), address(feeCollector), address(pairImpl));
        pair = factory.createPair(address(quoteToken), address(baseToken));

        _seedLiquidity(INITIAL_BASE_LIQ, INITIAL_QUOTE_LIQ);
    }

    // ── getAmountOut ───────────────────────────────────────
    //
    // These tests treat `pair.getAmountOut()` as the source of truth. Rather than
    // reimplementing the fee formula (which drifts from the implementation), we
    // verify invariants that must hold regardless of the exact math:
    //   1. Monotonicity: larger input ⇒ strictly larger output
    //   2. Fee impact:   with fee < without fee
    //   3. Round-trip:   getAmountIn(getAmountOut(x)) ≈ x (covered below)
    // Swap-consistency (actual swap receives exactly the view output) is covered
    // in NadFunPairFee.t.sol.

    /// @notice getAmountOut buy monotonicity and positivity (no NadFun fee)
    function test_getAmountOut_buy() public view {
        uint256 a = 1 ether;
        uint256 b = 2 ether;
        uint256 outA = INadFunPair(pair).getAmountOut(address(quoteToken), a);
        uint256 outB = INadFunPair(pair).getAmountOut(address(quoteToken), b);

        assertGt(outA, 0, "buy output must be positive");
        assertGt(outB, outA, "buy output must increase with larger input (monotonic)");
    }

    /// @notice getAmountOut sell monotonicity and positivity (no NadFun fee)
    function test_getAmountOut_sell() public view {
        uint256 a = 1000 ether;
        uint256 b = 2000 ether;
        uint256 outA = INadFunPair(pair).getAmountOut(address(baseToken), a);
        uint256 outB = INadFunPair(pair).getAmountOut(address(baseToken), b);

        assertGt(outA, 0, "sell output must be positive");
        assertGt(outB, outA, "sell output must increase with larger input (monotonic)");
    }

    /// @notice getAmountOut buy with fee — must be strictly less than no-fee baseline.
    function test_getAmountOut_buy_withFee() public {
        uint256 amountIn = 1 ether;

        // Baseline: query before configuring fee
        uint256 noFeeOut = INadFunPair(pair).getAmountOut(address(quoteToken), amountIn);

        // Configure 5% NadFun fee (CREATOR=300, PROTOCOL=200)
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200);

        uint256 withFeeOut = INadFunPair(pair).getAmountOut(address(quoteToken), amountIn);

        assertGt(withFeeOut, 0, "buy output with fee must be positive");
        assertLt(withFeeOut, noFeeOut, "buy with fee must be strictly less than no-fee baseline");
    }

    /// @notice getAmountOut sell with fee — must be strictly less than no-fee baseline.
    function test_getAmountOut_sell_withFee() public {
        uint256 amountIn = 1000 ether;

        // Baseline: query before configuring fee
        uint256 noFeeOut = INadFunPair(pair).getAmountOut(address(baseToken), amountIn);

        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200);

        uint256 withFeeOut = INadFunPair(pair).getAmountOut(address(baseToken), amountIn);

        assertGt(withFeeOut, 0, "sell output with fee must be positive");
        assertLt(withFeeOut, noFeeOut, "sell with fee must be strictly less than no-fee baseline");
    }

    function test_getAmountOut_revertsForInvalidToken() public {
        vm.expectRevert("NadFunPair: INVALID_TOKEN");
        INadFunPair(pair).getAmountOut(makeAddr("invalidToken"), 1 ether);
    }

    // ── getAmountIn ────────────────────────────────────────

    /// @notice getAmountIn for buy — round-trip consistency
    function test_getAmountIn_buy() public view {
        uint256 desiredOut = 500 ether;
        uint256 amountIn = INadFunPair(pair).getAmountIn(address(baseToken), desiredOut);

        uint256 actualOut = INadFunPair(pair).getAmountOut(address(quoteToken), amountIn);
        assertGe(actualOut, desiredOut, "getAmountIn buy should produce at least desiredOut");

        if (amountIn > 1) {
            uint256 lessOut = INadFunPair(pair).getAmountOut(address(quoteToken), amountIn - 1);
            assertLt(lessOut, desiredOut, "amountIn - 1 should undershoot");
        }
    }

    /// @notice getAmountIn for sell — round-trip consistency
    function test_getAmountIn_sell() public view {
        uint256 desiredOut = 0.5 ether;
        uint256 amountIn = INadFunPair(pair).getAmountIn(address(quoteToken), desiredOut);

        uint256 actualOut = INadFunPair(pair).getAmountOut(address(baseToken), amountIn);
        assertGe(actualOut, desiredOut, "getAmountIn sell should produce at least desiredOut");
    }

    /// @notice getAmountIn buy with fee — round-trip consistency
    function test_getAmountIn_buy_withFee() public {
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200);
        uint256 desiredOut = 500 ether;
        uint256 amountIn = INadFunPair(pair).getAmountIn(address(baseToken), desiredOut);

        uint256 actualOut = INadFunPair(pair).getAmountOut(address(quoteToken), amountIn);
        assertGe(actualOut, desiredOut, "getAmountIn buy with fee round-trip");
    }

    /// @notice getAmountIn sell with fee — round-trip consistency
    function test_getAmountIn_sell_withFee() public {
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200);
        uint256 desiredOut = 0.5 ether;
        uint256 amountIn = INadFunPair(pair).getAmountIn(address(quoteToken), desiredOut);

        uint256 actualOut = INadFunPair(pair).getAmountOut(address(baseToken), amountIn);
        assertGe(actualOut, desiredOut, "getAmountIn sell with fee round-trip");
    }

    function test_getAmountIn_revertsForInvalidToken() public {
        vm.expectRevert("NadFunPair: INVALID_TOKEN");
        INadFunPair(pair).getAmountIn(makeAddr("invalidToken"), 1 ether);
    }

    // ── Vanilla pair (no FeeCollector) ─────────────────────

    /// @notice getAmountOut on vanilla pair (no FeeCollector) — should work without fee
    function test_getAmountOut_vanillaPair_noFee() public {
        FeeCollector vanillaFc = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(new FeeCollector()),
                    abi.encodeCall(
                        FeeCollector.initialize,
                        (makeAddr("pm2"), makeAddr("tp2"), makeAddr("bc2"), makeAddr("router2"))
                    )
                )
            )
        );
        NadFunFactory vanillaFactory = new NadFunFactory(address(this), address(vanillaFc), address(new NadFunPair()));
        MockERC20 vanillaToken = new MockERC20("VAN", "VAN", 18);
        address vanillaPair = vanillaFactory.createPair(address(quoteToken), address(vanillaToken));

        vanillaToken.mint(address(this), INITIAL_BASE_LIQ);
        quoteToken.mint(address(this), INITIAL_QUOTE_LIQ);
        IERC20(address(vanillaToken)).transfer(vanillaPair, INITIAL_BASE_LIQ);
        IERC20(address(quoteToken)).transfer(vanillaPair, INITIAL_QUOTE_LIQ);
        INadFunPair(vanillaPair).mint(address(this));

        uint256 amountIn = 1 ether;
        uint256 out1 = INadFunPair(vanillaPair).getAmountOut(address(quoteToken), amountIn);
        uint256 out2 = INadFunPair(vanillaPair).getAmountOut(address(quoteToken), amountIn * 2);

        // Source of truth: pair.getAmountOut. Verify basic invariants only.
        assertGt(out1, 0, "vanilla pair getAmountOut should succeed");
        assertGt(out2, out1, "vanilla pair getAmountOut must be monotonic");

        // Round-trip: getAmountIn(getAmountOut(x)) >= x (ceil reverse).
        // `tokenOut` is the "base" token we want out when supplying quote.
        address vanillaBase = _otherToken(vanillaPair, address(quoteToken));
        uint256 amountInReversed = INadFunPair(vanillaPair).getAmountIn(vanillaBase, out1);
        assertGe(amountInReversed, amountIn, "round-trip getAmountIn must be >= original amountIn");
    }

    /// @dev Return the "other" token of a pair (not `known`).
    function _otherToken(address pairAddr, address known) internal view returns (address) {
        address t0 = INadFunPair(pairAddr).token0();
        address t1 = INadFunPair(pairAddr).token1();
        return known == t0 ? t1 : t0;
    }

    // ── Helpers ─────────────────────────────────────────────

    function _seedLiquidity(uint256 baseAmount, uint256 quote) internal {
        baseToken.mint(address(this), baseAmount);
        quoteToken.mint(address(this), quote);

        IERC20(address(baseToken)).transfer(pair, baseAmount);
        IERC20(address(quoteToken)).transfer(pair, quote);

        INadFunPair(pair).mint(address(this));
    }
}
