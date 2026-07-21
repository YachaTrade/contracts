// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for GiwaRouter.

import {Vm} from "forge-std/Vm.sol";
import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {QuoterV2} from "@uniswap/v3-periphery/contracts/lens/QuoterV2.sol";
import {V3SwapAdapter} from "../../src/adapters/V3SwapAdapter.sol";

contract GiwaRouterTest is SetUp {
    MockERC20 lvmon;

    address vault;
    address token;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");

        wmon = new MockWMON();
        lvmon = new MockERC20("Liquid Staked MON", "LVMON", 18);

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

        // Deploy GiwaRouter (UUPS proxy)
        GiwaRouter routerImpl = new GiwaRouter();
        giwaRouter = GiwaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(routerImpl),
                        abi.encodeCall(
                            GiwaRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wmon),
                                address(v3SwapAdapter),
                                address(quoterV2)
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
        wmon.approve(address(giwaRouter), maxQuoteIn);

        uint256 amountIn = giwaRouter.exactOutBuy(
            IGiwaRouter.ExactOutBuyParams({
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
        uint256 amountIn = giwaRouter.exactOutBuyWithNative{value: maxNativeIn}(
            IGiwaRouter.ExactOutBuyWithNativeParams({
                amountOut: desiredTokens, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        // V2: user receives full desiredTokens (creator fee on quote, not token transfer)
        assertGe(IERC20(token).balanceOf(user1), desiredTokens, "Should receive at least desired tokens");
        assertApproxEqAbs(IERC20(token).balanceOf(user1), desiredTokens, 1e15, "Surplus from rounding should be small");
        assertEq(user1.balance, maxNativeIn - amountIn, "Native refund should match");
    }

    function test_exactOutBuyWithNative_lvmonQuote_reverts() public {
        address lvmonQuotedToken = _createLvmonQuotedToken();
        uint256 tokenOut = 1000 ether;
        uint256 nativeInMax = 5 ether;

        vm.deal(user1, nativeInMax);
        vm.prank(user1);
        vm.expectRevert(IGiwaRouter.InvalidNativeQuoteToken.selector);
        giwaRouter.exactOutBuyWithNative{value: nativeInMax}(
            IGiwaRouter.ExactOutBuyWithNativeParams({
                amountOut: tokenOut, token: lvmonQuotedToken, to: user1, deadline: block.timestamp + 1
            })
        );
    }

    function test_exactOutBuy_bondingCurve_doesNotSweepPreexistingQuoteBalance() public {
        uint256 donation = 7 ether;
        uint256 desiredTokens = 1000 ether;
        uint256 maxQuoteIn = 5 ether;

        wmon.mint(user2, donation);
        vm.prank(user2);
        wmon.transfer(address(giwaRouter), donation);

        wmon.mint(user1, maxQuoteIn);
        vm.startPrank(user1);
        wmon.approve(address(giwaRouter), maxQuoteIn);

        uint256 amountIn = giwaRouter.exactOutBuy(
            IGiwaRouter.ExactOutBuyParams({
                amountInMax: maxQuoteIn,
                amountOut: desiredTokens,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(wmon.balanceOf(user1), maxQuoteIn - amountIn, "User should receive only this call's refund");
        assertEq(wmon.balanceOf(address(giwaRouter)), donation, "Router should retain pre-existing quote balance");
    }

    function test_exactOutBuyWithNative_bondingCurve_doesNotSweepPreexistingWmon() public {
        uint256 donation = 7 ether;
        uint256 desiredTokens = 1000 ether;
        uint256 maxNativeIn = 5 ether;

        wmon.mint(user2, donation);
        vm.prank(user2);
        wmon.transfer(address(giwaRouter), donation);

        vm.deal(user1, maxNativeIn);
        vm.prank(user1);
        uint256 amountIn = giwaRouter.exactOutBuyWithNative{value: maxNativeIn}(
            IGiwaRouter.ExactOutBuyWithNativeParams({
                amountOut: desiredTokens, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        assertEq(user1.balance, maxNativeIn - amountIn, "User should receive only this call's native refund");
        assertEq(wmon.balanceOf(address(giwaRouter)), donation, "Router should retain pre-existing WMON balance");
    }

    function test_exactOutBuy_excessiveInput_reverts() public {
        uint256 desiredTokens = 500_000_000 ether;
        uint256 tooLittle = 1 ether;

        wmon.mint(user1, tooLittle);
        vm.startPrank(user1);
        wmon.approve(address(giwaRouter), tooLittle);

        vm.expectRevert(IGiwaRouter.ExcessiveInput.selector);
        giwaRouter.exactOutBuy(
            IGiwaRouter.ExactOutBuyParams({
                amountInMax: tooLittle, amountOut: desiredTokens, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_exactOutBuy_expiredDeadline_reverts() public {
        wmon.mint(user1, 1 ether);
        vm.startPrank(user1);
        wmon.approve(address(giwaRouter), 1 ether);

        vm.expectRevert(IGiwaRouter.ExpiredDeadline.selector);
        giwaRouter.exactOutBuy(
            IGiwaRouter.ExactOutBuyParams({
                amountInMax: 1 ether, amountOut: 100 ether, token: token, to: user1, deadline: block.timestamp - 1
            })
        );
        vm.stopPrank();
    }

    function test_exactOutSell_bondingCurve() public {
        uint256 buyAmount = 2 ether;
        wmon.mint(user1, buyAmount);
        vm.startPrank(user1);
        wmon.approve(address(giwaRouter), buyAmount);
        uint256 tokensOwned = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        uint256 desiredQuoteOut = 0.5 ether;
        IERC20(token).approve(address(giwaRouter), tokensOwned);

        uint256 quoteBefore = wmon.balanceOf(user1);
        uint256 tokenBefore = IERC20(token).balanceOf(user1);
        uint256 tokenIn = giwaRouter.exactOutSell(
            IGiwaRouter.ExactOutSellParams({
                amountInMax: tokensOwned,
                amountOut: desiredQuoteOut,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(tokenIn, tokenBefore - IERC20(token).balanceOf(user1), "Should return launch-token input used");
        assertGe(
            wmon.balanceOf(user1) - quoteBefore, desiredQuoteOut, "Balance should increase by at least desiredQuoteOut"
        );
    }

    function test_sell_emitsBondingCurveSellerAsRecipient() public {
        uint256 buyAmount = 2 ether;
        wmon.mint(user1, buyAmount);

        vm.startPrank(user1);
        wmon.approve(address(giwaRouter), buyAmount);
        uint256 tokensOwned = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                token: token, amountIn: buyAmount, amountOutMin: 0, to: user1, deadline: block.timestamp + 1
            })
        );

        IERC20(token).approve(address(giwaRouter), tokensOwned);
        bytes32 sellTopic = keccak256("Sell(address,address,uint256,uint256)");

        vm.recordLogs();
        giwaRouter.sell(
            IGiwaRouter.SellParams({
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
        wmon.approve(address(giwaRouter), buyAmount);
        uint256 tokensOwned = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        uint256 desiredNativeOut = 0.5 ether;
        IERC20(token).approve(address(giwaRouter), tokensOwned);

        uint256 nativeBefore = user1.balance;
        uint256 tokenBefore = IERC20(token).balanceOf(user1);
        uint256 tokenIn = giwaRouter.exactOutSellToNative(
            IGiwaRouter.ExactOutSellToNativeParams({
                amountInMax: tokensOwned,
                amountOut: desiredNativeOut,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(tokenIn, tokenBefore - IERC20(token).balanceOf(user1), "Should return launch-token input used");
        assertGe(user1.balance - nativeBefore, desiredNativeOut, "Native balance should increase by at least desired");
    }

    function test_exactOutSellToNative_graduatedV2Metadata_revertsInvalidV3Pool() public {
        uint256 graduationAmount = 800_000 ether;

        wmon.mint(user1, graduationAmount);
        vm.startPrank(user1);
        wmon.transfer(address(bondingCurve), graduationAmount);
        bondingCurve.buy(user1, token);
        vm.stopPrank();

        assertTrue(bondingCurve.getCurve(token).graduated, "Token should be graduated");

        vm.startPrank(user1);
        IERC20(token).approve(address(giwaRouter), 1 ether);
        vm.expectRevert(IGiwaRouter.InvalidV3Pool.selector);
        giwaRouter.exactOutSellToNative(
            IGiwaRouter.ExactOutSellToNativeParams({
                amountInMax: 1 ether, amountOut: 1, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_exactOutSell_excessiveInput_reverts() public {
        wmon.mint(user1, 0.01 ether);
        vm.startPrank(user1);
        wmon.approve(address(giwaRouter), 0.01 ether);
        uint256 tokensOwned = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: 0.01 ether, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        IERC20(token).approve(address(giwaRouter), tokensOwned);
        vm.expectRevert();
        giwaRouter.exactOutSell(
            IGiwaRouter.ExactOutSellParams({
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
        wmon.approve(address(giwaRouter), amountIn);

        uint256 amountOut = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: amountIn, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(amountOut, expectedTokenOut, "Token out should match getAmountOut");
        assertEq(IERC20(token).balanceOf(user1), expectedTokenOut, "User token balance should match");
        assertEq(wmon.balanceOf(user1), amountIn - expectedQuoteIn, "User should keep unspent quote");
        assertEq(wmon.balanceOf(address(giwaRouter)), 0, "Router should hold no quote");
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
        uint256 amountOut = giwaRouter.buyWithNative{value: amountIn}(
            IGiwaRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1})
        );

        assertEq(amountOut, expectedTokenOut, "Token out should match getAmountOut");
        assertEq(IERC20(token).balanceOf(user1), expectedTokenOut, "User token balance should match");
        assertEq(user1.balance, expectedRefund, "User should receive exact native refund");
        assertEq(wmon.balanceOf(address(giwaRouter)), 0, "Router should hold no WMON");
        assertEq(address(giwaRouter).balance, 0, "Router should hold no native");
    }

    function test_buyWithNative_lvmonQuote_reverts() public {
        address lvmonQuotedToken = _createLvmonQuotedToken();
        uint256 nativeIn = 2 ether;

        vm.deal(user1, nativeIn);
        vm.prank(user1);
        vm.expectRevert(IGiwaRouter.InvalidNativeQuoteToken.selector);
        giwaRouter.buyWithNative{value: nativeIn}(
            IGiwaRouter.BuyWithNativeParams({
                amountOutMin: 0, token: lvmonQuotedToken, to: user1, deadline: block.timestamp + 1
            })
        );
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
        wmon.approve(address(giwaRouter), quoteNeeded);
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: quoteNeeded, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        // Send 10x what's needed for remaining tokens
        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        uint256 remainingTokens = curveAfter.virtualTokenReserve - curveAfter.minTokenReserve;
        uint256 exactNeeded = bondingCurve.getAmountIn(token, remainingTokens, true);
        uint256 excessAmount = exactNeeded * 10;

        // Pre-calculate: giwaRouter should only spend exactNeeded, not excessAmount
        uint256 expectedTokenOut = bondingCurve.getAmountOut(token, excessAmount, true);
        uint256 expectedQuoteIn = bondingCurve.getAmountIn(token, expectedTokenOut, true);
        if (expectedQuoteIn > excessAmount) expectedQuoteIn = excessAmount;

        wmon.mint(user2, excessAmount);
        vm.startPrank(user2);
        wmon.approve(address(giwaRouter), excessAmount);
        uint256 expectedRefund = excessAmount - expectedQuoteIn;

        vm.expectEmit(true, true, false, true, address(wmon));
        emit IERC20.Transfer(user2, address(giwaRouter), excessAmount);
        vm.expectEmit(true, true, false, true, address(wmon));
        emit IERC20.Transfer(address(giwaRouter), address(bondingCurve), expectedQuoteIn);
        vm.expectEmit(true, true, false, true, address(wmon));
        emit IERC20.Transfer(address(giwaRouter), user2, expectedRefund);
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: excessAmount, amountOutMin: 0, token: token, to: user2, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(IERC20(token).balanceOf(user2), expectedTokenOut, "User should receive capped token amount");
        assertEq(wmon.balanceOf(user2), expectedRefund, "User should receive exact quote refund");
        assertEq(wmon.balanceOf(address(giwaRouter)), 0, "Router should hold no quote");
    }

    function test_buy_bondingCurve_checksSlippageBeforeRefund() public {
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        uint256 availableTokens = curve.virtualTokenReserve - curve.minTokenReserve;
        uint256 quoteNeeded = bondingCurve.getAmountIn(token, availableTokens * 90 / 100, true);

        wmon.mint(user1, quoteNeeded);
        vm.startPrank(user1);
        wmon.approve(address(giwaRouter), quoteNeeded);
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: quoteNeeded, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        uint256 remainingTokens = curveAfter.virtualTokenReserve - curveAfter.minTokenReserve;
        uint256 exactQuoteIn = bondingCurve.getAmountIn(token, remainingTokens, true);
        uint256 quoteInMax = exactQuoteIn * 10;
        uint256 tokenOut = bondingCurve.getAmountOut(token, quoteInMax, true);
        uint256 quoteIn = bondingCurve.getAmountIn(token, tokenOut, true);
        if (quoteIn > quoteInMax) quoteIn = quoteInMax;
        uint256 refund = quoteInMax - quoteIn;

        wmon.mint(user2, quoteInMax);
        vm.prank(user2);
        wmon.approve(address(giwaRouter), quoteInMax);
        vm.mockCallRevert(
            address(wmon),
            abi.encodeCall(IERC20.transfer, (user2, refund)),
            abi.encodeWithSignature("RefundAttempted()")
        );

        vm.prank(user2);
        vm.expectRevert(IGiwaRouter.InsufficientOutput.selector);
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: quoteInMax, amountOutMin: tokenOut + 1, token: token, to: user2, deadline: block.timestamp + 1
            })
        );
    }

    function test_buyWithNative_nearGraduation_refundsExcess() public {
        // Buy 90% of available tokens first
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        uint256 availableTokens = curve.virtualTokenReserve - curve.minTokenReserve;
        uint256 targetTokens = availableTokens * 90 / 100;
        uint256 quoteNeeded = bondingCurve.getAmountIn(token, targetTokens, true);

        vm.deal(user1, quoteNeeded);
        vm.prank(user1);
        giwaRouter.buyWithNative{value: quoteNeeded}(
            IGiwaRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1})
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
        giwaRouter.buyWithNative{value: excessAmount}(
            IGiwaRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user2, deadline: block.timestamp + 1})
        );

        assertEq(IERC20(token).balanceOf(user2), expectedTokenOut, "User should receive capped token amount");
        assertEq(user2.balance, expectedRefund, "User should receive exact native refund");
        assertEq(address(giwaRouter).balance, 0, "Router should hold no native");
        assertEq(wmon.balanceOf(address(giwaRouter)), 0, "Router should hold no WMON");
    }

    // ── Unified quote — phase-aware getAmountOut / getAmountIn ──────

    function test_getAmountOut_preGraduation_matchesBondingCurve() public {
        uint256 amountIn = 0.5 ether;
        uint256 unified = giwaRouter.getAmountOut(token, amountIn, true);
        uint256 direct = bondingCurve.getAmountOut(token, amountIn, true);
        assertEq(unified, direct, "Pre-graduation getAmountOut should delegate to BondingCurve");
    }

    function test_getAmountIn_preGraduation_matchesBondingCurve() public {
        uint256 amountOut = 1_000 ether;
        uint256 unified = giwaRouter.getAmountIn(token, amountOut, true);
        uint256 direct = bondingCurve.getAmountIn(token, amountOut, true);
        assertEq(unified, direct, "Pre-graduation getAmountIn should delegate to BondingCurve");
    }

    function test_getAmountOut_postGraduationV2Metadata_revertsInvalidV3Pool() public {
        // Graduate the token by pushing enough quote through BondingCurve.
        uint256 graduationAmount = 800_000 ether;
        wmon.mint(user1, graduationAmount);
        vm.startPrank(user1);
        wmon.transfer(address(bondingCurve), graduationAmount);
        bondingCurve.buy(user1, token);
        vm.stopPrank();
        assertTrue(bondingCurve.getCurve(token).graduated, "Setup: token must graduate");

        vm.expectRevert(IGiwaRouter.InvalidV3Pool.selector);
        giwaRouter.getAmountOut(token, 0.1 ether, true);
    }

    function test_graduatedV2Metadata_allTradeAndQuoteEntrypointsRevertInvalidV3Pool() public {
        uint256 graduationAmount = 800_000 ether;
        wmon.mint(user1, graduationAmount);
        vm.startPrank(user1);
        wmon.transfer(address(bondingCurve), graduationAmount);
        bondingCurve.buy(user1, token);
        vm.stopPrank();
        assertTrue(bondingCurve.getCurve(token).graduated, "Setup: token must graduate");

        uint256 deadline = block.timestamp + 1;
        wmon.approve(address(giwaRouter), type(uint256).max);
        IERC20(token).approve(address(giwaRouter), type(uint256).max);
        vm.deal(address(this), 2 ether);

        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.buy,
                (IGiwaRouter.BuyParams({amountIn: 1, amountOutMin: 0, token: token, to: user1, deadline: deadline}))
            ),
            0
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.buyWithNative,
                (IGiwaRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user1, deadline: deadline}))
            ),
            1
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.buyWithPermit,
                (IGiwaRouter.BuyWithPermitParams({
                        amountIn: 1,
                        amountOutMin: 0,
                        amountAllowance: 1,
                        token: token,
                        to: user1,
                        deadline: deadline,
                        v: 27,
                        r: bytes32(0),
                        s: bytes32(0)
                    }))
            ),
            0
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.sell,
                (IGiwaRouter.SellParams({amountIn: 1, amountOutMin: 0, token: token, to: user1, deadline: deadline}))
            ),
            0
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.sellToNative,
                (IGiwaRouter.SellToNativeParams({
                        amountIn: 1, amountOutMin: 0, token: token, to: user1, deadline: deadline
                    }))
            ),
            0
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.sellWithPermit,
                (IGiwaRouter.SellWithPermitParams({
                        amountIn: 1,
                        amountOutMin: 0,
                        amountAllowance: 1,
                        token: token,
                        to: user1,
                        deadline: deadline,
                        v: 27,
                        r: bytes32(0),
                        s: bytes32(0)
                    }))
            ),
            0
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.sellToNativeWithPermit,
                (IGiwaRouter.SellToNativeWithPermitParams({
                        amountIn: 1,
                        amountOutMin: 0,
                        amountAllowance: 1,
                        token: token,
                        to: user1,
                        deadline: deadline,
                        v: 27,
                        r: bytes32(0),
                        s: bytes32(0)
                    }))
            ),
            0
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.exactOutBuy,
                (IGiwaRouter.ExactOutBuyParams({
                        amountInMax: 1, amountOut: 1, token: token, to: user1, deadline: deadline
                    }))
            ),
            0
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.exactOutBuyWithNative,
                (IGiwaRouter.ExactOutBuyWithNativeParams({amountOut: 1, token: token, to: user1, deadline: deadline}))
            ),
            1
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.exactOutSell,
                (IGiwaRouter.ExactOutSellParams({
                        amountInMax: 1, amountOut: 1, token: token, to: user1, deadline: deadline
                    }))
            ),
            0
        );
        _expectInvalidV3Pool(
            abi.encodeCall(
                GiwaRouter.exactOutSellToNative,
                (IGiwaRouter.ExactOutSellToNativeParams({
                        amountInMax: 1, amountOut: 1, token: token, to: user1, deadline: deadline
                    }))
            ),
            0
        );
        _expectInvalidV3Pool(abi.encodeCall(GiwaRouter.getAmountOut, (token, 1, true)), 0);
        _expectInvalidV3Pool(abi.encodeCall(GiwaRouter.getAmountIn, (token, 1, true)), 0);
        _expectInvalidV3Pool(abi.encodeCall(GiwaRouter.getDexAmountOut, (token, 1, true)), 0);
        _expectInvalidV3Pool(abi.encodeCall(GiwaRouter.getDexAmountIn, (token, 1, true)), 0);
    }

    function _expectInvalidV3Pool(bytes memory callData, uint256 value) internal {
        (bool success, bytes memory revertData) = address(giwaRouter).call{value: value}(callData);
        assertFalse(success, "graduated V2 metadata path must revert");
        assertEq(revertData, abi.encodeWithSelector(IGiwaRouter.InvalidV3Pool.selector));
    }

    function test_initialize_revertsForEveryZeroDependency() public {
        address[6] memory dependencies = _validDependencies();
        for (uint256 i; i < dependencies.length; ++i) {
            address dependency = dependencies[i];
            dependencies[i] = address(0);
            _expectInvalidDependency(dependencies);
            dependencies[i] = dependency;
        }
    }

    function test_initialize_revertsForEveryNonContractDependency() public {
        address[6] memory dependencies = _validDependencies();
        for (uint256 i; i < dependencies.length; ++i) {
            address dependency = dependencies[i];
            dependencies[i] = makeAddr(string.concat("nonContractDependency", vm.toString(i)));
            assertEq(dependencies[i].code.length, 0, "test dependency must have no code");
            _expectInvalidDependency(dependencies);
            dependencies[i] = dependency;
        }
    }

    function test_initialize_revertsWhenAdapterRegistryDoesNotMatch() public {
        V3SwapAdapter mismatchedAdapter = new V3SwapAdapter(address(v3Factory), address(protocolManager));
        address[6] memory dependencies = _validDependencies();
        dependencies[4] = address(mismatchedAdapter);
        _expectInvalidDependency(dependencies);
    }

    function test_initialize_revertsWhenQuoterFactoryDoesNotMatchAdapter() public {
        UniswapV3Factory otherFactory = new UniswapV3Factory();
        QuoterV2 mismatchedQuoter = new QuoterV2(address(otherFactory), address(wmon));
        address[6] memory dependencies = _validDependencies();
        dependencies[5] = address(mismatchedQuoter);
        _expectInvalidDependency(dependencies);
    }

    function test_initialize_revertsOnImplementation() public {
        GiwaRouter implementation = new GiwaRouter();
        address[6] memory dependencies = _validDependencies();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            dependencies[0], dependencies[1], dependencies[2], dependencies[3], dependencies[4], dependencies[5]
        );
    }

    function test_dependencyGetters_returnConfiguredDependencies() public view {
        assertEq(giwaRouter.authority(), address(protocolManager));
        assertEq(giwaRouter.bondingCurve(), address(bondingCurve));
        assertEq(giwaRouter.tokenRegistry(), address(tokenRegistry));
        assertEq(giwaRouter.wrappedNative(), address(wmon));
        assertEq(giwaRouter.v3SwapAdapter(), address(v3SwapAdapter));
        assertEq(giwaRouter.quoterV2(), address(quoterV2));
    }

    function test_setAuthority_remainsUnavailable() public {
        vm.prank(address(protocolManager));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(protocolManager))
        );
        giwaRouter.setAuthority(makeAddr("replacementAuthority"));
    }

    function _validDependencies() internal view returns (address[6] memory dependencies) {
        dependencies = [
            address(protocolManager),
            address(bondingCurve),
            address(tokenRegistry),
            address(wmon),
            address(v3SwapAdapter),
            address(quoterV2)
        ];
    }

    function _expectInvalidDependency(address[6] memory dependencies) internal {
        GiwaRouter implementation = new GiwaRouter();
        vm.expectRevert(IGiwaRouter.InvalidDependency.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                GiwaRouter.initialize,
                (dependencies[0], dependencies[1], dependencies[2], dependencies[3], dependencies[4], dependencies[5])
            )
        );
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
            salt: keccak256("giwaRouterTest"),
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
        params.salt = keccak256("giwaRouterLvmonTest");
        (lvmonQuotedToken,) = bondingCurve.create(params);
        vm.warp(block.timestamp + 100 minutes);
    }
}
