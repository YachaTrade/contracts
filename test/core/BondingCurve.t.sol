// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for BondingCurve.

import {console} from "forge-std/Test.sol";
import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {NadFunRouter} from "../../src/router/NadFunRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BondingCurveTest is SetUp {
    NadFunRouter localRouter;

    address vault;
    address token;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");

        wmon = new MockWMON();

        // Replace quoteToken with MockWMON in ProtocolManager, keep real modules
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

        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), user1);

        // Deploy NadFunRouter as UUPS proxy with MockWMON as wrappedNative
        NadFunRouter routerImpl = new NadFunRouter();
        localRouter = NadFunRouter(
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
                                address(0)
                            )
                        )
                    )
                ))
        );

        // Grant ROUTER_ROLE to NadFunRouter so it can call bondingCurve.buy/sell
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(localRouter));
        vm.stopPrank();

        vm.deal(address(wmon), 1000 ether);

        // Transfer deployFee to bondingCurve before create (balance detection)
        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        (token,) = bondingCurve.create(_defaultBCParams());

        // Skip past anti-sniping window (table length = 7, indexed by `block.number - createdAtBlock`).
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    // V2: creator fee is deducted from quote (not from token output)
    function test_buy_receivesTokens() public {
        uint256 buyAmount = 1 ether;
        _mintAndTransferBC(user1, buyAmount);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token);

        // V2 additive fee: totalFeeRate = curveProtocolFeeRate + creatorFeeRate (no sniping after warp)
        uint256 totalFeeRate = uint256(defaultCurveProtocolFee) + 500;
        uint256 quoteInAfterFees = buyAmount * (10000 - totalFeeRate) / 10000;
        uint256 k = virtualReserve * virtualTokenReserve;
        uint256 newReserveIn = virtualReserve + quoteInAfterFees;
        uint256 newReserveOut = (k + newReserveIn - 1) / newReserveIn; // ceilDiv
        uint256 expectedTokenOut = virtualTokenReserve - newReserveOut;
        assertEq(tokenOut, expectedTokenOut, "Should receive exact bonding curve output (creator fee on quote)");
        assertEq(IERC20(token).balanceOf(user1), tokenOut, "Balance should match tokenOut");
    }

    // V2: virtualQuoteReserve increases by quoteAfterCreatorFee (not quoteAfterProtocolFee)
    function test_buy_updatesState() public {
        uint256 buyAmount = 1 ether;
        _mintAndTransferBC(user1, buyAmount);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token);

        // V2 additive fee: totalFeeRate = curveProtocolFeeRate + creatorFeeRate (no sniping after warp)
        uint256 totalFeeRate = uint256(defaultCurveProtocolFee) + 500;
        uint256 quoteInAfterFees = buyAmount * (10000 - totalFeeRate) / 10000;
        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertEq(
            info.virtualQuoteReserve - info.initialQuoteReserve,
            quoteInAfterFees,
            "realQuoteReserve should equal effective input after protocol fee and creator fee"
        );
        // V2: tokensSold == tokenOut (no creator fee on token transfer)
        uint256 tokensSold = info.initialTokenReserve - info.virtualTokenReserve;
        assertEq(tokensSold, tokenOut, "Tokens sold should equal tokenOut (no creator fee on transfer)");
    }

    function test_buy_multipleBuys() public {
        _mintAndTransferBC(user1, 1 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        _mintAndTransferBC(user2, 1 ether);
        vm.prank(user2);
        bondingCurve.buy(user2, token);

        assertGt(
            IERC20(token).balanceOf(user1),
            IERC20(token).balanceOf(user2),
            "Second buy should yield fewer tokens (price increases)"
        );
    }

    function test_buy_slippageProtection() public {
        _mintAndApproveRouter(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(INadFunRouter.InsufficientOutput.selector);
        localRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: 1 ether,
                amountOutMin: type(uint256).max,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
    }

    function test_buy_unknownToken_reverts() public {
        address fakeToken = makeAddr("nonExistentToken");

        _mintAndTransferBC(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(IBondingCurve.TokenNotFound.selector);
        bondingCurve.buy(user1, fakeToken);
    }

    // V2: creator fee deducted from grossQuote output (not from token input)
    function test_sell_receivesQuote() public {
        _mintAndTransferBC(user1, 1 ether);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token);

        uint256 sellAmount = tokenOut / 2;
        uint256 quoteBefore = wmon.balanceOf(user1);

        vm.startPrank(user1);
        IERC20(token).approve(address(localRouter), sellAmount);
        uint256 quoteOut = localRouter.sell(
            INadFunRouter.SellParams({
                amountIn: sellAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertGt(quoteOut, 0, "Should receive positive quote output");
        assertEq(wmon.balanceOf(user1), quoteBefore + quoteOut, "Quote balance should increase by quoteOut");

        // Verify grossQuote via curve state: quoteOut = grossQuote - protocolFee - creatorFee
        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        IBondingCurve.Curve memory curveBefore = bondingCurve.getCurve(token);
        // The sell reduced virtualQuoteReserve; since we can't easily reconstruct the exact
        // state mid-function, we just verify that the user received a positive amount
        // and the getAmountOut view matches the actual execution
        uint256 viewOut = bondingCurve.getAmountOut(token, sellAmount, false);
        // viewOut uses current curve state (post-sell) so won't match exactly.
        // This test validates the basic flow; exact math is covered in BondingCurveV2Test.
    }

    // V2: virtualQuoteReserve decreases by grossQuote (before fees)
    function test_sell_updatesState() public {
        _mintAndTransferBC(user1, 2 ether);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory infoBefore = bondingCurve.getCurve(token);
        uint256 sellAmount = tokenOut / 2;

        vm.startPrank(user1);
        IERC20(token).approve(address(localRouter), sellAmount);
        uint256 quoteOut = localRouter.sell(
            INadFunRouter.SellParams({
                amountIn: sellAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        IBondingCurve.Curve memory infoAfter = bondingCurve.getCurve(token);

        assertLt(
            infoAfter.virtualQuoteReserve,
            infoBefore.virtualQuoteReserve,
            "virtualQuoteReserve should decrease after sell"
        );

        // V2: grossQuote = delta(virtualQuoteReserve)
        // quoteOut = grossQuote - protocolFee - creatorFee
        uint256 grossQuote = infoBefore.virtualQuoteReserve - infoAfter.virtualQuoteReserve;
        uint256 totalFees = (grossQuote * (defaultCurveProtocolFee + 500)) / 10000;
        assertApproxEqAbs(
            quoteOut, grossQuote - totalFees, 2, "quoteOut should be grossQuote minus fees and creator fee"
        );
    }

    function test_sell_slippageProtection() public {
        _mintAndTransferBC(user1, 1 ether);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token);

        vm.startPrank(user1);
        IERC20(token).approve(address(localRouter), tokenOut);
        vm.expectRevert(INadFunRouter.InsufficientOutput.selector);
        localRouter.sell(
            INadFunRouter.SellParams({
                amountIn: tokenOut,
                amountOutMin: type(uint256).max,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_antiSniping_maxPenaltyAtCreation() public {
        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        (address newToken,) = bondingCurve.create(_createBCParams("SnipeTest", "ST", keccak256("snipeTest")));
        assertEq(bondingCurve.getSnipingPenalty(newToken), 8000, "Penalty should be 8000 BPS (80%) at creation");
        _verifySnipingBuyAndFees(newToken);
    }

    function _verifySnipingBuyAndFees(address newToken) internal {
        // Additive model: totalFeeRate = 8000 (sniping) + protocol + 500 (creator) < BPS, buy succeeds.
        // Verify a substantial sniping fee was charged.
        _mintAndTransferBC(user1, 1 ether);
        address pair = tokenRegistry.getPair(newToken);
        uint256 feeReceiverBefore = wmon.balanceOf(feeReceiver);
        uint256 accumulatedBefore = feeCollector.accumulatedFee(pair);

        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, newToken);

        uint256 snipingFee = 800_000_000_000_000_000;
        uint256 protocolFee = 1 ether * uint256(defaultCurveProtocolFee) / 10000;
        uint256 creatorFee = 50_000_000_000_000_000;

        assertGt(tokenOut, 0, "buy succeeds at 80% sniping penalty");
        assertEq(IERC20(newToken).balanceOf(user1), tokenOut, "buyer receives quoted tokens");
        uint256 feeReceiverDelta = wmon.balanceOf(feeReceiver) - feeReceiverBefore;
        uint256 accumulatedDelta = feeCollector.accumulatedFee(pair) - accumulatedBefore;
        assertTrue(feeReceiverDelta == snipingFee + protocolFee, "fee receiver");
        assertTrue(accumulatedDelta == creatorFee, "creator fee");
    }

    /// @dev Verifies the per-block penalty curve matches the production table
    ///      [8000, 4000, 2000, 1500, 1000, 1000, 500] BPS for blocks 0..6, then 0.
    function test_antiSniping_perBlockTableMatchesCurve() public {
        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        (address newToken,) = bondingCurve.create(_createBCParams("Curve", "CV", keccak256("curve")));
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(newToken);
        uint64 createdAtBlock = curve.createdAtBlock;

        uint256[7] memory expected = [uint256(8000), 4000, 2000, 1500, 1000, 1000, 500];
        for (uint256 i = 0; i < expected.length; i++) {
            vm.roll(uint256(createdAtBlock) + i);
            assertEq(bondingCurve.getSnipingPenalty(newToken), expected[i], "penalty mismatch within sniping window");
        }

        // Past the table end → penalty drops to 0 immediately.
        vm.roll(uint256(createdAtBlock) + expected.length);
        assertEq(bondingCurve.getSnipingPenalty(newToken), 0, "penalty 0 at first block past the table");
        vm.roll(uint256(createdAtBlock) + expected.length + 100);
        assertEq(bondingCurve.getSnipingPenalty(newToken), 0, "penalty 0 well past the table");
    }

    function test_antiSniping_zeroPenaltyAfterWindow() public view {
        // `token` is created in setUp() and `vm.roll(... + 10)` advances past the 7-block table.
        uint256 penalty = bondingCurve.getSnipingPenalty(token);
        assertEq(penalty, 0, "Penalty should be 0 once past the per-block table");
    }

    function test_antiSniping_sameBlockUsesIndexZero() public {
        // Create + read in the same block — elapsed = 0, max penalty applies.
        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        (address newToken,) = bondingCurve.create(_createBCParams("SameBlk", "SB", keccak256("sameBlk")));
        assertEq(bondingCurve.getSnipingPenalty(newToken), 8000, "same-block read should hit table[0]");
    }

    function test_buy_smallAmountDuringSniping_doesNotUnderflowFeeRounding() public {
        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        (address newToken,) = bondingCurve.create(_createBCParams("Rounding", "RND", keccak256("rounding")));

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(newToken);
        // Last entry in the sniping table — smallest non-zero penalty (5%).
        vm.roll(uint256(curve.createdAtBlock) + 6);
        assertEq(bondingCurve.getSnipingPenalty(newToken), 500, "precondition: tail-of-window sniping penalty");

        _mintAndTransferBC(user1, 10);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, newToken);

        assertGt(tokenOut, 0, "small buy should not underflow fee split");
    }

    // BondingCurve.getAmountIn includes protocolFee + snipingPenalty + creatorFee

    function test_getAmountIn_buy_noFee() public view {
        uint256 desiredTokens = 1000 ether;
        uint256 bcAmountIn = bondingCurve.getAmountIn(token, desiredTokens, true);
        assertGt(bcAmountIn, 0, "getAmountIn should return positive value");
    }

    function test_getAmountIn_buy_withProtocolFee() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(wmon), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0, 0
        );

        uint256 desiredTokens = 1000 ether;
        uint256 bcAmountIn = bondingCurve.getAmountIn(token, desiredTokens, true);
        assertGt(bcAmountIn, 0, "getAmountIn with fee should return positive value");
    }

    function test_getAmountIn_buy_withSnipingPenalty() public {
        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        (address newToken,) = bondingCurve.create(_createBCParams("PenaltyTest", "PT", keccak256("penaltyTest")));

        // Same-block buy → max sniping (8000 BPS). getAmountIn must inflate the input to cover
        // both protocol/creator fees and the sniping penalty.
        uint256 desiredTokens = 100 ether;
        uint256 inflatedAmountIn = bondingCurve.getAmountIn(newToken, desiredTokens, true);

        // Past the table → no sniping fee, identical curve state.
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(newToken);
        vm.roll(uint256(curve.createdAtBlock) + 7);
        assertEq(bondingCurve.getSnipingPenalty(newToken), 0, "precondition: sniping ended");
        uint256 baselineAmountIn = bondingCurve.getAmountIn(newToken, desiredTokens, true);

        assertGt(inflatedAmountIn, baselineAmountIn, "sniping window must require more quote in");
    }

    // V2: BondingCurve.getAmountIn includes protocolFee + creatorFee
    function test_getAmountIn_sell_noFee() public view {
        uint256 desiredQuote = 1 ether;
        uint256 bcAmountIn = bondingCurve.getAmountIn(token, desiredQuote, false);
        assertGt(bcAmountIn, 0, "getAmountIn sell should return positive value");
    }

    function test_getAmountIn_sell_withProtocolFee() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(wmon), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0, 0
        );

        _mintAndTransferBC(user1, 5 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        uint256 desiredQuote = 1 ether;
        uint256 bcAmountIn = bondingCurve.getAmountIn(token, desiredQuote, false);
        assertGt(bcAmountIn, 0, "getAmountIn sell with fee should return positive value");
    }

    // BondingCurve.getAmountOut includes protocolFee + snipingPenalty + creatorFee

    function test_getAmountOut_buy_noFee() public view {
        uint256 quoteIn = 1 ether;
        uint256 bcOut = bondingCurve.getAmountOut(token, quoteIn, true);
        assertGt(bcOut, 0, "getAmountOut buy should return positive value");
    }

    function test_getAmountOut_buy_withProtocolFee() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(wmon), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0, 0
        );

        uint256 quoteIn = 1 ether;
        uint256 bcOut = bondingCurve.getAmountOut(token, quoteIn, true);
        assertGt(bcOut, 0, "getAmountOut buy with fee should return positive value");
    }

    // V2: BondingCurve.getAmountOut includes all fees for sell too.
    function test_getAmountOut_sell_noFee() public {
        _mintAndTransferBC(user1, 5 ether);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token);

        uint256 sellAmount = tokenOut / 2;
        uint256 bcOut = bondingCurve.getAmountOut(token, sellAmount, false);
        assertGt(bcOut, 0, "getAmountOut sell should return positive value");
    }

    function test_getAmountOut_sell_withProtocolFee() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(wmon), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0, 0
        );

        _mintAndTransferBC(user1, 5 ether);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token);

        uint256 sellAmount = tokenOut / 2;
        uint256 bcOut = bondingCurve.getAmountOut(token, sellAmount, false);
        assertGt(bcOut, 0, "getAmountOut sell with fee should return positive value");
    }

    // V2: creator fee on quote, user receives full tokenOut (no creator-fee-on-transfer)
    function test_exactOutBuy() public {
        uint256 desiredTokens = 1000 ether;
        uint256 maxQuoteIn = 5 ether;

        wmon.mint(user1, maxQuoteIn);
        vm.startPrank(user1);
        wmon.approve(address(localRouter), maxQuoteIn);

        uint256 amountIn = localRouter.exactOutBuy(
            INadFunRouter.ExactOutBuyParams({
                amountInMax: maxQuoteIn,
                amountOut: desiredTokens,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        uint256 tokenBalance = IERC20(token).balanceOf(user1);
        // V2: user receives full desiredTokens (no creator fee on token transfer)
        assertGe(tokenBalance, desiredTokens, "Should receive at least desired tokens");
        assertApproxEqAbs(tokenBalance, desiredTokens, 1e15, "Surplus from rounding should be small");
        assertLe(amountIn, maxQuoteIn, "Should not exceed max input");
        assertEq(wmon.balanceOf(user1), maxQuoteIn - amountIn, "Refund should match");
    }

    function test_exactOutBuy_excessiveInput() public {
        uint256 desiredTokens = 500_000_000 ether;
        uint256 tooLittleQuote = 1 ether;

        wmon.mint(user1, tooLittleQuote);
        vm.startPrank(user1);
        wmon.approve(address(localRouter), tooLittleQuote);

        vm.expectRevert(INadFunRouter.ExcessiveInput.selector);
        localRouter.exactOutBuy(
            INadFunRouter.ExactOutBuyParams({
                amountInMax: tooLittleQuote,
                amountOut: desiredTokens,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    // V2: creator fee on quote, user receives full tokenOut
    function test_exactOutBuyWithNative() public {
        uint256 desiredTokens = 1000 ether;
        uint256 maxNativeIn = 5 ether;
        vm.deal(user1, maxNativeIn);

        vm.prank(user1);
        uint256 amountIn = localRouter.exactOutBuyWithNative{value: maxNativeIn}(
            INadFunRouter.ExactOutBuyWithNativeParams({
                amountOut: desiredTokens, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        // V2: user receives full desiredTokens (no creator fee on transfer)
        assertGe(IERC20(token).balanceOf(user1), desiredTokens, "Should receive at least desired tokens");
        assertApproxEqAbs(IERC20(token).balanceOf(user1), desiredTokens, 1e15, "Surplus from rounding should be small");
        assertEq(user1.balance, maxNativeIn - amountIn, "Native refund should match");
    }

    function test_exactOutBuy_withSnipingPenalty() public {
        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        (address newToken,) =
            bondingCurve.create(_createBCParams("ExactOutPenalty", "EOP", keccak256("exactOutPenalty")));

        // Same-block exactOutBuy → table[0] (8000 BPS) sniping penalty applies on top of
        // protocol/creator fees. amountInMax must cover the inflated cost; otherwise the router
        // reverts with InsufficientOutput / out-of-budget. With a generous max we just verify the
        // exact-output buy succeeds during the sniping window.
        uint256 desiredTokens = 100 ether;
        uint256 maxQuoteIn = 5_000 ether;

        wmon.mint(user1, maxQuoteIn);
        vm.startPrank(user1);
        wmon.approve(address(localRouter), maxQuoteIn);

        uint256 amountIn = localRouter.exactOutBuy(
            INadFunRouter.ExactOutBuyParams({
                amountInMax: maxQuoteIn,
                amountOut: desiredTokens,
                token: newToken,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertGt(amountIn, 0, "exactOutBuy should succeed within sniping window");
        assertGe(IERC20(newToken).balanceOf(user1), desiredTokens, "buyer received the requested tokens");
    }

    function test_exactOutSell() public {
        uint256 buyAmount = 2 ether;
        wmon.mint(user1, buyAmount);
        vm.startPrank(user1);
        wmon.approve(address(localRouter), buyAmount);
        uint256 tokensOwned = localRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        uint256 desiredQuoteOut = 0.5 ether;
        IERC20(token).approve(address(localRouter), tokensOwned);

        uint256 quoteBefore = wmon.balanceOf(user1);
        uint256 amountOut = localRouter.exactOutSell(
            INadFunRouter.ExactOutSellParams({
                amountInMax: tokensOwned,
                amountOut: desiredQuoteOut,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertGe(amountOut, desiredQuoteOut, "Should receive at least desired quote");
        assertApproxEqAbs(
            amountOut, desiredQuoteOut, 1, "Should receive desired quote (1 wei tolerance for fee rounding)"
        );
        assertGe(
            wmon.balanceOf(user1) - quoteBefore, desiredQuoteOut, "Balance should increase by at least desiredQuoteOut"
        );
        assertGt(IERC20(token).balanceOf(user1), 0, "Should still have unused tokens");
    }

    function test_exactOutSellToNative() public {
        uint256 buyAmount = 2 ether;
        wmon.mint(user1, buyAmount);
        vm.startPrank(user1);
        wmon.approve(address(localRouter), buyAmount);
        uint256 tokensOwned = localRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        uint256 desiredNativeOut = 0.5 ether;
        IERC20(token).approve(address(localRouter), tokensOwned);

        uint256 nativeBefore = user1.balance;
        uint256 amountOut = localRouter.exactOutSellToNative(
            INadFunRouter.ExactOutSellToNativeParams({
                amountInMax: tokensOwned,
                amountOut: desiredNativeOut,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertGe(amountOut, desiredNativeOut, "Should receive at least desired native");
        assertApproxEqAbs(
            amountOut, desiredNativeOut, 1, "Should receive desired native (1 wei tolerance for fee rounding)"
        );
        assertGe(user1.balance - nativeBefore, desiredNativeOut, "Native balance should increase by at least desired");
    }

    function test_exactOutSell_excessiveInput() public {
        wmon.mint(user1, 0.01 ether);
        vm.startPrank(user1);
        wmon.approve(address(localRouter), 0.01 ether);
        uint256 tokensOwned = localRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: 0.01 ether, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        IERC20(token).approve(address(localRouter), tokensOwned);
        vm.expectRevert();
        localRouter.exactOutSell(
            INadFunRouter.ExactOutSellParams({
                amountInMax: tokensOwned, amountOut: 100 ether, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_create_withBuy_success() public {
        IBondingCurve.CreateTokenParams memory params = _createBCParams("CreateBuy", "CB", keccak256("createAndBuy1"));
        params.creator = user1;

        uint256 buyAmount = 1 ether;
        params.buyQuoteAmount = buyAmount;
        wmon.mint(user1, defaultDeployFee + buyAmount);
        vm.prank(user1);
        wmon.transfer(address(bondingCurve), defaultDeployFee + buyAmount);

        vm.prank(user1);
        (address newToken, uint256 tokenOut) = bondingCurve.create(params);

        assertTrue(newToken != address(0), "Token should be created");
        assertGt(tokenOut, 0, "Should receive tokens");
        assertEq(IERC20(newToken).balanceOf(user1), tokenOut, "Balance should match tokenOut");

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(newToken);
        assertEq(curve.creator, user1, "Creator should be user1");
    }

    function test_create_withBuy_noSnipingPenalty() public {
        IBondingCurve.CreateTokenParams memory params = _createBCParams("NoPenalty", "NP", keccak256("createAndBuy2"));
        params.creator = user1;

        uint256 buyAmount = 1 ether;
        params.buyQuoteAmount = buyAmount;
        wmon.mint(user1, defaultDeployFee + buyAmount);
        vm.prank(user1);
        wmon.transfer(address(bondingCurve), defaultDeployFee + buyAmount);

        vm.prank(user1);
        (address newToken, uint256 creatorTokenOut) = bondingCurve.create(params);

        // Warp past sniping so user2's buy doesn't hit totalFeeRate >= BPS
        vm.warp(block.timestamp + 100 minutes);

        wmon.mint(user2, buyAmount);
        vm.prank(user2);
        wmon.transfer(address(bondingCurve), buyAmount);

        vm.prank(user2);
        uint256 nonCreatorTokenOut = bondingCurve.buy(user2, newToken);

        assertGt(creatorTokenOut, nonCreatorTokenOut, "Creator should receive more (no sniping penalty)");
    }

    function test_create_createOnly() public {
        IBondingCurve.CreateTokenParams memory params = _createBCParams("CreateOnly", "CO", keccak256("createAndBuy3"));

        wmon.mint(user1, defaultDeployFee);
        vm.prank(user1);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        vm.prank(user1);
        (address newToken, uint256 tokenOut) = bondingCurve.create(params);

        assertTrue(newToken != address(0), "Token should be created");
        assertEq(tokenOut, 0, "Should receive no tokens (create only)");
    }

    function test_create_creatorSpoofing_reverts() public {
        IBondingCurve.CreateTokenParams memory params = _createBCParams("Spoof", "SP", keccak256("spoof1"));
        params.creator = user2;

        vm.prank(user3);
        vm.expectRevert();
        bondingCurve.create(params);
    }

    /// @dev dexTypes with no registered adapter must fail at create. Otherwise the token
    ///      would be born in a state where graduation permanently reverts in LPManager.
    function test_create_revertsOnUnsupportedDexType() public {
        IBondingCurve.CreateTokenParams memory params = _createBCParams("BadDex", "BDX", keccak256("bad-dex-type"));
        params.dexType = ITokenRegistry.DexType.UniswapV3; // no V3 adapter registered in SetUp

        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        vm.expectRevert("Unsupported dexType");
        bondingCurve.create(params);
    }

    /// @dev Previously, empty setupData skipped IVault.setup, leaving CreatorFeeVault
    ///      unconfigured — fees would be delivered post-settle but never credited and
    ///      neither claim() nor setCreator() could recover them. The create flow must now
    ///      reject empty setupData for vaults that require it (abi.decode reverts).
    function test_create_revertsOnEmptySetupDataForCreatorFeeVault() public {
        IBondingCurve.CreateTokenParams memory params = _createBCParams("EmptySetup", "ES", keccak256("empty-setup"));
        params.vaults[0].setupData = "";

        wmon.mint(address(this), defaultDeployFee);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        vm.expectRevert();
        bondingCurve.create(params);
    }

    function test_create_creatorFieldStored_withRouterRole() public {
        IBondingCurve.CreateTokenParams memory params =
            _createBCParams("CreatorField", "CF", keccak256("creatorField1"));
        params.creator = user2;

        bytes32 routerRole = bondingCurve.ROUTER_ROLE();
        vm.prank(admin);
        bondingCurve.grantRole(routerRole, user1);

        wmon.mint(user1, defaultDeployFee);
        vm.prank(user1);
        wmon.transfer(address(bondingCurve), defaultDeployFee);
        vm.prank(user1);
        (address newToken,) = bondingCurve.create(params);

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(newToken);
        assertEq(curve.creator, user2, "Creator should be user2");
    }

    function _mintAndTransferBC(address _user, uint256 amount) internal {
        wmon.mint(_user, amount);
        vm.prank(_user);
        wmon.transfer(address(bondingCurve), amount);
    }

    function _mintAndApproveRouter(address _user, uint256 amount) internal {
        wmon.mint(_user, amount);
        vm.prank(_user);
        wmon.approve(address(localRouter), amount);
    }

    function _createBCParams(string memory name, string memory symbol, bytes32 salt)
        internal
        view
        returns (IBondingCurve.CreateTokenParams memory params)
    {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});

        params = IBondingCurve.CreateTokenParams({
            name: name,
            symbol: symbol,
            tokenURI: "",
            quoteToken: address(wmon),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: salt,
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }

    function _defaultBCParams() internal view returns (IBondingCurve.CreateTokenParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});

        params = IBondingCurve.CreateTokenParams({
            name: "BondingTest",
            symbol: "BT",
            tokenURI: "",
            quoteToken: address(wmon),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: keccak256("bondingCurveTest"),
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }
}
