// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV2ExternalAdapter} from "../../src/adapters/UniswapV2ExternalAdapter.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniswapV2ExternalAdapterTest is Test {
    UniswapV2ExternalAdapter adapter;
    MockERC20 quote;
    MockERC20 usdt;
    MockUniswapV2Pair pair;

    function setUp() public {
        quote = new MockERC20("WMON", "WMON", 18);
        usdt = new MockERC20("USDT", "USDT", 18);
        (address t0, address t1) =
            address(quote) < address(usdt) ? (address(quote), address(usdt)) : (address(usdt), address(quote));
        pair = new MockUniswapV2Pair(t0, t1);
        quote.mint(address(pair), 100 ether);
        usdt.mint(address(pair), 100 ether);
        pair.sync();
        adapter = new UniswapV2ExternalAdapter();
    }

    function test_getAmountOut_v2Formula() public view {
        uint256 amountIn = 1 ether;
        uint256 amountInWithFee = amountIn * 997;
        uint256 expected = (amountInWithFee * 100 ether) / (100 ether * 1000 + amountInWithFee);
        assertEq(adapter.getAmountOut(address(pair), address(quote), amountIn), expected);
    }

    function test_swap_pushesAndReturnsAmountOut() public {
        uint256 amountIn = 1 ether;
        uint256 expectedOut = adapter.getAmountOut(address(pair), address(quote), amountIn);
        quote.mint(address(adapter), amountIn); // push pattern
        uint256 out = adapter.swap(address(pair), address(quote), address(usdt), amountIn, address(this), "");
        assertEq(out, expectedOut);
        assertEq(usdt.balanceOf(address(this)), expectedOut);
    }

    function test_swap_revertsOnTokenMismatch() public {
        // tokenOut not in the pair (use a third token)
        MockERC20 other = new MockERC20("OTHER", "OTHER", 18);
        quote.mint(address(adapter), 1 ether);
        vm.expectRevert(UniswapV2ExternalAdapter.TokenMismatch.selector);
        adapter.swap(address(pair), address(quote), address(other), 1 ether, address(this), "");
    }
}
