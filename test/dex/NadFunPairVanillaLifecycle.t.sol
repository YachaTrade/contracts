// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice End-to-end DEX lifecycle for a plain ERC20 pair with no NadFun token lifecycle.
contract NadFunPairVanillaLifecycleTest is Test {
    MockERC20 private quoteToken;
    MockERC20 private baseToken;
    NadFunFactory private factory;
    FeeCollector private feeCollector;
    INadFunPair private pair;

    address private lp = makeAddr("lp");
    address private trader = makeAddr("trader");

    uint256 private constant INITIAL_BASE_LIQ = 100_000 ether;
    uint256 private constant INITIAL_QUOTE_LIQ = 100 ether;

    function setUp() public {
        quoteToken = new MockERC20("Quote", "QUOTE", 18);
        baseToken = new MockERC20("Base", "BASE", 18);

        ProtocolManager protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()),
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
                        (
                            address(protocolManager),
                            makeAddr("creatorFeeProcessor"),
                            makeAddr("bondingCurve"),
                            makeAddr("router")
                        )
                    )
                )
            )
        );

        factory = new NadFunFactory(address(this), address(feeCollector), address(new NadFunPair()));
        pair = INadFunPair(factory.createPair(address(baseToken), address(quoteToken)));
    }

    function test_vanillaDex_createPair_addLiquidity_buyAndSell() public {
        assertEq(factory.getPair(address(baseToken), address(quoteToken)), address(pair), "pair not registered");
        assertEq(factory.getPair(address(quoteToken), address(baseToken)), address(pair), "reverse pair not registered");

        baseToken.mint(address(pair), INITIAL_BASE_LIQ);
        quoteToken.mint(address(pair), INITIAL_QUOTE_LIQ);
        uint256 lpAmount = pair.mint(lp);

        assertGt(lpAmount, 0, "LP should be minted");
        assertEq(IERC20(address(pair)).balanceOf(lp), lpAmount, "LP recipient mismatch");

        _assertReservesInitialized();

        uint256 baseOut = _swapExactIn(address(quoteToken), 1 ether, address(baseToken));
        assertEq(baseToken.balanceOf(trader), baseOut, "buy output mismatch");
        assertEq(quoteToken.balanceOf(address(feeCollector)), 0, "vanilla pair should not collect fees");

        uint256 baseIn = baseOut / 2;
        uint256 quoteOut = _swapExactInFromTrader(address(baseToken), baseIn, address(quoteToken));

        assertEq(baseToken.balanceOf(trader), baseOut - baseIn, "sell input not debited");
        assertEq(quoteToken.balanceOf(trader), quoteOut, "sell output mismatch");
        assertEq(quoteToken.balanceOf(address(feeCollector)), 0, "vanilla sell should not collect fees");

        uint256 exactBaseOut = 100 ether;
        uint256 quoteInForExactBase = _swapExactOut(address(quoteToken), address(baseToken), exactBaseOut);
        assertEq(baseToken.balanceOf(trader), baseOut - baseIn + exactBaseOut, "exact-out buy mismatch");
        assertGt(quoteInForExactBase, 0, "exact-out buy should require quote input");

        uint256 exactQuoteOut = 0.1 ether;
        uint256 baseInForExactQuote = _swapExactOut(address(baseToken), address(quoteToken), exactQuoteOut);
        assertEq(quoteToken.balanceOf(trader), quoteOut + exactQuoteOut, "exact-out sell mismatch");
        assertGt(baseInForExactQuote, 0, "exact-out sell should require base input");
        assertEq(quoteToken.balanceOf(address(feeCollector)), 0, "exact-out vanilla swaps should not collect fees");
    }

    function _assertReservesInitialized() private view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertGt(reserve0, 0, "reserve0 not initialized");
        assertGt(reserve1, 0, "reserve1 not initialized");
    }

    function _swapExactIn(address tokenIn, uint256 amountIn, address tokenOut) private returns (uint256 amountOut) {
        amountOut = pair.getAmountOut(tokenIn, amountIn);
        MockERC20(tokenIn).mint(address(pair), amountIn);
        uint256 balanceBefore = MockERC20(tokenOut).balanceOf(trader);
        _swapOut(tokenOut, amountOut, trader);
        assertEq(MockERC20(tokenOut).balanceOf(trader) - balanceBefore, amountOut, "exact-in output mismatch");
    }

    function _swapExactInFromTrader(address tokenIn, uint256 amountIn, address tokenOut)
        private
        returns (uint256 amountOut)
    {
        amountOut = pair.getAmountOut(tokenIn, amountIn);
        vm.prank(trader);
        MockERC20(tokenIn).transfer(address(pair), amountIn);
        uint256 balanceBefore = MockERC20(tokenOut).balanceOf(trader);
        _swapOut(tokenOut, amountOut, trader);
        assertEq(MockERC20(tokenOut).balanceOf(trader) - balanceBefore, amountOut, "exact-in trader output mismatch");
    }

    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut) private returns (uint256 amountIn) {
        amountIn = pair.getAmountIn(tokenOut, amountOut);
        MockERC20(tokenIn).mint(address(pair), amountIn);
        uint256 balanceBefore = MockERC20(tokenOut).balanceOf(trader);
        _swapOut(tokenOut, amountOut, trader);
        assertEq(MockERC20(tokenOut).balanceOf(trader) - balanceBefore, amountOut, "exact-out output mismatch");
    }

    function _swapOut(address tokenOut, uint256 amountOut, address to) private {
        if (tokenOut == pair.token0()) {
            pair.swap(amountOut, 0, to, "");
        } else {
            pair.swap(0, amountOut, to, "");
        }
    }
}
