// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for YachaRouter.

import {Vm} from "forge-std/Vm.sol";
import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {YachaRouter} from "../../src/router/YachaRouter.sol";
import {IYachaRouter} from "../../src/interfaces/IYachaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWrappedNative} from "../mocks/MockWrappedNative.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {QuoterV2} from "@uniswap/v3-periphery/contracts/lens/QuoterV2.sol";
import {V3SwapAdapter} from "../../src/adapters/V3SwapAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ToggleFeeOnTransferQuote is ERC20 {
    bool public feeEnabled;

    constructor() ERC20("Toggle Tax Quote", "TTQ") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeEnabled(bool enabled) external {
        feeEnabled = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeEnabled && from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, to, value - fee);
            super._update(from, address(0xdead), fee);
            return;
        }
        super._update(from, to, value);
    }
}

contract YachaRouterTest is SetUp {
    event RouterBuy(address indexed buyer, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated);
    event RouterSell(
        address indexed seller, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated
    );

    MockERC20 lvmon;

    address vault;
    address token;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");

        wnative = new MockWrappedNative();
        lvmon = new MockERC20("Liquid Staked MON", "LVMON", 18);

        // Replace quoteToken with MockWrappedNative, keep real modules
        vm.startPrank(admin);

        protocolManager.removeQuoteToken(address(quoteToken));
        protocolManager.addQuoteToken(
            address(wnative),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee
        );
        protocolManager.setV3QuoteConfig(address(wnative), DEFAULT_V3_FEE_TIER, DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS);
        protocolManager.addQuoteToken(
            address(lvmon),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee
        );
        protocolManager.setV3QuoteConfig(address(lvmon), DEFAULT_V3_FEE_TIER, DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS);

        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));
        vm.stopPrank();

        // Deploy YachaRouter (UUPS proxy)
        YachaRouter routerImpl = new YachaRouter();
        yachaRouter = YachaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(routerImpl),
                        abi.encodeCall(
                            YachaRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wnative),
                                address(v3SwapAdapter),
                                address(quoterV2)
                            )
                        )
                    )
                ))
        );

        vm.startPrank(admin);
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(yachaRouter));
        vm.stopPrank();

        // Fund MockWrappedNative with ETH for native tests
        vm.deal(address(wnative), 1000 ether);

        wnative.mint(address(this), defaultDeployFee);
        wnative.approve(address(bondingCurve), defaultDeployFee);
        // Create token
        (token,) = bondingCurve.create(_nadFunDefaultParams());

        // Skip past anti-sniping
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    function test_exactOutBuy_bondingCurve() public {
        uint256 desiredTokens = 1000 ether;
        uint256 maxQuoteIn = 5 ether;

        wnative.mint(user1, maxQuoteIn);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), maxQuoteIn);

        uint256 amountIn = yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
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
        assertEq(wnative.balanceOf(user1), maxQuoteIn - amountIn, "Refund should match");
    }

    function test_exactOutBuyWithNative_bondingCurve() public {
        uint256 desiredTokens = 1000 ether;
        uint256 maxNativeIn = 5 ether;
        vm.deal(user1, maxNativeIn);

        vm.prank(user1);
        uint256 amountIn = yachaRouter.exactOutBuyWithNative{value: maxNativeIn}(
            IYachaRouter.ExactOutBuyWithNativeParams({
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
        vm.expectRevert(IYachaRouter.InvalidNativeQuoteToken.selector);
        yachaRouter.exactOutBuyWithNative{value: nativeInMax}(
            IYachaRouter.ExactOutBuyWithNativeParams({
                amountOut: tokenOut, token: lvmonQuotedToken, to: user1, deadline: block.timestamp + 1
            })
        );
    }

    function test_exactOutBuy_bondingCurve_doesNotSweepPreexistingQuoteBalance() public {
        uint256 donation = 7 ether;
        uint256 desiredTokens = 1000 ether;
        uint256 maxQuoteIn = 5 ether;

        wnative.mint(user2, donation);
        vm.prank(user2);
        wnative.transfer(address(yachaRouter), donation);

        wnative.mint(user1, maxQuoteIn);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), maxQuoteIn);

        uint256 amountIn = yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: maxQuoteIn,
                amountOut: desiredTokens,
                token: token,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(wnative.balanceOf(user1), maxQuoteIn - amountIn, "User should receive only this call's refund");
        assertEq(wnative.balanceOf(address(yachaRouter)), donation, "Router should retain pre-existing quote balance");
    }

    function test_exactOutBuyWithNative_bondingCurve_doesNotSweepPreexistingWnative() public {
        uint256 donation = 7 ether;
        uint256 desiredTokens = 1000 ether;
        uint256 maxNativeIn = 5 ether;

        wnative.mint(user2, donation);
        vm.prank(user2);
        wnative.transfer(address(yachaRouter), donation);

        vm.deal(user1, maxNativeIn);
        vm.prank(user1);
        uint256 amountIn = yachaRouter.exactOutBuyWithNative{value: maxNativeIn}(
            IYachaRouter.ExactOutBuyWithNativeParams({
                amountOut: desiredTokens, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        assertEq(user1.balance, maxNativeIn - amountIn, "User should receive only this call's native refund");
        assertEq(wnative.balanceOf(address(yachaRouter)), donation, "Router should retain pre-existing WNATIVE balance");
    }

    function test_exactOutBuy_excessiveInput_reverts() public {
        uint256 desiredTokens = 500_000_000 ether;
        uint256 tooLittle = 1 ether;

        wnative.mint(user1, tooLittle);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), tooLittle);

        vm.expectRevert(IYachaRouter.ExcessiveInput.selector);
        yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: tooLittle, amountOut: desiredTokens, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_exactOutBuy_expiredDeadline_reverts() public {
        wnative.mint(user1, 1 ether);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), 1 ether);

        vm.expectRevert(IYachaRouter.ExpiredDeadline.selector);
        yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: 1 ether, amountOut: 100 ether, token: token, to: user1, deadline: block.timestamp - 1
            })
        );
        vm.stopPrank();
    }

    function test_exactOutSell_bondingCurve() public {
        uint256 buyAmount = 2 ether;
        wnative.mint(user1, buyAmount);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), buyAmount);
        uint256 tokensOwned = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        uint256 desiredQuoteOut = 0.5 ether;
        IERC20(token).approve(address(yachaRouter), tokensOwned);

        uint256 quoteBefore = wnative.balanceOf(user1);
        uint256 tokenBefore = IERC20(token).balanceOf(user1);
        uint256 tokenIn = yachaRouter.exactOutSell(
            IYachaRouter.ExactOutSellParams({
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
            wnative.balanceOf(user1) - quoteBefore,
            desiredQuoteOut,
            "Balance should increase by at least desiredQuoteOut"
        );
    }

    function test_sell_emitsBondingCurveSellerAsRecipient() public {
        uint256 buyAmount = 2 ether;
        wnative.mint(user1, buyAmount);

        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), buyAmount);
        uint256 tokensOwned = yachaRouter.buy(
            IYachaRouter.BuyParams({
                token: token, amountIn: buyAmount, amountOutMin: 0, to: user1, deadline: block.timestamp + 1
            })
        );

        IERC20(token).approve(address(yachaRouter), tokensOwned);
        bytes32 sellTopic = keccak256("Sell(address,address,uint256,uint256)");

        vm.recordLogs();
        yachaRouter.sell(
            IYachaRouter.SellParams({
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
        wnative.mint(user1, buyAmount);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), buyAmount);
        uint256 tokensOwned = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        uint256 desiredNativeOut = 0.5 ether;
        IERC20(token).approve(address(yachaRouter), tokensOwned);

        uint256 nativeBefore = user1.balance;
        uint256 tokenBefore = IERC20(token).balanceOf(user1);
        uint256 tokenIn = yachaRouter.exactOutSellToNative(
            IYachaRouter.ExactOutSellToNativeParams({
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

    function test_exactOutSell_excessiveInput_reverts() public {
        wnative.mint(user1, 0.01 ether);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), 0.01 ether);
        uint256 tokensOwned = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: 0.01 ether, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        IERC20(token).approve(address(yachaRouter), tokensOwned);
        vm.expectRevert();
        yachaRouter.exactOutSell(
            IYachaRouter.ExactOutSellParams({
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
        wnative.mint(user1, amountIn);

        // Pre-calculate expected values
        uint256 expectedTokenOut = bondingCurve.getAmountOut(token, amountIn, true);
        uint256 expectedQuoteIn = bondingCurve.getAmountIn(token, expectedTokenOut, true);
        if (expectedQuoteIn > amountIn) expectedQuoteIn = amountIn;

        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), amountIn);

        vm.expectEmit(true, true, false, true, address(yachaRouter));
        emit RouterBuy(user1, token, expectedQuoteIn, expectedTokenOut, false);
        uint256 amountOut = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: amountIn, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(amountOut, expectedTokenOut, "Token out should match getAmountOut");
        assertEq(IERC20(token).balanceOf(user1), expectedTokenOut, "User token balance should match");
        assertEq(wnative.balanceOf(user1), amountIn - expectedQuoteIn, "User should keep unspent quote");
        assertEq(wnative.balanceOf(address(yachaRouter)), 0, "Router should hold no quote");
        assertEq(wnative.allowance(address(yachaRouter), address(bondingCurve)), 0, "Curve allowance reset");
    }

    function test_buy_bondingCurve_doesNotSweepCurveOrRouterDonations() public {
        uint256 curveDonation = 3 ether;
        uint256 routerDonation = 5 ether;
        uint256 amountIn = 2 ether;
        wnative.mint(user2, curveDonation + routerDonation);
        vm.startPrank(user2);
        wnative.transfer(address(bondingCurve), curveDonation);
        wnative.transfer(address(yachaRouter), routerDonation);
        vm.stopPrank();

        wnative.mint(user1, amountIn);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), amountIn);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: amountIn, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        uint256 trackedQuote = curve.virtualQuoteReserve - curve.initialQuoteReserve;
        assertEq(wnative.balanceOf(address(bondingCurve)), trackedQuote + curveDonation, "curve donation remains");
        assertEq(wnative.balanceOf(address(yachaRouter)), routerDonation, "router donation remains");
    }

    function test_sell_bondingCurve_doesNotSweepLaunchTokenDonations() public {
        uint256 buyAmount = 4 ether;
        wnative.mint(user1, buyAmount);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), buyAmount);
        uint256 tokenOut = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );

        uint256 curveDonation = tokenOut / 5;
        uint256 routerDonation = tokenOut / 5;
        uint256 tokenIn = tokenOut / 5;
        uint256 expectedQuoteOut = bondingCurve.getAmountOut(token, tokenIn, false);
        IERC20(token).transfer(address(bondingCurve), curveDonation);
        IERC20(token).transfer(address(yachaRouter), routerDonation);
        uint256 curveBalanceBefore = IERC20(token).balanceOf(address(bondingCurve));
        IERC20(token).approve(address(yachaRouter), tokenIn);

        vm.expectEmit(true, true, false, true, address(yachaRouter));
        emit RouterSell(user1, token, tokenIn, expectedQuoteOut, false);
        yachaRouter.sell(
            IYachaRouter.SellParams({
                amountIn: tokenIn, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(
            IERC20(token).balanceOf(address(bondingCurve)),
            curveBalanceBefore + tokenIn,
            "curve launch-token donation remains"
        );
        assertEq(IERC20(token).balanceOf(address(yachaRouter)), routerDonation, "router launch-token donation remains");
        assertEq(IERC20(token).allowance(address(yachaRouter), address(bondingCurve)), 0, "Curve allowance reset");
    }

    function test_buy_bondingCurve_taxedQuoteInputRevertsAndRollsBack() public {
        (ToggleFeeOnTransferQuote taxedQuote, address taxedToken) = _createToggleTaxQuotedToken();
        uint256 amountIn = 2 ether;
        taxedQuote.mint(user1, amountIn);
        taxedQuote.setFeeEnabled(true);
        IBondingCurve.Curve memory curveBefore = bondingCurve.getCurve(taxedToken);

        vm.startPrank(user1);
        taxedQuote.approve(address(yachaRouter), amountIn);
        vm.expectPartialRevert(IYachaRouter.InvalidBalanceDelta.selector);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: amountIn, amountOutMin: 0, token: taxedToken, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(taxedQuote.balanceOf(user1), amountIn, "taxed pull rolls back payer balance");
        assertEq(
            bondingCurve.getCurve(taxedToken).virtualQuoteReserve,
            curveBefore.virtualQuoteReserve,
            "taxed pull rolls back curve state"
        );
    }

    function test_sell_bondingCurve_shortCreditRevertsAndRollsBack() public {
        (ToggleFeeOnTransferQuote taxedQuote, address taxedToken) = _createToggleTaxQuotedToken();
        uint256 buyAmount = 4 ether;
        taxedQuote.mint(user1, buyAmount);
        vm.startPrank(user1);
        taxedQuote.approve(address(yachaRouter), buyAmount);
        uint256 tokenOut = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: taxedToken, to: user1, deadline: block.timestamp + 1
            })
        );
        uint256 tokenIn = tokenOut / 2;
        IERC20(taxedToken).approve(address(yachaRouter), tokenIn);
        uint256 tokenBalanceBefore = IERC20(taxedToken).balanceOf(user1);
        uint256 quoteBalanceBefore = taxedQuote.balanceOf(user1);
        IBondingCurve.Curve memory curveBefore = bondingCurve.getCurve(taxedToken);
        taxedQuote.setFeeEnabled(true);

        vm.expectPartialRevert(IBondingCurve.InvalidBalanceDelta.selector);
        yachaRouter.sell(
            IYachaRouter.SellParams({
                amountIn: tokenIn, amountOutMin: 0, token: taxedToken, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(IERC20(taxedToken).balanceOf(user1), tokenBalanceBefore, "failed sell rolls back token input");
        assertEq(taxedQuote.balanceOf(user1), quoteBalanceBefore, "failed sell rolls back quote output");
        assertEq(
            bondingCurve.getCurve(taxedToken).virtualQuoteReserve,
            curveBefore.virtualQuoteReserve,
            "short credit rolls back curve state"
        );
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
        uint256 amountOut = yachaRouter.buyWithNative{value: amountIn}(
            IYachaRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1})
        );

        assertEq(amountOut, expectedTokenOut, "Token out should match getAmountOut");
        assertEq(IERC20(token).balanceOf(user1), expectedTokenOut, "User token balance should match");
        assertEq(user1.balance, expectedRefund, "User should receive exact native refund");
        assertEq(wnative.balanceOf(address(yachaRouter)), 0, "Router should hold no WNATIVE");
        assertEq(address(yachaRouter).balance, 0, "Router should hold no native");
    }

    function test_buyWithNative_lvmonQuote_reverts() public {
        address lvmonQuotedToken = _createLvmonQuotedToken();
        uint256 nativeIn = 2 ether;

        vm.deal(user1, nativeIn);
        vm.prank(user1);
        vm.expectRevert(IYachaRouter.InvalidNativeQuoteToken.selector);
        yachaRouter.buyWithNative{value: nativeIn}(
            IYachaRouter.BuyWithNativeParams({
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

        wnative.mint(user1, quoteNeeded);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), quoteNeeded);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteNeeded, amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        // Send 10x what's needed for remaining tokens
        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        uint256 remainingTokens = curveAfter.virtualTokenReserve - curveAfter.minTokenReserve;
        uint256 exactNeeded = bondingCurve.getAmountIn(token, remainingTokens, true);
        uint256 excessAmount = exactNeeded * 10;

        // Pre-calculate: yachaRouter should only spend exactNeeded, not excessAmount
        uint256 expectedTokenOut = bondingCurve.getAmountOut(token, excessAmount, true);
        uint256 expectedQuoteIn = bondingCurve.getAmountIn(token, expectedTokenOut, true);
        if (expectedQuoteIn > excessAmount) expectedQuoteIn = excessAmount;

        wnative.mint(user2, excessAmount);
        vm.startPrank(user2);
        wnative.approve(address(yachaRouter), excessAmount);
        uint256 expectedRefund = excessAmount - expectedQuoteIn;

        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: excessAmount, amountOutMin: 0, token: token, to: user2, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(IERC20(token).balanceOf(user2), expectedTokenOut, "User should receive capped token amount");
        assertEq(wnative.balanceOf(user2), expectedRefund, "User should receive exact quote refund");
        assertEq(wnative.balanceOf(address(yachaRouter)), 0, "Router should hold no quote");
    }

    function test_buy_bondingCurve_checksSlippageBeforeRefund() public {
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        uint256 availableTokens = curve.virtualTokenReserve - curve.minTokenReserve;
        uint256 quoteNeeded = bondingCurve.getAmountIn(token, availableTokens * 90 / 100, true);

        wnative.mint(user1, quoteNeeded);
        vm.startPrank(user1);
        wnative.approve(address(yachaRouter), quoteNeeded);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
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

        wnative.mint(user2, quoteInMax);
        vm.prank(user2);
        wnative.approve(address(yachaRouter), quoteInMax);
        vm.mockCallRevert(
            address(wnative),
            abi.encodeCall(IERC20.transfer, (user2, refund)),
            abi.encodeWithSignature("RefundAttempted()")
        );

        vm.prank(user2);
        vm.expectRevert(IYachaRouter.InsufficientOutput.selector);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
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
        yachaRouter.buyWithNative{value: quoteNeeded}(
            IYachaRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user1, deadline: block.timestamp + 1})
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
        yachaRouter.buyWithNative{value: excessAmount}(
            IYachaRouter.BuyWithNativeParams({amountOutMin: 0, token: token, to: user2, deadline: block.timestamp + 1})
        );

        assertEq(IERC20(token).balanceOf(user2), expectedTokenOut, "User should receive capped token amount");
        assertEq(user2.balance, expectedRefund, "User should receive exact native refund");
        assertEq(address(yachaRouter).balance, 0, "Router should hold no native");
        assertEq(wnative.balanceOf(address(yachaRouter)), 0, "Router should hold no WNATIVE");
    }

    // ── Unified quote — phase-aware getAmountOut / getAmountIn ──────

    function test_getAmountOut_preGraduation_matchesBondingCurve() public {
        uint256 amountIn = 0.5 ether;
        uint256 unified = yachaRouter.getAmountOut(token, amountIn, true);
        uint256 direct = bondingCurve.getAmountOut(token, amountIn, true);
        assertEq(unified, direct, "Pre-graduation getAmountOut should delegate to BondingCurve");
    }

    function test_getAmountIn_preGraduation_matchesBondingCurve() public {
        uint256 amountOut = 1_000 ether;
        uint256 unified = yachaRouter.getAmountIn(token, amountOut, true);
        uint256 direct = bondingCurve.getAmountIn(token, amountOut, true);
        assertEq(unified, direct, "Pre-graduation getAmountIn should delegate to BondingCurve");
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
        QuoterV2 mismatchedQuoter = new QuoterV2(address(otherFactory), address(wnative));
        address[6] memory dependencies = _validDependencies();
        dependencies[5] = address(mismatchedQuoter);
        _expectInvalidDependency(dependencies);
    }

    function test_initialize_revertsOnImplementation() public {
        YachaRouter implementation = new YachaRouter();
        address[6] memory dependencies = _validDependencies();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            dependencies[0], dependencies[1], dependencies[2], dependencies[3], dependencies[4], dependencies[5]
        );
    }

    function test_dependencyGetters_returnConfiguredDependencies() public view {
        assertEq(yachaRouter.authority(), address(protocolManager));
        assertEq(yachaRouter.bondingCurve(), address(bondingCurve));
        assertEq(yachaRouter.tokenRegistry(), address(tokenRegistry));
        assertEq(yachaRouter.wrappedNative(), address(wnative));
        assertEq(yachaRouter.v3SwapAdapter(), address(v3SwapAdapter));
        assertEq(yachaRouter.quoterV2(), address(quoterV2));
    }

    function test_setAuthority_remainsUnavailable() public {
        vm.prank(address(protocolManager));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(protocolManager))
        );
        yachaRouter.setAuthority(makeAddr("replacementAuthority"));
    }

    function _validDependencies() internal view returns (address[6] memory dependencies) {
        dependencies = [
            address(protocolManager),
            address(bondingCurve),
            address(tokenRegistry),
            address(wnative),
            address(v3SwapAdapter),
            address(quoterV2)
        ];
    }

    function _expectInvalidDependency(address[6] memory dependencies) internal {
        YachaRouter implementation = new YachaRouter();
        vm.expectRevert(IYachaRouter.InvalidDependency.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                YachaRouter.initialize,
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
            quoteToken: address(wnative),
            vaults: vaults,
            salt: keccak256("yachaRouterTest"),
            dexType: ITokenRegistry.DexType.UniswapV3,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }

    function _createLvmonQuotedToken() internal returns (address lvmonQuotedToken) {
        lvmon.mint(address(this), defaultDeployFee);
        lvmon.approve(address(bondingCurve), defaultDeployFee);
        IBondingCurve.CreateTokenParams memory params = _nadFunDefaultParams();
        params.quoteToken = address(lvmon);
        params.salt = keccak256("yachaRouterLvmonTest");
        (lvmonQuotedToken,) = bondingCurve.create(params);
        vm.warp(block.timestamp + 100 minutes);
    }

    function _createToggleTaxQuotedToken() internal returns (ToggleFeeOnTransferQuote taxedQuote, address taxedToken) {
        taxedQuote = new ToggleFeeOnTransferQuote();
        vm.startPrank(admin);
        protocolManager.addQuoteToken(
            address(taxedQuote),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee
        );
        protocolManager.setV3QuoteConfig(address(taxedQuote), DEFAULT_V3_FEE_TIER, DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS);
        vm.stopPrank();

        taxedQuote.mint(address(this), defaultDeployFee);
        taxedQuote.approve(address(bondingCurve), defaultDeployFee);
        IBondingCurve.CreateTokenParams memory params = _nadFunDefaultParams();
        params.quoteToken = address(taxedQuote);
        params.salt = keccak256("yachaRouterTaxedQuoteTest");
        (taxedToken,) = bondingCurve.create(params);
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }
}
