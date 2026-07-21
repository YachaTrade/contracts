// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NadSwapAdapter} from "../../src/adapters/NadSwapAdapter.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice NadSwapAdapter unit tests — V2 AMM swap/liquidity/fee logic
/// @dev Uses real NadFunFactory + NadFunPair with MockFeeCollector.
contract NadSwapAdapterTest is Test {
    NadSwapAdapter public adapter;
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

        feeCollector = FeeCollector(
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
        NadFunPair pairImpl = new NadFunPair();
        factory = new NadFunFactory(address(this), address(feeCollector), address(pairImpl));
        pair = factory.createPair(address(quoteToken), address(baseToken));

        _seedLiquidity(INITIAL_BASE_LIQ, INITIAL_QUOTE_LIQ);

        adapter = new NadSwapAdapter();
    }

    // ── Swap: Buy (quoteIn -> baseOut) ─────────────────────

    /// @notice Vanilla buy — adapter must deliver exactly what pair.getAmountOut reports
    function test_swap_buy() public {
        uint256 amountIn = 1 ether;
        quoteToken.mint(address(adapter), amountIn);

        // Source of truth: pair.getAmountOut
        uint256 expectedOut = INadFunPair(pair).getAmountOut(address(quoteToken), amountIn);

        uint256 actualOut = adapter.swap(pair, address(quoteToken), address(baseToken), amountIn, address(this), "");

        assertEq(actualOut, expectedOut, "Buy output should match pair.getAmountOut");
        assertEq(baseToken.balanceOf(address(this)), expectedOut, "Recipient should receive baseToken");
        assertEq(quoteToken.balanceOf(address(adapter)), 0, "Adapter should have no quoteToken left");
    }

    /// @notice Buy with 5% NadFun fee — adapter must delegate exactly to pair
    function test_swap_buy_withFee() public {
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200); // 5%

        uint256 amountIn = 10 ether;
        quoteToken.mint(address(adapter), amountIn);

        // Source of truth: pair.getAmountOut
        uint256 expectedOut = INadFunPair(pair).getAmountOut(address(quoteToken), amountIn);

        uint256 actualOut = adapter.swap(pair, address(quoteToken), address(baseToken), amountIn, address(this), "");

        assertEq(actualOut, expectedOut, "Buy with fee should match pair.getAmountOut");
        assertEq(baseToken.balanceOf(address(this)), expectedOut);
    }

    /// @notice tokenOut must be the pair's other token — a mismatched tokenOut reverts BEFORE any
    ///         transfer, so a caller (e.g. DividendVault's bot-supplied hop) can't push quote into a
    ///         pair and have it swapped into a token other than the one it credits. Mirrors
    ///         UniswapV2ExternalAdapter's TokenMismatch guard.
    function test_swap_revertsOnTokenMismatch() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 18);
        quoteToken.mint(address(adapter), 1 ether);
        vm.expectRevert(NadSwapAdapter.TokenMismatch.selector);
        adapter.swap(pair, address(quoteToken), address(other), 1 ether, address(this), "");
        // guard runs before the transfer — nothing left the adapter
        assertEq(quoteToken.balanceOf(address(adapter)), 1 ether, "no funds moved on mismatch");
    }

    // ── Swap: Sell (baseIn -> quoteOut) ────────────────────

    /// @notice Vanilla sell — no NadFun fee
    function test_swap_sell() public {
        uint256 amountIn = 1000 ether;
        baseToken.mint(address(adapter), amountIn);

        // Source of truth: pair.getAmountOut — adapter must delegate exactly
        uint256 expectedOut = INadFunPair(pair).getAmountOut(address(baseToken), amountIn);

        uint256 actualOut = adapter.swap(pair, address(baseToken), address(quoteToken), amountIn, address(this), "");

        assertEq(actualOut, expectedOut, "Sell output should match pair.getAmountOut");
        assertEq(quoteToken.balanceOf(address(this)), expectedOut, "Recipient should receive quoteToken");
    }

    /// @notice Sell with 5% NadFun fee — fee deducted from output
    function test_swap_sell_withFee() public {
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200); // 5%

        uint256 amountIn = 1000 ether;
        baseToken.mint(address(adapter), amountIn);

        // Source of truth: pair.getAmountOut — adapter must delegate exactly
        uint256 expectedOut = INadFunPair(pair).getAmountOut(address(baseToken), amountIn);

        uint256 actualOut = adapter.swap(pair, address(baseToken), address(quoteToken), amountIn, address(this), "");

        assertEq(actualOut, expectedOut, "Sell with fee should match pair.getAmountOut");
        assertEq(quoteToken.balanceOf(address(this)), expectedOut);
    }

    /// @notice Swap on vanilla pair (no FeeCollector config) — should work without fee
    function test_swap_vanillaPair_noFee() public {
        // Create a pair with feeCollector but no fee config
        ProtocolManager pm2Impl = new ProtocolManager();
        ProtocolManager pm2 = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(pm2Impl),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), makeAddr("feeReceiver2")))
                )
            )
        );
        FeeCollector vanillaFc = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(new FeeCollector()),
                    abi.encodeCall(
                        FeeCollector.initialize, (address(pm2), makeAddr("tp2"), makeAddr("bc2"), makeAddr("router2"))
                    )
                )
            )
        );
        NadFunFactory vanillaFactory = new NadFunFactory(address(this), address(vanillaFc), address(new NadFunPair()));
        MockERC20 vanillaToken = new MockERC20("VAN", "VAN", 18);
        address vanillaPair = vanillaFactory.createPair(address(quoteToken), address(vanillaToken));

        // Seed liquidity
        vanillaToken.mint(address(this), INITIAL_BASE_LIQ);
        quoteToken.mint(address(this), INITIAL_QUOTE_LIQ);
        IERC20(address(vanillaToken)).transfer(vanillaPair, INITIAL_BASE_LIQ);
        IERC20(address(quoteToken)).transfer(vanillaPair, INITIAL_QUOTE_LIQ);
        INadFunPair(vanillaPair).mint(address(this));

        // Buy on vanilla pair
        uint256 amountIn = 1 ether;
        quoteToken.mint(address(adapter), amountIn);

        uint256 actualOut =
            adapter.swap(vanillaPair, address(quoteToken), address(vanillaToken), amountIn, address(this), "");

        assertGt(actualOut, 0, "Vanilla pair swap should succeed");
    }

    // ── getAmountOut ───────────────────────────────────────

    /// @notice getAmountOut for buy direction — adapter must delegate to pair
    function test_getAmountOut_buy() public view {
        uint256 amountIn = 1 ether;
        uint256 expected = INadFunPair(pair).getAmountOut(address(quoteToken), amountIn);

        uint256 actual = adapter.getAmountOut(pair, address(quoteToken), amountIn);

        assertEq(actual, expected, "adapter.getAmountOut buy should delegate to pair");
    }

    /// @notice getAmountOut for sell direction — adapter must delegate to pair
    function test_getAmountOut_sell() public view {
        uint256 amountIn = 1000 ether;
        uint256 expected = INadFunPair(pair).getAmountOut(address(baseToken), amountIn);

        uint256 actual = adapter.getAmountOut(pair, address(baseToken), amountIn);

        assertEq(actual, expected, "adapter.getAmountOut sell should delegate to pair");
    }

    /// @notice getAmountOut buy with fee — adapter must delegate to pair
    function test_getAmountOut_buy_withFee() public {
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200);
        uint256 amountIn = 1 ether;
        uint256 expected = INadFunPair(pair).getAmountOut(address(quoteToken), amountIn);

        uint256 actual = adapter.getAmountOut(pair, address(quoteToken), amountIn);

        assertEq(actual, expected, "adapter.getAmountOut buy with fee should delegate to pair");
    }

    /// @notice getAmountOut sell with fee — adapter must delegate to pair
    function test_getAmountOut_sell_withFee() public {
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200);
        uint256 amountIn = 1000 ether;
        uint256 expected = INadFunPair(pair).getAmountOut(address(baseToken), amountIn);

        uint256 actual = adapter.getAmountOut(pair, address(baseToken), amountIn);

        assertEq(actual, expected, "adapter.getAmountOut sell with fee should delegate to pair");
    }

    // ── getAmountIn ────────────────────────────────────────

    /// @notice getAmountIn for buy — round-trip consistency
    function test_getAmountIn_buy() public view {
        uint256 desiredOut = 500 ether; // desired baseToken out
        uint256 amountIn = adapter.getAmountIn(pair, address(baseToken), desiredOut);

        // Verify round-trip: getAmountOut(amountIn) >= desiredOut
        uint256 actualOut = adapter.getAmountOut(pair, address(quoteToken), amountIn);
        assertGe(actualOut, desiredOut, "getAmountIn buy should produce at least desiredOut");

        // Verify not over-estimated: amountIn - 1 should produce less than desiredOut
        if (amountIn > 1) {
            uint256 lessOut = adapter.getAmountOut(pair, address(quoteToken), amountIn - 1);
            assertLt(lessOut, desiredOut, "amountIn - 1 should undershoot");
        }
    }

    /// @notice getAmountIn for sell — round-trip consistency
    function test_getAmountIn_sell() public view {
        uint256 desiredOut = 0.5 ether; // desired quoteToken out
        uint256 amountIn = adapter.getAmountIn(pair, address(quoteToken), desiredOut);

        // Verify round-trip
        uint256 actualOut = adapter.getAmountOut(pair, address(baseToken), amountIn);
        assertGe(actualOut, desiredOut, "getAmountIn sell should produce at least desiredOut");
    }

    /// @notice getAmountIn buy with fee — round-trip consistency
    function test_getAmountIn_buy_withFee() public {
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200);
        uint256 desiredOut = 500 ether;
        uint256 amountIn = adapter.getAmountIn(pair, address(baseToken), desiredOut);

        uint256 actualOut = adapter.getAmountOut(pair, address(quoteToken), amountIn);
        assertGe(actualOut, desiredOut, "getAmountIn buy with fee round-trip");
    }

    /// @notice getAmountIn sell with fee — round-trip consistency
    function test_getAmountIn_sell_withFee() public {
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(baseToken), address(quoteToken), 300, 200, 200);
        uint256 desiredOut = 0.5 ether;
        uint256 amountIn = adapter.getAmountIn(pair, address(quoteToken), desiredOut);

        uint256 actualOut = adapter.getAmountOut(pair, address(baseToken), amountIn);
        assertGe(actualOut, desiredOut, "getAmountIn sell with fee round-trip");
    }

    // ── Liquidity ──────────────────────────────────────────

    /// @notice addLiquidity mints LP tokens
    function test_addLiquidity() public {
        uint256 baseAmount = 10_000 ether;
        uint256 quote = 10 ether;

        baseToken.mint(address(adapter), baseAmount);
        quoteToken.mint(address(adapter), quote);

        address recipient = makeAddr("lpRecipient");
        uint256 liquidity =
            adapter.addLiquidity(pair, address(baseToken), address(quoteToken), baseAmount, quote, recipient);

        assertGt(liquidity, 0, "Should receive LP tokens");
        assertEq(IERC20(pair).balanceOf(recipient), liquidity, "Recipient should hold LP tokens");
    }

    /// @notice removeLiquidity burns LP and returns tokens
    function test_removeLiquidity() public {
        // First add some liquidity to get LP tokens
        uint256 baseAmount = 10_000 ether;
        uint256 quote = 10 ether;

        baseToken.mint(address(adapter), baseAmount);
        quoteToken.mint(address(adapter), quote);

        uint256 liquidity =
            adapter.addLiquidity(pair, address(baseToken), address(quoteToken), baseAmount, quote, address(this));

        // Now remove liquidity via adapter
        IERC20(pair).transfer(address(adapter), liquidity);

        address recipient = makeAddr("removeRecipient");
        (uint256 amount0, uint256 amount1) = adapter.removeLiquidity(pair, liquidity, recipient);

        assertGt(amount0, 0, "Should receive token0");
        assertGt(amount1, 0, "Should receive token1");

        address token0 = INadFunPair(pair).token0();
        address token1 = INadFunPair(pair).token1();
        assertEq(IERC20(token0).balanceOf(recipient), amount0, "Recipient should receive token0");
        assertEq(IERC20(token1).balanceOf(recipient), amount1, "Recipient should receive token1");
    }

    // ── claimFees reverts ──────────────────────────────────

    /// @notice claimableFees reverts (V2 has no separate fee claiming)
    function test_claimableFees_reverts() public {
        vm.expectRevert(NadSwapAdapter.NoClaims.selector);
        adapter.claimableFees(pair, 0);
    }

    /// @notice claimFees reverts (V2 has no separate fee claiming)
    function test_claimFees_reverts() public {
        vm.expectRevert(NadSwapAdapter.NoClaims.selector);
        adapter.claimFees(pair, 0, address(this));
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
