// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {INadFunRouter02} from "../../src/interfaces/INadFunRouter02.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract RouterSwapTest is SetUp {
    /// @dev Graduate a quoteToken-quoted NadFun token; returns token + its (real, fee-configured) pair.
    function _graduatedToken() internal returns (address token, address pair) {
        token = _createToken();
        _skipAntiSniping();
        _graduateToken(token);
        pair = nadFunFactory.getPair(token, address(quoteToken));
        require(pair != address(0), "pair");
    }

    /// @dev Plain MockERC20 + wmon pool seeded 1_000_000:1_000. Returns token + pair.
    function _seedWmonPair(string memory name) internal returns (address token, address pair) {
        MockERC20 t = new MockERC20(name, name, 18);
        token = address(t);
        uint256 tAmt = 1_000_000 ether;
        uint256 wAmt = 1_000 ether;
        t.mint(address(this), tAmt);
        vm.deal(address(this), wAmt);
        wmon.deposit{value: wAmt}();
        t.approve(address(nadFunRouter), type(uint256).max);
        t.approve(address(nadFunRouter02), type(uint256).max);
        wmon.approve(address(nadFunRouter), type(uint256).max);
        wmon.approve(address(nadFunRouter02), type(uint256).max);
        nadFunRouter02.addLiquidity(token, address(wmon), tAmt, wAmt, 0, 0, address(this), block.timestamp + 1);
        pair = nadFunFactory.getPair(token, address(wmon));
        require(pair != address(0), "wmon pair");
    }

    /// @dev Give `who` `token` by buying on the graduated bonding curve with `quoteAmt` quoteToken.
    function _buyToken(address who, address token, uint256 quoteAmt) internal {
        quoteToken.mint(who, quoteAmt);
        vm.startPrank(who);
        quoteToken.approve(address(nadFunRouter), type(uint256).max);
        quoteToken.approve(address(nadFunRouter02), type(uint256).max);
        nadFunRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: quoteAmt, amountOutMin: 0, token: token, to: who, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════
    //  Task 1: getAmountsOut / getAmountsIn
    // ═══════════════════════════════════════════════

    function test_getAmountsOut_feeAware_matchesPairView() public {
        (address token, address pair) = _graduatedToken();
        address[] memory path = new address[](2);
        path[0] = address(quoteToken);
        path[1] = token;
        uint256 expected = INadFunPair(pair).getAmountOut(address(quoteToken), 1 ether);
        uint256[] memory amounts = nadFunRouter02.getAmountsOut(1 ether, path);
        assertEq(amounts.length, 2);
        assertEq(amounts[0], 1 ether);
        assertEq(amounts[1], expected, "fee-aware out matches pair");
    }

    function test_getAmountsIn_feeAware_matchesPairView() public {
        (address token, address pair) = _graduatedToken();
        address[] memory path = new address[](2);
        path[0] = address(quoteToken);
        path[1] = token;
        uint256 expectedIn = INadFunPair(pair).getAmountIn(token, 1 ether);
        uint256[] memory amounts = nadFunRouter02.getAmountsIn(1 ether, path);
        assertEq(amounts[1], 1 ether);
        assertEq(amounts[0], expectedIn, "fee-aware in matches pair");
    }

    // ═══════════════════════════════════════════════
    //  Task 2: swapExactTokensForTokens + swapTokensForExactTokens
    // ═══════════════════════════════════════════════

    function test_swapExactTokensForTokens_singleHop() public {
        (address token,) = _graduatedToken();
        _buyToken(user2, token, 1_000 ether);
        uint256 tokenBal = IERC20Like(token).balanceOf(user2);
        vm.startPrank(user2);
        IERC20Like(token).approve(address(nadFunRouter), type(uint256).max);
        IERC20Like(token).approve(address(nadFunRouter02), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(quoteToken);
        uint256[] memory expected = nadFunRouter02.getAmountsOut(tokenBal, path);
        uint256 qBefore = quoteToken.balanceOf(user2);
        uint256[] memory amounts =
            nadFunRouter02.swapExactTokensForTokens(tokenBal, 0, path, user2, block.timestamp + 1);
        vm.stopPrank();
        assertEq(amounts[1], expected[1], "out matches fee-aware quote");
        assertEq(quoteToken.balanceOf(user2), qBefore + amounts[1], "received quote");
    }

    function test_swapExactTokensForTokens_revertsSlippage() public {
        (address token,) = _graduatedToken();
        _buyToken(user2, token, 1_000 ether);
        uint256 tokenBal = IERC20Like(token).balanceOf(user2);
        vm.startPrank(user2);
        IERC20Like(token).approve(address(nadFunRouter), type(uint256).max);
        IERC20Like(token).approve(address(nadFunRouter02), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(quoteToken);
        vm.expectRevert(INadFunRouter02.InsufficientOutput.selector);
        nadFunRouter02.swapExactTokensForTokens(tokenBal, type(uint256).max, path, user2, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_swapTokensForExactTokens() public {
        (address token,) = _graduatedToken();
        // user2 has quoteToken, wants an exact token amount out
        uint256 exactOut = 1 ether;
        address[] memory path = new address[](2);
        path[0] = address(quoteToken);
        path[1] = token;
        uint256[] memory expectedIn = nadFunRouter02.getAmountsIn(exactOut, path);
        quoteToken.mint(user2, expectedIn[0] * 2);
        vm.startPrank(user2);
        quoteToken.approve(address(nadFunRouter), type(uint256).max);
        quoteToken.approve(address(nadFunRouter02), type(uint256).max);
        uint256 tBefore = IERC20Like(token).balanceOf(user2);
        uint256[] memory amounts =
            nadFunRouter02.swapTokensForExactTokens(exactOut, expectedIn[0] * 2, path, user2, block.timestamp + 1);
        vm.stopPrank();
        assertEq(amounts[0], expectedIn[0], "input matches fee-aware quote");
        assertEq(IERC20Like(token).balanceOf(user2), tBefore + exactOut, "received exact out");
    }

    function test_swapExactTokensForTokens_multiHop() public {
        (address tokenA,) = _seedWmonPair("HOPA");
        (address tokenB,) = _seedWmonPair("HOPB");
        uint256 amtIn = 1_000 ether;
        MockERC20(tokenA).mint(user2, amtIn);
        vm.startPrank(user2);
        MockERC20(tokenA).approve(address(nadFunRouter), type(uint256).max);
        MockERC20(tokenA).approve(address(nadFunRouter02), type(uint256).max);
        address[] memory path = new address[](3);
        path[0] = tokenA;
        path[1] = address(wmon);
        path[2] = tokenB;
        uint256[] memory expected = nadFunRouter02.getAmountsOut(amtIn, path);
        uint256 bBefore = IERC20Like(tokenB).balanceOf(user2);
        uint256[] memory amounts = nadFunRouter02.swapExactTokensForTokens(amtIn, 0, path, user2, block.timestamp + 1);
        vm.stopPrank();
        assertEq(amounts[2], expected[2], "multi-hop out matches quote");
        assertEq(IERC20Like(tokenB).balanceOf(user2), bBefore + amounts[2], "received tokenB");
    }

    // ═══════════════════════════════════════════════
    //  Task 3: ETH swap variants
    // ═══════════════════════════════════════════════

    function test_swapExactETHForTokens() public {
        (address token,) = _seedWmonPair("ETHIN");
        address[] memory path = new address[](2);
        path[0] = address(wmon);
        path[1] = token;
        vm.deal(user2, 10 ether);
        vm.startPrank(user2);
        uint256[] memory expected = nadFunRouter02.getAmountsOut(1 ether, path);
        uint256 before = IERC20Like(token).balanceOf(user2);
        uint256[] memory amounts =
            nadFunRouter02.swapExactETHForTokens{value: 1 ether}(0, path, user2, block.timestamp + 1);
        vm.stopPrank();
        assertEq(amounts[1], expected[1]);
        assertEq(IERC20Like(token).balanceOf(user2), before + amounts[1]);
    }

    function test_swapExactTokensForETH() public {
        (address token,) = _seedWmonPair("ETHOUT");
        MockERC20(token).mint(user2, 1_000 ether);
        vm.startPrank(user2);
        MockERC20(token).approve(address(nadFunRouter), type(uint256).max);
        MockERC20(token).approve(address(nadFunRouter02), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(wmon);
        uint256 ethBefore = user2.balance;
        uint256[] memory amounts =
            nadFunRouter02.swapExactTokensForETH(1_000 ether, 0, path, user2, block.timestamp + 1);
        vm.stopPrank();
        assertEq(user2.balance, ethBefore + amounts[1], "received native MON");
    }

    function test_swapETHForExactTokens_refundsExcess() public {
        (address token,) = _seedWmonPair("ETHEXACT");
        address[] memory path = new address[](2);
        path[0] = address(wmon);
        path[1] = token;
        uint256 exactOut = 1_000 ether; // token
        uint256[] memory needed = nadFunRouter02.getAmountsIn(exactOut, path);
        vm.deal(user2, 100 ether);
        vm.startPrank(user2);
        uint256 ethBefore = user2.balance;
        uint256 tBefore = IERC20Like(token).balanceOf(user2);
        uint256[] memory amounts =
            nadFunRouter02.swapETHForExactTokens{value: 100 ether}(exactOut, path, user2, block.timestamp + 1);
        vm.stopPrank();
        assertEq(amounts[0], needed[0], "input matches quote");
        assertEq(IERC20Like(token).balanceOf(user2), tBefore + exactOut, "received exact tokens");
        assertEq(user2.balance, ethBefore - amounts[0], "excess native refunded");
    }

    // ═══════════════════════════════════════════════
    //  Task 4: SupportingFeeOnTransfer swap variants
    // ═══════════════════════════════════════════════

    function test_swapExactTokensForTokensSupportingFOT_matchesPlain() public {
        (address token,) = _graduatedToken();
        _buyToken(user2, token, 1_000 ether);
        uint256 tokenBal = IERC20Like(token).balanceOf(user2);
        vm.startPrank(user2);
        IERC20Like(token).approve(address(nadFunRouter), type(uint256).max);
        IERC20Like(token).approve(address(nadFunRouter02), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(quoteToken);
        uint256[] memory expected = nadFunRouter02.getAmountsOut(tokenBal, path);
        uint256 qBefore = quoteToken.balanceOf(user2);
        nadFunRouter02.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenBal, 0, path, user2, block.timestamp + 1
        );
        vm.stopPrank();
        assertEq(quoteToken.balanceOf(user2) - qBefore, expected[1], "FOT equals plain for non-FOT token");
    }

    // ═══════════════════════════════════════════════
    //  Fee-aware correctness guarantee
    // ═══════════════════════════════════════════════

    /// @dev Pins the core design guarantee: the router quote is the pair's FEE-AWARE amount,
    ///      NOT the vanilla 0.3% (997/1000) amount, and the swap actually executes at that amount.
    function test_swap_isFeeAware_notVanilla() public {
        (address token,) = _graduatedToken();
        address pair = nadFunFactory.getPair(token, address(quoteToken));
        (uint112 r0, uint112 r1,) = INadFunPair(pair).getReserves();

        address[] memory path = new address[](2);
        path[0] = address(quoteToken);
        path[1] = token;

        uint256 amountIn = 1 ether;
        uint256 feeAware = nadFunRouter02.getAmountsOut(amountIn, path)[1];

        // vanilla 0.3% (997/1000) estimate on the same reserves
        (uint256 reserveIn, uint256 reserveOut) =
            address(quoteToken) < token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 vanillaInWithFee = amountIn * 997;
        uint256 vanilla = (vanillaInWithFee * reserveOut) / (reserveIn * 1000 + vanillaInWithFee);

        assertTrue(feeAware != vanilla, "router quote must be fee-aware, not vanilla 0.3%");

        // And the swap must actually execute at the fee-aware amount (pair K passes).
        quoteToken.mint(user2, amountIn);
        vm.startPrank(user2);
        quoteToken.approve(address(nadFunRouter), type(uint256).max);
        quoteToken.approve(address(nadFunRouter02), type(uint256).max);
        uint256[] memory amounts =
            nadFunRouter02.swapExactTokensForTokens(amountIn, 0, path, user2, block.timestamp + 1);
        vm.stopPrank();
        assertEq(amounts[1], feeAware, "executed at fee-aware amount");
    }
}
