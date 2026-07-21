// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for NadFunRouter.

import {console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {NadFunRouter} from "../../src/router/NadFunRouter.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {MockLvMonMinter} from "../mocks/MockLvMonMinter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract NadFunRouterTest is SetUp {
    NadFunRouter router;
    MockERC20 lvmon;
    MockLvMonMinter lvmonMinter;

    address vault;
    address token;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");

        wmon = new MockWMON();
        lvmon = new MockERC20("Liquid Staked MON", "LVMON", 18);
        lvmonMinter = new MockLvMonMinter(admin, address(0), address(wmon), address(lvmon));

        // Replace quoteToken with MockWMON, keep real modules
        vm.startPrank(admin);

        protocolManager.removeQuoteToken(address(quoteToken));
        protocolManager.addQuoteToken(
            address(wmon),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee,
            0
        );
        protocolManager.addQuoteToken(
            address(lvmon),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee,
            0
        );

        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));
        vm.stopPrank();

        // Deploy NadFunRouter (UUPS proxy)
        NadFunRouter routerImpl = new NadFunRouter();
        router = NadFunRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(routerImpl),
                        abi.encodeCall(
                            NadFunRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wmon),
                                address(lvmonMinter)
                            )
                        )
                    )
                ))
        );

        // Fund MockWMON with ETH for native tests
        vm.deal(address(wmon), 1000 ether);

        // Transfer deployFee to bondingCurve before create (balance detection)
        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        // Create token
        (token,) = bondingCurve.create(_nadFunDefaultParams());

        // Skip past anti-sniping
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    function test_exactOutBuy_bondingCurve() public {
        uint256 desiredTokens = 1000 ether;
        uint256 maxQuoteIn = 5 ether;

        wmon.mint(user1, maxQuoteIn);
        vm.startPrank(user1);
        wmon.approve(address(router), maxQuoteIn);

        uint256 amountIn = router.exactOutBuy(
            INadFunRouter.ExactOutBuyParams({
                amountInMax: maxQuoteIn,
                amountOut: desiredTokens,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        // V2: user receives full desiredTokens (creator fee on quote, not token transfer)
        uint256 tokenBalance = IERC20(token).balanceOf(user1);
        assertGe(tokenBalance, desiredTokens, "Should receive at least desired tokens");
        assertApproxEqAbs(tokenBalance, desiredTokens, 1e15, "Surplus from rounding should be small");
        assertLe(amountIn, maxQuoteIn, "Should not exceed max input");
        assertEq(wmon.balanceOf(user1), maxQuoteIn - amountIn, "Refund should match");
    }

    function test_exactOutBuyWithNative_bondingCurve() public {
        uint256 desiredTokens = 1000 ether;
        uint256 maxNativeIn = 5 ether;
        vm.deal(user1, maxNativeIn);

        vm.prank(user1);
        uint256 amountIn = router.exactOutBuyWithNative{value: maxNativeIn}(
            INadFunRouter.ExactOutBuyWithNativeParams({
                amountOut: desiredTokens, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        // V2: user receives full desiredTokens (creator fee on quote, not token transfer)
        assertGe(IERC20(token).balanceOf(user1), desiredTokens, "Should receive at least desired tokens");
        assertApproxEqAbs(IERC20(token).balanceOf(user1), desiredTokens, 1e15, "Surplus from rounding should be small");
        assertEq(user1.balance, maxNativeIn - amountIn, "Native refund should match");
    }

    function test_exactOutBuyWithNative_lvmonQuote_mintsLvmon() public {
        address lvmonQuotedToken = _createLvmonQuotedToken();
        uint256 tokenOut = 1000 ether;
        uint256 nativeInMax = 5 ether;

        uint256 quoteIn = bondingCurve.getAmountIn(lvmonQuotedToken, tokenOut, true);

        vm.deal(user1, nativeInMax);
        vm.prank(user1);
        uint256 quoteInSpent = router.exactOutBuyWithNative{value: nativeInMax}(
            INadFunRouter.ExactOutBuyWithNativeParams({
                amountOut: tokenOut, token: lvmonQuotedToken, to: user1, deadline: block.timestamp + 1
            })
        );

        assertEq(quoteInSpent, quoteIn, "Quote spent should match getAmountIn");
        assertGe(IERC20(lvmonQuotedToken).balanceOf(user1), tokenOut, "Should receive at least desired tokens");
        assertApproxEqAbs(
            IERC20(lvmonQuotedToken).balanceOf(user1), tokenOut, 1e15, "Surplus from rounding should be small"
        );
        assertEq(user1.balance, nativeInMax - quoteInSpent, "Native refund should match");
        assertEq(lvmon.balanceOf(address(router)), 0, "Router should hold no LVMON");
        assertEq(address(lvmonMinter).balance, quoteInSpent, "LVMON minter should receive spent native");
    }

    function test_exactOutBuy_bondingCurve_doesNotSweepPreexistingQuoteBalance() public {
        uint256 donation = 7 ether;
        uint256 desiredTokens = 1000 ether;
        uint256 maxQuoteIn = 5 ether;

        wmon.mint(user2, donation);
        vm.prank(user2);
        wmon.transfer(address(router), donation);

        wmon.mint(user1, maxQuoteIn);
        vm.startPrank(user1);
        wmon.approve(address(router), maxQuoteIn);

        uint256 amountIn = router.exactOutBuy(
            INadFunRouter.ExactOutBuyParams({
                amountInMax: maxQuoteIn,
                amountOut: desiredTokens,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(wmon.balanceOf(user1), maxQuoteIn - amountIn, "User should receive only this call's refund");
        assertEq(wmon.balanceOf(address(router)), donation, "Router should retain pre-existing quote balance");
    }

    function test_exactOutBuyWithNative_bondingCurve_doesNotSweepPreexistingWmon() public {
        uint256 donation = 7 ether;
        uint256 desiredTokens = 1000 ether;
        uint256 maxNativeIn = 5 ether;

        wmon.mint(user2, donation);
        vm.prank(user2);
        wmon.transfer(address(router), donation);

        vm.deal(user1, maxNativeIn);
        vm.prank(user1);
        uint256 amountIn = router.exactOutBuyWithNative{value: maxNativeIn}(
            INadFunRouter.ExactOutBuyWithNativeParams({
                amountOut: desiredTokens, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        assertEq(user1.balance, maxNativeIn - amountIn, "User should receive only this call's native refund");
        assertEq(wmon.balanceOf(address(router)), donation, "Router should retain pre-existing WMON balance");
    }

    function test_exactOutBuy_excessiveInput_reverts() public {
        uint256 desiredTokens = 500_000_000 ether;
        uint256 tooLittle = 1 ether;

        wmon.mint(user1, tooLittle);
        vm.startPrank(user1);
        wmon.approve(address(router), tooLittle);

        vm.expectRevert(INadFunRouter.ExcessiveInput.selector);
        router.exactOutBuy(
            INadFunRouter.ExactOutBuyParams({
                amountInMax: tooLittle, amountOut: desiredTokens, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_exactOutBuy_expiredDeadline_reverts() public {
        wmon.mint(user1, 1 ether);
        vm.startPrank(user1);
        wmon.approve(address(router), 1 ether);

        vm.expectRevert(INadFunRouter.ExpiredDeadline.selector);
        router.exactOutBuy(
            INadFunRouter.ExactOutBuyParams({
                amountInMax: 1 ether, amountOut: 100 ether, token: token, to: user1, deadline: block.timestamp - 1
            })
        );
        vm.stopPrank();
    }

    function test_exactOutSell_bondingCurve() public {
        uint256 buyAmount = 2 ether;
        wmon.mint(user1, buyAmount);
        vm.startPrank(user1);
        wmon.approve(address(router), buyAmount);
        uint256 tokensOwned = router.buy(
            INadFunRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        uint256 desiredQuoteOut = 0.5 ether;
        IERC20(token).approve(address(router), tokensOwned);

        uint256 quoteBefore = wmon.balanceOf(user1);
        uint256 quoteOut = router.exactOutSell(
            INadFunRouter.ExactOutSellParams({
                amountInMax: tokensOwned,
                amountOut: desiredQuoteOut,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertGe(quoteOut, desiredQuoteOut, "Should receive at least desired quote");
        assertApproxEqAbs(
            quoteOut, desiredQuoteOut, 1, "Should receive desired quote (1 wei tolerance for fee rounding)"
        );
        assertGe(
            wmon.balanceOf(user1) - quoteBefore, desiredQuoteOut, "Balance should increase by at least desiredQuoteOut"
        );
    }

    function test_sell_emitsBondingCurveSellerAsRecipient() public {
        uint256 buyAmount = 2 ether;
        wmon.mint(user1, buyAmount);

        vm.startPrank(user1);
        wmon.approve(address(router), buyAmount);
        uint256 tokensOwned = router.buy(
            INadFunRouter.BuyParams({
                token: token, amountIn: buyAmount, amountOutMin: 0, to: user1, deadline: block.timestamp + 1
            })
        );

        IERC20(token).approve(address(router), tokensOwned);
        bytes32 sellTopic = keccak256("Sell(address,address,uint256,uint256)");

        vm.recordLogs();
        router.sell(
            INadFunRouter.SellParams({
                token: token, amountIn: tokensOwned, amountOutMin: 0, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundBondingCurveSell;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(bondingCurve) && logs[i].topics.length == 3 && logs[i].topics[0] == sellTopic
            ) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "sell event token");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), user1, "sell event seller");
                foundBondingCurveSell = true;
            }
        }
        assertTrue(foundBondingCurveSell, "BondingCurve Sell event not found");
    }

    function test_exactOutSellToNative_bondingCurve() public {
        uint256 buyAmount = 2 ether;
        wmon.mint(user1, buyAmount);
        vm.startPrank(user1);
        wmon.approve(address(router), buyAmount);
        uint256 tokensOwned = router.buy(
            INadFunRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        uint256 desiredNativeOut = 0.5 ether;
        IERC20(token).approve(address(router), tokensOwned);

        uint256 nativeBefore = user1.balance;
        uint256 nativeOut = router.exactOutSellToNative(
            INadFunRouter.ExactOutSellToNativeParams({
                amountInMax: tokensOwned,
                amountOut: desiredNativeOut,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertGe(nativeOut, desiredNativeOut, "Should receive at least desired native");
        assertApproxEqAbs(
            nativeOut, desiredNativeOut, 1, "Should receive desired native (1 wei tolerance for fee rounding)"
        );
        assertGe(user1.balance - nativeBefore, desiredNativeOut, "Native balance should increase by at least desired");
    }

    function test_exactOutSellToNative_graduated_sendsFullDexOutput() public {
        uint256 targetDustReserve = 30_000_000_000_000_000;
        uint256 desiredNativeOut = 10 ether;
        uint256 graduationAmount = 800_000 ether;

        wmon.mint(user1, graduationAmount);
        vm.startPrank(user1);
        wmon.transfer(address(bondingCurve), graduationAmount);
        bondingCurve.buy(user1, token);
        vm.stopPrank();

        assertTrue(bondingCurve.getCurve(token).graduated, "Token should be graduated");

        address pair = bondingCurve.getCurve(token).pair;
        uint256 tokenReserveBefore = _tokenReserve(pair, token);
        uint256 skewAmountOut = tokenReserveBefore - targetDustReserve;
        uint256 quoteRequired = INadFunPair(pair).getAmountIn(token, skewAmountOut);

        wmon.mint(user1, quoteRequired);
        vm.startPrank(user1);
        wmon.transfer(pair, quoteRequired);
        _swapOut(pair, token, skewAmountOut, user1);
        vm.stopPrank();

        uint256 tokenUsed = router.getAmountIn(token, desiredNativeOut, false);
        uint256 expectedNativeOut = router.getAmountOut(token, tokenUsed, false);
        assertGt(expectedNativeOut, desiredNativeOut, "Skewed pair should produce native surplus");

        uint256 nativeBefore = user1.balance;
        uint256 routerWmonBefore = wmon.balanceOf(address(router));

        vm.startPrank(user1);
        IERC20(token).approve(address(router), tokenUsed);
        uint256 nativeOut = router.exactOutSellToNative(
            INadFunRouter.ExactOutSellToNativeParams({
                amountInMax: tokenUsed,
                amountOut: desiredNativeOut,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(nativeOut, expectedNativeOut, "Router should return the full DEX output");
        assertEq(user1.balance - nativeBefore, expectedNativeOut, "Seller should receive the full native output");
        assertEq(wmon.balanceOf(address(router)) - routerWmonBefore, 0, "Router should not retain surplus WMON");
        assertEq(address(router).balance, 0, "Router should not retain native");
    }

    function test_exactOutSell_excessiveInput_reverts() public {
        wmon.mint(user1, 0.01 ether);
        vm.startPrank(user1);
        wmon.approve(address(router), 0.01 ether);
        uint256 tokensOwned = router.buy(
            INadFunRouter.BuyParams({
                amountIn: 0.01 ether, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        IERC20(token).approve(address(router), tokensOwned);
        vm.expectRevert();
        router.exactOutSell(
            INadFunRouter.ExactOutSellParams({
                amountInMax: tokensOwned, amountOut: 100 ether, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════
    //  buy — bonding curve exact amount
    // ═══════════════════════════════════════════════

    function test_buy_bondingCurve_exactAmount() public {
        uint256 amountIn = 2 ether;
        wmon.mint(user1, amountIn);

        // Pre-calculate expected values
        uint256 expectedTokenOut = bondingCurve.getAmountOut(token, amountIn, true);
        uint256 expectedQuoteIn = bondingCurve.getAmountIn(token, expectedTokenOut, true);
        if (expectedQuoteIn > amountIn) expectedQuoteIn = amountIn;

        vm.startPrank(user1);
        wmon.approve(address(router), amountIn);

        uint256 amountOut = router.buy(
            INadFunRouter.BuyParams({
                amountIn: amountIn, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(amountOut, expectedTokenOut, "Token out should match getAmountOut");
        assertEq(IERC20(token).balanceOf(user1), expectedTokenOut, "User token balance should match");
        assertEq(wmon.balanceOf(user1), amountIn - expectedQuoteIn, "User should keep unspent quote");
        assertEq(wmon.balanceOf(address(router)), 0, "Router should hold no quote");
    }

    function test_buyWithNative_bondingCurve_exactAmount() public {
        uint256 amountIn = 2 ether;

        // Pre-calculate expected values
        uint256 expectedTokenOut = bondingCurve.getAmountOut(token, amountIn, true);
        uint256 expectedQuoteIn = bondingCurve.getAmountIn(token, expectedTokenOut, true);
        if (expectedQuoteIn > amountIn) expectedQuoteIn = amountIn;
        uint256 expectedRefund = amountIn - expectedQuoteIn;

        vm.deal(user1, amountIn);
        vm.prank(user1);
        uint256 amountOut = router.buyWithNative{value: amountIn}(
            INadFunRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1})
        );

        assertEq(amountOut, expectedTokenOut, "Token out should match getAmountOut");
        assertEq(IERC20(token).balanceOf(user1), expectedTokenOut, "User token balance should match");
        assertEq(user1.balance, expectedRefund, "User should receive exact native refund");
        assertEq(wmon.balanceOf(address(router)), 0, "Router should hold no WMON");
        assertEq(address(router).balance, 0, "Router should hold no native");
    }

    function test_buyWithNative_lvmonQuote_mintsLvmon() public {
        address lvmonQuotedToken = _createLvmonQuotedToken();
        uint256 nativeIn = 2 ether;

        uint256 tokenOut = bondingCurve.getAmountOut(lvmonQuotedToken, nativeIn, true);
        uint256 quoteIn = bondingCurve.getAmountIn(lvmonQuotedToken, tokenOut, true);
        if (quoteIn > nativeIn) quoteIn = nativeIn;
        uint256 nativeRefund = nativeIn - quoteIn;

        vm.deal(user1, nativeIn);
        vm.prank(user1);
        uint256 tokenOutReceived = router.buyWithNative{value: nativeIn}(
            INadFunRouter.BuyWithNativeParams({
                amountOutMin: 0, token: lvmonQuotedToken, to: user1, deadline: block.timestamp + 1
            })
        );

        assertEq(tokenOutReceived, tokenOut, "Token out should match getAmountOut");
        assertEq(IERC20(lvmonQuotedToken).balanceOf(user1), tokenOut, "User token balance should match");
        assertEq(user1.balance, nativeRefund, "User should receive native refund");
        assertEq(lvmon.balanceOf(address(router)), 0, "Router should hold no LVMON");
        assertEq(address(router).balance, 0, "Router should hold no native");
        assertEq(address(lvmonMinter).balance, quoteIn, "LVMON minter should receive spent native");
    }

    // ═══════════════════════════════════════════════
    //  buy — near graduation refund
    // ═══════════════════════════════════════════════

    function test_buy_nearGraduation_noExcessToFeeReceiver() public {
        // Buy 90% of available tokens to approach graduation
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        uint256 availableTokens = curve.virtualTokenReserve - curve.minTokenReserve;
        uint256 targetTokens = availableTokens * 90 / 100;
        uint256 quoteNeeded = bondingCurve.getAmountIn(token, targetTokens, true);

        wmon.mint(user1, quoteNeeded);
        vm.startPrank(user1);
        wmon.approve(address(router), quoteNeeded);
        router.buy(
            INadFunRouter.BuyParams({
                amountIn: quoteNeeded, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        // Send 10x what's needed for remaining tokens
        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        uint256 remainingTokens = curveAfter.virtualTokenReserve - curveAfter.minTokenReserve;
        uint256 exactNeeded = bondingCurve.getAmountIn(token, remainingTokens, true);
        uint256 excessAmount = exactNeeded * 10;

        // Pre-calculate: router should only spend exactNeeded, not excessAmount
        uint256 expectedTokenOut = bondingCurve.getAmountOut(token, excessAmount, true);
        uint256 expectedQuoteIn = bondingCurve.getAmountIn(token, expectedTokenOut, true);
        if (expectedQuoteIn > excessAmount) expectedQuoteIn = excessAmount;

        wmon.mint(user2, excessAmount);
        vm.startPrank(user2);
        wmon.approve(address(router), excessAmount);
        uint256 expectedRefund = excessAmount - expectedQuoteIn;

        vm.expectEmit(true, true, false, true, address(wmon));
        emit IERC20.Transfer(user2, address(router), excessAmount);
        vm.expectEmit(true, true, false, true, address(wmon));
        emit IERC20.Transfer(address(router), address(bondingCurve), expectedQuoteIn);
        vm.expectEmit(true, true, false, true, address(wmon));
        emit IERC20.Transfer(address(router), user2, expectedRefund);
        router.buy(
            INadFunRouter.BuyParams({
                amountIn: excessAmount, amountOutMin: 0, token: token, to: user2, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(IERC20(token).balanceOf(user2), expectedTokenOut, "User should receive capped token amount");
        assertEq(wmon.balanceOf(user2), expectedRefund, "User should receive exact quote refund");
        assertEq(wmon.balanceOf(address(router)), 0, "Router should hold no quote");
    }

    function test_buyWithNative_nearGraduation_refundsExcess() public {
        // Buy 90% of available tokens first
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        uint256 availableTokens = curve.virtualTokenReserve - curve.minTokenReserve;
        uint256 targetTokens = availableTokens * 90 / 100;
        uint256 quoteNeeded = bondingCurve.getAmountIn(token, targetTokens, true);

        vm.deal(user1, quoteNeeded);
        vm.prank(user1);
        router.buyWithNative{value: quoteNeeded}(
            INadFunRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1})
        );

        // Send 10x what's needed for remaining tokens
        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        uint256 remainingTokens = curveAfter.virtualTokenReserve - curveAfter.minTokenReserve;
        uint256 exactNeeded = bondingCurve.getAmountIn(token, remainingTokens, true);
        uint256 excessAmount = exactNeeded * 10;

        // Pre-calculate
        uint256 expectedTokenOut = bondingCurve.getAmountOut(token, excessAmount, true);
        uint256 expectedQuoteIn = bondingCurve.getAmountIn(token, expectedTokenOut, true);
        if (expectedQuoteIn > excessAmount) expectedQuoteIn = excessAmount;
        uint256 expectedRefund = excessAmount - expectedQuoteIn;

        vm.deal(user2, excessAmount);
        vm.prank(user2);
        router.buyWithNative{value: excessAmount}(
            INadFunRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user2, deadline: block.timestamp + 1})
        );

        assertEq(IERC20(token).balanceOf(user2), expectedTokenOut, "User should receive capped token amount");
        assertEq(user2.balance, expectedRefund, "User should receive exact native refund");
        assertEq(address(router).balance, 0, "Router should hold no native");
        assertEq(wmon.balanceOf(address(router)), 0, "Router should hold no WMON");
    }

    // ── Unified quote — phase-aware getAmountOut / getAmountIn ──────

    function test_getAmountOut_preGraduation_matchesBondingCurve() public view {
        uint256 amountIn = 0.5 ether;
        uint256 unified = router.getAmountOut(token, amountIn, true);
        uint256 direct = bondingCurve.getAmountOut(token, amountIn, true);
        assertEq(unified, direct, "Pre-graduation getAmountOut should delegate to BondingCurve");
    }

    function test_getAmountIn_preGraduation_matchesBondingCurve() public view {
        uint256 amountOut = 1_000 ether;
        uint256 unified = router.getAmountIn(token, amountOut, true);
        uint256 direct = bondingCurve.getAmountIn(token, amountOut, true);
        assertEq(unified, direct, "Pre-graduation getAmountIn should delegate to BondingCurve");
    }

    function test_getAmountOut_postGraduation_matchesDex() public {
        // Graduate the token by pushing enough quote through BondingCurve.
        uint256 graduationAmount = 800_000 ether;
        wmon.mint(user1, graduationAmount);
        vm.startPrank(user1);
        wmon.transfer(address(bondingCurve), graduationAmount);
        bondingCurve.buy(user1, token);
        vm.stopPrank();
        assertTrue(bondingCurve.getCurve(token).graduated, "Setup: token must graduate");

        uint256 amountIn = 0.1 ether;
        uint256 unified = router.getAmountOut(token, amountIn, true);
        uint256 direct = router.getDexAmountOut(token, amountIn, true);
        assertEq(unified, direct, "Post-graduation getAmountOut should delegate to DEX");
    }

    function _nadFunDefaultParams() internal view returns (IBondingCurve.CreateTokenParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});
        params = IBondingCurve.CreateTokenParams({
            name: "RouterTest",
            symbol: "RT",
            tokenURI: "",
            quoteToken: address(wmon),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: keccak256("nadFunRouterTest"),
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }

    function _createLvmonQuotedToken() internal returns (address lvmonQuotedToken) {
        lvmon.mint(address(this), defaultDeployFee);
        lvmon.transfer(address(bondingCurve), defaultDeployFee);
        IBondingCurve.CreateTokenParams memory params = _nadFunDefaultParams();
        params.quoteToken = address(lvmon);
        params.salt = keccak256("nadFunRouterLvmonTest");
        (lvmonQuotedToken,) = bondingCurve.create(params);
        vm.warp(block.timestamp + 100 minutes);
    }

    function _tokenReserve(address pairAddr, address tokenAddr) internal view returns (uint256 reserve) {
        (uint112 r0, uint112 r1,) = INadFunPair(pairAddr).getReserves();
        reserve = INadFunPair(pairAddr).token0() == tokenAddr ? uint256(r0) : uint256(r1);
    }

    function _swapOut(address pairAddr, address tokenOut, uint256 amountOut, address to) internal {
        if (INadFunPair(pairAddr).token0() == tokenOut) {
            INadFunPair(pairAddr).swap(amountOut, 0, to, "");
        } else {
            INadFunPair(pairAddr).swap(0, amountOut, to, "");
        }
    }
}
