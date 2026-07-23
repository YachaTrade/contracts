// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV3ExternalAdapter} from "../../src/adapters/UniswapV3ExternalAdapter.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {MockCapricornPool} from "../mocks/MockCapricornPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev P5-2: direct pool.swap V3 adapter (Capricorn CL). Plan:
///      docs/plans/2026-06-11-dividend-vault-p5-routing-design.md §5.
contract UniswapV3ExternalAdapterTest is Test {
    UniswapV3ExternalAdapter adapter;
    MockERC20 wnative; // quote side (tokenIn in the vault flow)
    MockERC20 v1Meme; // V1 graduated token side
    MockCapricornPool pool;

    uint256 constant POOL_LIQ = 1_000 ether;

    function setUp() public {
        wnative = new MockERC20("WNATIVE", "WNATIVE", 18);
        v1Meme = new MockERC20("V1MEME", "V1MEME", 18);
        (address token0, address token1) = address(wnative) < address(v1Meme)
            ? (address(wnative), address(v1Meme))
            : (address(v1Meme), address(wnative));
        pool = new MockCapricornPool(token0, token1);
        wnative.mint(address(pool), POOL_LIQ);
        v1Meme.mint(address(pool), POOL_LIQ);
        adapter = new UniswapV3ExternalAdapter();
    }

    // ── 정상 스왑 (push 패턴, 양방향) ──────────────────────────────────────

    function test_swap_pushesAndSendsOutput() public {
        pool.setRate(2, 1); // out = 2 * in (so in/out are distinguishable)
        uint256 amountIn = 1 ether;
        wnative.mint(address(adapter), amountIn); // push pattern: caller pre-funds the adapter

        uint256 amountOut = adapter.swap(address(pool), address(wnative), address(v1Meme), amountIn, address(this), "");

        assertEq(amountOut, 2 ether, "returns pool output");
        assertEq(v1Meme.balanceOf(address(this)), 2 ether, "recipient received tokenOut");
        assertEq(wnative.balanceOf(address(pool)), POOL_LIQ + amountIn, "pool received full input");
        assertEq(wnative.balanceOf(address(adapter)), 0, "adapter holds nothing at rest");
    }

    function test_swap_reverseDirection() public {
        // tokenIn = v1Meme covers the opposite zeroForOne branch of the WNATIVE direction.
        uint256 amountIn = 3 ether;
        v1Meme.mint(address(adapter), amountIn);

        uint256 amountOut = adapter.swap(address(pool), address(v1Meme), address(wnative), amountIn, address(this), "");

        assertEq(amountOut, 3 ether); // rate 1:1
        assertEq(wnative.balanceOf(address(this)), 3 ether);
        assertEq(v1Meme.balanceOf(address(pool)), POOL_LIQ + amountIn);
    }

    function test_swap_uniswapV3CallbackSelector() public {
        // Standard V3 forks call uniswapV3SwapCallback instead of capricornCLSwapCallback —
        // the adapter implements both selectors over the same logic.
        pool.setCallbackMode(MockCapricornPool.CallbackMode.UniswapV3);
        uint256 amountIn = 1 ether;
        wnative.mint(address(adapter), amountIn);

        uint256 amountOut = adapter.swap(address(pool), address(wnative), address(v1Meme), amountIn, address(this), "");
        assertEq(amountOut, 1 ether);
        assertEq(v1Meme.balanceOf(address(this)), 1 ether);
    }

    function test_swap_pancakeV3CallbackSelector() public {
        // Pancake V3 forks call pancakeV3SwapCallback — third selector over the same handler.
        pool.setCallbackMode(MockCapricornPool.CallbackMode.PancakeV3);
        uint256 amountIn = 1 ether;
        wnative.mint(address(adapter), amountIn);

        uint256 amountOut = adapter.swap(address(pool), address(wnative), address(v1Meme), amountIn, address(this), "");
        assertEq(amountOut, 1 ether);
        assertEq(v1Meme.balanceOf(address(this)), 1 ether);
    }

    // ── 부분 체결 (codex review #5) ───────────────────────────────────────

    function test_swap_partialFill_refundsLeftoverToCaller() public {
        // Pool consumes only half the input (liquidity exhausted). The adapter must refund the
        // unconsumed half to msg.sender so the vault's balance-delta accounting (consumed =
        // quoteBefore - quoteAfter) leaves the rest in pendingSwap instead of treating it as spent.
        pool.setFillBps(5_000);
        uint256 amountIn = 2 ether;
        wnative.mint(address(adapter), amountIn);

        uint256 amountOut = adapter.swap(address(pool), address(wnative), address(v1Meme), amountIn, address(this), "");

        assertEq(amountOut, 1 ether, "output for the consumed half");
        assertEq(wnative.balanceOf(address(this)), 1 ether, "unconsumed input refunded to caller");
        assertEq(wnative.balanceOf(address(pool)), POOL_LIQ + 1 ether, "pool only received the consumed half");
        assertEq(wnative.balanceOf(address(adapter)), 0, "adapter holds nothing at rest");
    }

    // ── 가드 / 콜백 보안 (codex review #3, #4) ────────────────────────────

    function test_swap_revertsOnZeroPool() public {
        wnative.mint(address(adapter), 1 ether);
        vm.expectRevert(UniswapV3ExternalAdapter.NoPair.selector);
        adapter.swap(address(0), address(wnative), address(v1Meme), 1 ether, address(this), "");
    }

    function test_swap_revertsOnTokenMismatch() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 18);
        wnative.mint(address(adapter), 1 ether);
        vm.expectRevert(UniswapV3ExternalAdapter.TokenMismatch.selector);
        adapter.swap(address(pool), address(wnative), address(other), 1 ether, address(this), "");
    }

    function test_callback_directSpoof_reverts() public {
        // No swap in progress — a direct callback from any caller must be rejected.
        vm.expectRevert(UniswapV3ExternalAdapter.NotExpectedPool.selector);
        adapter.capricornCLSwapCallback(
            int256(1 ether), -int256(1 ether), abi.encode(address(wnative), uint256(1 ether))
        );

        vm.expectRevert(UniswapV3ExternalAdapter.NotExpectedPool.selector);
        adapter.uniswapV3SwapCallback(int256(1 ether), -int256(1 ether), abi.encode(address(wnative), uint256(1 ether)));

        vm.expectRevert(UniswapV3ExternalAdapter.NotExpectedPool.selector);
        adapter.pancakeV3SwapCallback(int256(1 ether), -int256(1 ether), abi.encode(address(wnative), uint256(1 ether)));
    }

    function test_swap_noCallback_reverts() public {
        // A pool returning without ever calling back must not be treated as a successful swap.
        pool.setCallbackMode(MockCapricornPool.CallbackMode.None);
        wnative.mint(address(adapter), 1 ether);
        vm.expectRevert(UniswapV3ExternalAdapter.NoCallback.selector);
        adapter.swap(address(pool), address(wnative), address(v1Meme), 1 ether, address(this), "");
    }

    function test_swap_doubleCallback_reverts() public {
        // The first callback clears the expected pool; a second one must be rejected,
        // reverting the whole swap.
        pool.setCallbackMode(MockCapricornPool.CallbackMode.Double);
        wnative.mint(address(adapter), 1 ether);
        vm.expectRevert(UniswapV3ExternalAdapter.NotExpectedPool.selector);
        adapter.swap(address(pool), address(wnative), address(v1Meme), 1 ether, address(this), "");
    }

    function test_swap_bothPositiveDeltas_reverts() public {
        // Corrupt pool reporting both deltas positive: exactly one positive delta is required.
        pool.setCallbackMode(MockCapricornPool.CallbackMode.BothPositive);
        wnative.mint(address(adapter), 1 ether);
        vm.expectRevert(UniswapV3ExternalAdapter.InvalidDelta.selector);
        adapter.swap(address(pool), address(wnative), address(v1Meme), 1 ether, address(this), "");
    }

    function test_swap_excessiveInput_reverts() public {
        // Greedy pool demanding more input than the adapter was given must revert,
        // never silently underpay or strand the swap.
        pool.setFillBps(12_000);
        uint256 amountIn = 1 ether;
        wnative.mint(address(adapter), amountIn);
        vm.expectRevert(UniswapV3ExternalAdapter.ExcessiveInput.selector);
        adapter.swap(address(pool), address(wnative), address(v1Meme), amountIn, address(this), "");
    }

    function test_swap_reentrancy_blocked() public {
        // A pool re-calling adapter.swap mid-swap (while the expected-pool guard is armed)
        // must hit SwapInProgress. The outer swap then completes normally.
        pool.setCallbackMode(MockCapricornPool.CallbackMode.Reenter);
        pool.setReenterCall(
            abi.encodeCall(
                IDexAdapter.swap, (address(pool), address(wnative), address(v1Meme), 1, address(this), bytes(""))
            )
        );
        uint256 amountIn = 1 ether;
        wnative.mint(address(adapter), amountIn);

        uint256 amountOut = adapter.swap(address(pool), address(wnative), address(v1Meme), amountIn, address(this), "");

        assertEq(amountOut, 1 ether, "outer swap completes");
        assertTrue(pool.reenterReverted(), "nested swap rejected");
        assertEq(bytes4(pool.reenterRevertData()), UniswapV3ExternalAdapter.SwapInProgress.selector);
    }

    // ── 미지원 IDexAdapter 함수 ───────────────────────────────────────────

    function test_unsupportedFunctions_revert() public {
        vm.expectRevert(UniswapV3ExternalAdapter.NotSupported.selector);
        adapter.getAmountOut(address(pool), address(wnative), 1 ether);
        vm.expectRevert(UniswapV3ExternalAdapter.NotSupported.selector);
        adapter.getAmountIn(address(pool), address(v1Meme), 1 ether);
        vm.expectRevert(UniswapV3ExternalAdapter.NotSupported.selector);
        adapter.addLiquidity(address(pool), address(wnative), address(v1Meme), 1, 1, address(this));
        vm.expectRevert(UniswapV3ExternalAdapter.NotSupported.selector);
        adapter.removeLiquidity(address(pool), 1, address(this));
        vm.expectRevert(UniswapV3ExternalAdapter.NotSupported.selector);
        adapter.claimableFees(address(pool), 1);
        vm.expectRevert(UniswapV3ExternalAdapter.NotSupported.selector);
        adapter.claimFees(address(pool), 1, address(this));
    }
}
