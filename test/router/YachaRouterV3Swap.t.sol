// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

import {SetUp} from "../SetUp.t.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {YachaRouter} from "../../src/router/YachaRouter.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IYachaRouter} from "../../src/interfaces/IYachaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IV3SwapAdapter} from "../../src/interfaces/IV3SwapAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RejectingReceiverERC20 is MockERC20 {
    error RejectedRecipient();

    address private _rejectedRecipient;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    function setRejectedRecipient(address recipient) external {
        _rejectedRecipient = recipient;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == _rejectedRecipient) revert RejectedRecipient();
        super._update(from, to, value);
    }
}

contract ConditionalTransferERC20 is MockERC20 {
    enum Behavior {
        None,
        Tax,
        Surcharge
    }

    address private _conditionFrom;
    address private _conditionTo;
    Behavior private _behavior;
    uint16 private _rate;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    function configure(address from, address to, Behavior behavior, uint16 rate) external {
        _conditionFrom = from;
        _conditionTo = to;
        _behavior = behavior;
        _rate = rate;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != _conditionFrom || to != _conditionTo || _behavior == Behavior.None) {
            super._update(from, to, value);
            return;
        }

        uint256 adjustment = FullMath.mulDiv(value, _rate, 10_000);
        if (_behavior == Behavior.Tax) {
            super._update(from, to, value - adjustment);
            super._update(from, address(0), adjustment);
        } else {
            super._update(from, address(0), adjustment);
            super._update(from, to, value);
        }
    }
}

contract StateChangingQuoter {
    address public immutable factory;
    uint256 public calls;

    constructor(address factory_) {
        factory = factory_;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams calldata)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        calls++;
        amountOut = 123;
        sqrtPriceX96After = 1;
        initializedTicksCrossed = 0;
        gasEstimate = 1;
    }
}

contract YachaRouterV3SwapTest is SetUp {
    using SafeERC20 for IERC20;

    struct Fixture {
        MockERC20 launchToken;
        MockERC20 quoteToken;
        address pool;
        uint24 feeTier;
        uint16 protocolFeeRate;
    }

    uint256 private constant BPS = 10_000;
    uint24 private constant LOW_FEE_TIER = 500;
    uint24 private constant HIGH_FEE_TIER = 3_000;
    uint16 private constant LOW_PROTOCOL_FEE_RATE = 35;
    uint16 private constant HIGH_PROTOCOL_FEE_RATE = 125;
    uint128 private constant REGULAR_LIQUIDITY = 1_000_000 ether;
    uint128 private constant PARTIAL_LIQUIDITY = 1e30;
    uint256 private constant REGULAR_BALANCE = 1_000_000_000 ether;
    uint256 private constant PARTIAL_BALANCE = 1e52;
    uint256 private constant PARTIAL_INPUT = 1e50;
    uint256 private constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 private constant MIN_RUNTIME_HEADROOM = 512;
    bytes32 private constant BUY_EVENT = keccak256("RouterBuy(address,address,uint256,uint256,bool)");
    bytes32 private constant SELL_EVENT = keccak256("RouterSell(address,address,uint256,uint256,bool)");

    Fixture private launchBelowQuote;
    Fixture private launchAboveQuote;
    address private _mintPool;

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        protocolManager.setOperatorPermission(
            address(this), address(tokenRegistry), TokenRegistry.registerV3.selector, true
        );

        launchBelowQuote = _createFixture("Below", true, LOW_FEE_TIER, LOW_PROTOCOL_FEE_RATE, false);
        launchAboveQuote = _createFixture("Above", false, HIGH_FEE_TIER, HIGH_PROTOCOL_FEE_RATE, false);
    }

    function test_buyGraduated_chargesProtocolFeeOnInputAndRoutesQuoteToToken() public {
        Fixture memory fixture = launchBelowQuote;
        uint256 quoteInMaxWithProtocolFee = 10 ether;
        uint256 userQuoteBefore = _fundAndApproveQuote(fixture, user1, quoteInMaxWithProtocolFee);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        uint256 recipientTokenBefore = fixture.launchToken.balanceOf(user2);
        uint256 poolQuoteBefore = fixture.quoteToken.balanceOf(fixture.pool);
        vm.recordLogs();

        vm.prank(user1);
        uint256 tokenOut = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        uint256 quoteIn = fixture.quoteToken.balanceOf(fixture.pool) - poolQuoteBefore;
        uint256 protocolFee = _buyProtocolFee(quoteInMaxWithProtocolFee, fixture.protocolFeeRate, quoteIn);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore, protocolFee);
        assertEq(userQuoteBefore - fixture.quoteToken.balanceOf(user1), quoteIn + protocolFee);
        assertEq(fixture.launchToken.balanceOf(user2) - recipientTokenBefore, tokenOut);
        assertEq(fixture.quoteToken.allowance(address(yachaRouter), address(v3SwapAdapter)), 0);
        _assertTradeEvent(
            vm.getRecordedLogs(), BUY_EVENT, user1, address(fixture.launchToken), quoteIn + protocolFee, tokenOut
        );
    }

    function test_buyGraduated_partialInputProratesProtocolFeeAndRefundsQuote() public {
        Fixture memory fixture = _createFixture("PartialBuy", true, LOW_FEE_TIER, LOW_PROTOCOL_FEE_RATE, true);
        uint256 quoteInMaxWithProtocolFee = PARTIAL_INPUT;
        uint256 userQuoteBefore = _fundAndApproveQuote(fixture, user1, quoteInMaxWithProtocolFee);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        uint256 poolQuoteBefore = fixture.quoteToken.balanceOf(fixture.pool);

        vm.prank(user1);
        uint256 tokenOut = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        uint256 protocolFeeMax = FullMath.mulDivRoundingUp(quoteInMaxWithProtocolFee, fixture.protocolFeeRate, BPS);
        uint256 poolQuoteInMax = quoteInMaxWithProtocolFee - protocolFeeMax;
        uint256 quoteIn = fixture.quoteToken.balanceOf(fixture.pool) - poolQuoteBefore;
        uint256 protocolFee = FullMath.mulDivRoundingUp(protocolFeeMax, quoteIn, poolQuoteInMax);
        assertGt(tokenOut, 0);
        assertGt(quoteIn, 0);
        assertLt(quoteIn, poolQuoteInMax);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore, protocolFee);
        assertEq(userQuoteBefore - fixture.quoteToken.balanceOf(user1), quoteIn + protocolFee);
        assertEq(fixture.quoteToken.balanceOf(address(yachaRouter)), 0);
    }

    function test_sellGraduated_chargesProtocolFeeOnOutputAndRoutesTokenToQuote() public {
        Fixture memory fixture = launchAboveQuote;
        uint256 tokenInMax = 10 ether;
        uint256 userTokenBefore = _fundAndApproveLaunch(fixture, user1, tokenInMax);
        uint256 recipientQuoteBefore = fixture.quoteToken.balanceOf(user2);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        uint256 poolLaunchBefore = fixture.launchToken.balanceOf(fixture.pool);
        uint256 poolQuoteBefore = fixture.quoteToken.balanceOf(fixture.pool);
        vm.recordLogs();

        vm.prank(user1);
        uint256 quoteOut = yachaRouter.sell(
            IYachaRouter.SellParams({
                amountIn: tokenInMax,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        uint256 tokenInUsed = fixture.launchToken.balanceOf(fixture.pool) - poolLaunchBefore;
        uint256 quoteOutBeforeProtocolFee = poolQuoteBefore - fixture.quoteToken.balanceOf(fixture.pool);
        uint256 protocolFee = FullMath.mulDivRoundingUp(quoteOutBeforeProtocolFee, fixture.protocolFeeRate, BPS);
        assertEq(userTokenBefore - fixture.launchToken.balanceOf(user1), tokenInUsed);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore, protocolFee);
        assertEq(fixture.quoteToken.balanceOf(user2) - recipientQuoteBefore, quoteOutBeforeProtocolFee - protocolFee);
        assertEq(quoteOut, quoteOutBeforeProtocolFee - protocolFee);
        assertEq(fixture.launchToken.allowance(address(yachaRouter), address(v3SwapAdapter)), 0);
        _assertTradeEvent(vm.getRecordedLogs(), SELL_EVENT, user1, address(fixture.launchToken), tokenInUsed, quoteOut);
    }

    function test_sellGraduated_partialInputRefundsLaunchToken() public {
        Fixture memory fixture = _createFixture("PartialSell", false, HIGH_FEE_TIER, HIGH_PROTOCOL_FEE_RATE, true);
        uint256 tokenInMax = PARTIAL_INPUT;
        uint256 userTokenBefore = _fundAndApproveLaunch(fixture, user1, tokenInMax);
        uint256 poolLaunchBefore = fixture.launchToken.balanceOf(fixture.pool);
        uint256 recipientQuoteBefore = fixture.quoteToken.balanceOf(user2);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        uint256 poolQuoteBefore = fixture.quoteToken.balanceOf(fixture.pool);

        vm.prank(user1);
        uint256 quoteOut = yachaRouter.sell(
            IYachaRouter.SellParams({
                amountIn: tokenInMax,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        uint256 tokenInUsed = fixture.launchToken.balanceOf(fixture.pool) - poolLaunchBefore;
        uint256 quoteOutBeforeProtocolFee = poolQuoteBefore - fixture.quoteToken.balanceOf(fixture.pool);
        uint256 protocolFee = FullMath.mulDivRoundingUp(quoteOutBeforeProtocolFee, fixture.protocolFeeRate, BPS);
        assertGt(tokenInUsed, 0);
        assertLt(tokenInUsed, tokenInMax);
        assertEq(userTokenBefore - fixture.launchToken.balanceOf(user1), tokenInUsed);
        assertEq(fixture.quoteToken.balanceOf(user2) - recipientQuoteBefore, quoteOutBeforeProtocolFee - protocolFee);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore, protocolFee);
        assertEq(quoteOut, quoteOutBeforeProtocolFee - protocolFee);
        assertEq(fixture.launchToken.balanceOf(address(yachaRouter)), 0);
    }

    function test_exactOutBuyGraduated_returnsGrossQuoteUsedAndRefundsMaximum() public {
        Fixture memory fixture = launchBelowQuote;
        uint256 amountInMax = 10 ether;
        uint256 tokenOut = 1 ether;
        uint256 userQuoteBefore = _fundAndApproveQuote(fixture, user1, amountInMax);
        uint256 recipientTokenBefore = fixture.launchToken.balanceOf(user2);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        uint256 poolQuoteBefore = fixture.quoteToken.balanceOf(fixture.pool);
        vm.recordLogs();

        vm.prank(user1);
        uint256 quoteInWithProtocolFee = yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: amountInMax,
                amountOut: tokenOut,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        uint256 poolQuoteIn = fixture.quoteToken.balanceOf(fixture.pool) - poolQuoteBefore;
        uint256 requiredQuoteInWithProtocolFee =
            FullMath.mulDivRoundingUp(poolQuoteIn, BPS, BPS - fixture.protocolFeeRate);
        uint256 protocolFee = requiredQuoteInWithProtocolFee - poolQuoteIn;
        assertEq(quoteInWithProtocolFee, requiredQuoteInWithProtocolFee);
        assertEq(userQuoteBefore - fixture.quoteToken.balanceOf(user1), requiredQuoteInWithProtocolFee);
        assertEq(fixture.launchToken.balanceOf(user2) - recipientTokenBefore, tokenOut);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore, protocolFee);
        assertEq(fixture.quoteToken.balanceOf(address(yachaRouter)), 0);
        assertEq(fixture.quoteToken.allowance(address(yachaRouter), address(v3SwapAdapter)), 0);
        _assertTradeEvent(
            vm.getRecordedLogs(),
            BUY_EVENT,
            user1,
            address(fixture.launchToken),
            requiredQuoteInWithProtocolFee,
            tokenOut
        );
    }

    function test_exactOutBuyGraduated_revertsAboveMaximumGrossQuote() public {
        Fixture memory fixture = launchBelowQuote;
        uint256 tokenOut = 1 ether;
        uint256 snapshot = vm.snapshotState();
        _fundAndApproveQuote(fixture, user1, 10 ether);
        vm.prank(user1);
        uint256 quoteInWithProtocolFee = yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: 10 ether,
                amountOut: tokenOut,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );
        vm.revertToState(snapshot);

        uint256 amountInMax = quoteInWithProtocolFee - 1;
        uint256 userQuoteBefore = _fundAndApproveQuote(fixture, user1, amountInMax);
        uint256 recipientTokenBefore = fixture.launchToken.balanceOf(user2);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);

        vm.expectRevert(IYachaRouter.ExcessiveInput.selector);
        vm.prank(user1);
        yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: amountInMax,
                amountOut: tokenOut,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.quoteToken.balanceOf(user1), userQuoteBefore);
        assertEq(fixture.launchToken.balanceOf(user2), recipientTokenBefore);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver), feeReceiverQuoteBefore);
    }

    function test_exactOutSellGraduated_revertsAboveMaximumLaunchTokenInput() public {
        Fixture memory fixture = launchAboveQuote;
        uint256 quoteOut = 1 ether;
        uint256 snapshot = vm.snapshotState();
        _fundAndApproveLaunch(fixture, user1, 10 ether);
        vm.prank(user1);
        uint256 tokenIn = yachaRouter.exactOutSell(
            IYachaRouter.ExactOutSellParams({
                amountInMax: 10 ether,
                amountOut: quoteOut,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );
        vm.revertToState(snapshot);

        uint256 amountInMax = tokenIn - 1;
        uint256 userTokenBefore = _fundAndApproveLaunch(fixture, user1, amountInMax);
        uint256 recipientQuoteBefore = fixture.quoteToken.balanceOf(user2);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);

        vm.expectRevert(IYachaRouter.ExcessiveInput.selector);
        vm.prank(user1);
        yachaRouter.exactOutSell(
            IYachaRouter.ExactOutSellParams({
                amountInMax: amountInMax,
                amountOut: quoteOut,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.launchToken.balanceOf(user1), userTokenBefore);
        assertEq(fixture.quoteToken.balanceOf(user2), recipientQuoteBefore);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver), feeReceiverQuoteBefore);
    }

    function test_exactOutBuyGraduated_acceptsExactGrossMaximum() public {
        Fixture memory fixture = launchBelowQuote;
        uint256 tokenOut = 1 ether;
        uint256 snapshot = vm.snapshotState();
        _fundAndApproveQuote(fixture, user1, 10 ether);
        vm.prank(user1);
        uint256 requiredQuoteInWithProtocolFee = yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: 10 ether,
                amountOut: tokenOut,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );
        vm.revertToState(snapshot);

        uint256 userQuoteBefore = _fundAndApproveQuote(fixture, user1, requiredQuoteInWithProtocolFee);
        vm.prank(user1);
        uint256 quoteInWithProtocolFee = yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: requiredQuoteInWithProtocolFee,
                amountOut: tokenOut,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(quoteInWithProtocolFee, requiredQuoteInWithProtocolFee);
        assertEq(userQuoteBefore - fixture.quoteToken.balanceOf(user1), requiredQuoteInWithProtocolFee);
    }

    function test_exactOutSellGraduated_returnsTokenUsedAndPaysExactNetQuote() public {
        Fixture memory fixture = launchAboveQuote;
        uint256 amountInMax = 10 ether;
        uint256 quoteOut = 1 ether;
        uint256 userTokenBefore = _fundAndApproveLaunch(fixture, user1, amountInMax);
        uint256 recipientQuoteBefore = fixture.quoteToken.balanceOf(user2);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        uint256 poolLaunchBefore = fixture.launchToken.balanceOf(fixture.pool);
        uint256 poolQuoteBefore = fixture.quoteToken.balanceOf(fixture.pool);
        vm.recordLogs();

        vm.prank(user1);
        uint256 tokenIn = yachaRouter.exactOutSell(
            IYachaRouter.ExactOutSellParams({
                amountInMax: amountInMax,
                amountOut: quoteOut,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        uint256 requiredQuoteOutBeforeProtocolFee =
            FullMath.mulDivRoundingUp(quoteOut, BPS, BPS - fixture.protocolFeeRate);
        uint256 protocolFee = requiredQuoteOutBeforeProtocolFee - quoteOut;
        assertEq(tokenIn, fixture.launchToken.balanceOf(fixture.pool) - poolLaunchBefore);
        assertEq(userTokenBefore - fixture.launchToken.balanceOf(user1), tokenIn);
        assertEq(poolQuoteBefore - fixture.quoteToken.balanceOf(fixture.pool), requiredQuoteOutBeforeProtocolFee);
        assertEq(fixture.quoteToken.balanceOf(user2) - recipientQuoteBefore, quoteOut);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore, protocolFee);
        assertEq(fixture.launchToken.allowance(address(yachaRouter), address(v3SwapAdapter)), 0);
        _assertTradeEvent(vm.getRecordedLogs(), SELL_EVENT, user1, address(fixture.launchToken), tokenIn, quoteOut);
    }

    function test_exactOutSellGraduated_refundsUnusedLaunchToken() public {
        Fixture memory fixture = launchBelowQuote;
        uint256 amountInMax = 10 ether;
        uint256 userTokenBefore = _fundAndApproveLaunch(fixture, user1, amountInMax);

        vm.prank(user1);
        uint256 tokenIn = yachaRouter.exactOutSell(
            IYachaRouter.ExactOutSellParams({
                amountInMax: amountInMax,
                amountOut: 1 ether,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertGt(tokenIn, 0);
        assertLt(tokenIn, amountInMax);
        assertEq(userTokenBefore - fixture.launchToken.balanceOf(user1), tokenIn);
        assertEq(fixture.launchToken.balanceOf(address(yachaRouter)), 0);
    }

    function test_exactOutput_roundsProtocolFeeUpAtOneWei() public {
        Fixture memory fixture = launchAboveQuote;
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        uint256 recipientQuoteBefore = fixture.quoteToken.balanceOf(user2);
        _fundAndApproveLaunch(fixture, user1, 1 ether);

        vm.prank(user1);
        yachaRouter.exactOutSell(
            IYachaRouter.ExactOutSellParams({
                amountInMax: 1 ether,
                amountOut: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.quoteToken.balanceOf(user2) - recipientQuoteBefore, 1);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore, 1);
    }

    function test_exactOutput_revertsOnPartialFill() public {
        Fixture memory fixture = _createFixture("PartialExactOut", true, LOW_FEE_TIER, LOW_PROTOCOL_FEE_RATE, true);
        _fundAndApproveQuote(fixture, user1, PARTIAL_INPUT);

        vm.expectRevert(IV3SwapAdapter.InvalidAmountOut.selector);
        vm.prank(user1);
        yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: PARTIAL_INPUT,
                amountOut: PARTIAL_BALANCE,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );
    }

    function test_exactOutput_usesCurrentFeeReceiverAndDoesNotSweepDonations() public {
        Fixture memory fixture = launchAboveQuote;
        address currentFeeReceiver = makeAddr("exactOutputFeeReceiver");
        vm.prank(admin);
        protocolManager.setFeeReceiver(currentFeeReceiver);
        uint256 quoteDonation = 7 ether;
        uint256 tokenDonation = 11 ether;
        fixture.quoteToken.mint(address(yachaRouter), quoteDonation);
        fixture.launchToken.mint(address(yachaRouter), tokenDonation);
        uint256 oldFeeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        _fundAndApproveLaunch(fixture, user1, 10 ether);

        vm.prank(user1);
        yachaRouter.exactOutSell(
            IYachaRouter.ExactOutSellParams({
                amountInMax: 10 ether,
                amountOut: 1 ether,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertGt(fixture.quoteToken.balanceOf(currentFeeReceiver), 0);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver), oldFeeReceiverQuoteBefore);
        assertEq(fixture.quoteToken.balanceOf(address(yachaRouter)), quoteDonation);
        assertEq(fixture.launchToken.balanceOf(address(yachaRouter)), tokenDonation);
    }

    function test_exactOutBuy_revertsForTaxedUserPullWithoutConsumingDonation() public {
        Fixture memory fixture = _createConditionalFixture("ExactOutTaxedPull");
        ConditionalTransferERC20 conditionalQuote = ConditionalTransferERC20(address(fixture.quoteToken));
        uint256 amountInMax = 10 ether;
        uint256 donation = 2 ether;
        fixture.quoteToken.mint(address(yachaRouter), donation);
        uint256 userQuoteBefore = _fundAndApproveQuote(fixture, user1, amountInMax);
        conditionalQuote.configure(user1, address(yachaRouter), ConditionalTransferERC20.Behavior.Tax, 1_000);

        vm.expectPartialRevert(IYachaRouter.InvalidBalanceDelta.selector);
        vm.prank(user1);
        yachaRouter.exactOutBuy(
            IYachaRouter.ExactOutBuyParams({
                amountInMax: amountInMax,
                amountOut: 1 ether,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.quoteToken.balanceOf(user1), userQuoteBefore);
        assertEq(fixture.quoteToken.balanceOf(address(yachaRouter)), donation);
        assertEq(fixture.launchToken.balanceOf(user2), 0);
    }

    function test_exactInput_zeroProtocolFeeDoesNotTransferToFeeReceiver() public {
        Fixture memory fixture = launchBelowQuote;
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(fixture.quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            0
        );
        uint256 quoteInMaxWithProtocolFee = 10 ether;
        uint256 userQuoteBefore = _fundAndApproveQuote(fixture, user1, quoteInMaxWithProtocolFee);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        uint256 poolQuoteBefore = fixture.quoteToken.balanceOf(fixture.pool);

        vm.prank(user1);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        uint256 quoteIn = fixture.quoteToken.balanceOf(fixture.pool) - poolQuoteBefore;
        assertEq(fixture.quoteToken.balanceOf(feeReceiver), feeReceiverQuoteBefore);
        assertEq(userQuoteBefore - fixture.quoteToken.balanceOf(user1), quoteIn);
    }

    function test_exactInput_usesEachQuoteTokensConfiguredProtocolFeeRate() public {
        uint256 lowProtocolFee = _executeBuyAndReadProtocolFee(launchBelowQuote, user1, 10 ether);
        uint256 highProtocolFee = _executeBuyAndReadProtocolFee(launchAboveQuote, user2, 10 ether);

        assertEq(lowProtocolFee, FullMath.mulDivRoundingUp(10 ether, LOW_PROTOCOL_FEE_RATE, BPS));
        assertEq(highProtocolFee, FullMath.mulDivRoundingUp(10 ether, HIGH_PROTOCOL_FEE_RATE, BPS));
        assertGt(highProtocolFee, lowProtocolFee);
    }

    function test_exactInput_supportsQuoteBelowAndAboveLaunchToken() public {
        assertLt(uint160(address(launchBelowQuote.launchToken)), uint160(address(launchBelowQuote.quoteToken)));
        assertGt(uint160(address(launchAboveQuote.launchToken)), uint160(address(launchAboveQuote.quoteToken)));

        uint256 tokenOutBelowQuote = _executeBuy(launchBelowQuote, user1, 10 ether);
        uint256 tokenOutAboveQuote = _executeBuy(launchAboveQuote, user2, 10 ether);

        assertGt(tokenOutBelowQuote, 0);
        assertGt(tokenOutAboveQuote, 0);
    }

    function test_exactInput_revertsWhenQuoteOutAfterProtocolFeeMissesSlippage() public {
        Fixture memory fixture = launchAboveQuote;
        uint256 tokenInMax = 10 ether;
        uint256 userTokenBefore = _fundAndApproveLaunch(fixture, user1, tokenInMax);
        uint256 userQuoteBefore = fixture.quoteToken.balanceOf(user1);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);

        vm.expectRevert(IYachaRouter.InsufficientOutput.selector);
        vm.prank(user1);
        yachaRouter.sell(
            IYachaRouter.SellParams({
                amountIn: tokenInMax,
                amountOutMin: type(uint256).max,
                token: address(fixture.launchToken),
                to: user1,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.launchToken.balanceOf(user1), userTokenBefore);
        assertEq(fixture.quoteToken.balanceOf(user1), userQuoteBefore);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver), feeReceiverQuoteBefore);
    }

    function test_exactInput_doesNotSweepRouterDonations() public {
        Fixture memory fixture = launchBelowQuote;
        uint256 quoteDonation = 7 ether;
        uint256 tokenDonation = 11 ether;
        fixture.quoteToken.mint(address(yachaRouter), quoteDonation);
        fixture.launchToken.mint(address(yachaRouter), tokenDonation);

        _executeBuy(fixture, user1, 10 ether);
        _fundAndApproveLaunch(fixture, user2, 10 ether);
        vm.prank(user2);
        yachaRouter.sell(
            IYachaRouter.SellParams({
                amountIn: 10 ether,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.quoteToken.balanceOf(address(yachaRouter)), quoteDonation);
        assertEq(fixture.launchToken.balanceOf(address(yachaRouter)), tokenDonation);
    }

    function test_directAdapterSwapDoesNotChargeRouterProtocolFee() public {
        Fixture memory fixture = launchBelowQuote;
        uint256 amountIn = 10 ether;
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        fixture.quoteToken.approve(address(v3SwapAdapter), amountIn);

        (uint256 amountInUsed, uint256 amountOut) = v3SwapAdapter.exactInput(
            IV3SwapAdapter.ExactInputParams({
                token: address(fixture.launchToken),
                tokenIn: address(fixture.quoteToken),
                amountIn: amountIn,
                amountOutMin: 1,
                recipient: user1,
                sqrtPriceLimitX96: _priceLimit(address(fixture.quoteToken), address(fixture.launchToken)),
                deadline: block.timestamp
            })
        );

        assertGt(amountInUsed, 0);
        assertGt(amountOut, 0);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver), feeReceiverQuoteBefore);
    }

    function test_exactInput_usesCurrentFeeReceiver() public {
        Fixture memory fixture = launchBelowQuote;
        address currentFeeReceiver = makeAddr("currentFeeReceiver");
        vm.prank(admin);
        protocolManager.setFeeReceiver(currentFeeReceiver);
        uint256 oldFeeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);

        uint256 currentReceiverProtocolFee = _executeBuyAndReadProtocolFee(fixture, user1, 10 ether);

        assertGt(currentReceiverProtocolFee, 0);
        assertEq(fixture.quoteToken.balanceOf(feeReceiver), oldFeeReceiverQuoteBefore);
        assertEq(fixture.quoteToken.balanceOf(currentFeeReceiver), currentReceiverProtocolFee);
    }

    function test_exactInput_revertsForDisabledQuoteToken() public {
        Fixture memory fixture = launchBelowQuote;
        vm.prank(admin);
        protocolManager.removeQuoteToken(address(fixture.quoteToken));
        _fundAndApproveQuote(fixture, user1, 10 ether);

        vm.expectRevert(IYachaRouter.InvalidV3Quote.selector);
        vm.prank(user1);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: 10 ether,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user1,
                deadline: block.timestamp
            })
        );
    }

    function test_exactInput_revertsForInvalidDexFeeRate() public {
        Fixture memory fixture = launchBelowQuote;
        uint16 invalidRate = 10_000;
        vm.mockCall(
            address(protocolManager),
            abi.encodeCall(protocolManager.dexProtocolFeeRate, (address(fixture.quoteToken))),
            abi.encode(invalidRate)
        );
        _fundAndApproveQuote(fixture, user1, 10 ether);

        vm.expectRevert(IYachaRouter.InvalidDexFeeRate.selector);
        vm.prank(user1);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: 10 ether,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user1,
                deadline: block.timestamp
            })
        );
    }

    function test_exactInput_revertsAndRollsBackWhenProtocolFeePaymentFails() public {
        RejectingReceiverERC20 first = new RejectingReceiverERC20("Reject A", "RJA");
        RejectingReceiverERC20 second = new RejectingReceiverERC20("Reject B", "RJB");
        Fixture memory fixture = _createFixtureFromTokens(
            "Reject",
            MockERC20(address(first)),
            MockERC20(address(second)),
            true,
            LOW_FEE_TIER,
            LOW_PROTOCOL_FEE_RATE,
            false
        );
        RejectingReceiverERC20(address(fixture.quoteToken)).setRejectedRecipient(feeReceiver);
        uint256 quoteInMaxWithProtocolFee = 10 ether;
        uint256 userQuoteBefore = _fundAndApproveQuote(fixture, user1, quoteInMaxWithProtocolFee);
        uint256 poolQuoteBefore = fixture.quoteToken.balanceOf(fixture.pool);

        vm.expectRevert(RejectingReceiverERC20.RejectedRecipient.selector);
        vm.prank(user1);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.quoteToken.balanceOf(user1), userQuoteBefore);
        assertEq(fixture.quoteToken.balanceOf(fixture.pool), poolQuoteBefore);
        assertEq(fixture.launchToken.balanceOf(user2), 0);
    }

    function test_exactInput_revertsForTaxedUserPullWithoutConsumingDonation() public {
        Fixture memory fixture = _createConditionalFixture("TaxedPull");
        ConditionalTransferERC20 conditionalQuote = ConditionalTransferERC20(address(fixture.quoteToken));
        uint256 quoteInMaxWithProtocolFee = 10 ether;
        uint256 donation = 2 ether;
        fixture.quoteToken.mint(address(yachaRouter), donation);
        uint256 userQuoteBefore = _fundAndApproveQuote(fixture, user1, quoteInMaxWithProtocolFee);
        conditionalQuote.configure(user1, address(yachaRouter), ConditionalTransferERC20.Behavior.Tax, 1_000);

        vm.expectPartialRevert(IYachaRouter.InvalidBalanceDelta.selector);
        vm.prank(user1);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.quoteToken.balanceOf(user1), userQuoteBefore);
        assertEq(fixture.quoteToken.balanceOf(address(yachaRouter)), donation);
        assertEq(fixture.launchToken.balanceOf(user2), 0);
    }

    function test_exactInput_revertsWhenPayerIsSurcharged() public {
        Fixture memory fixture = _createConditionalFixture("SurchargedPull");
        ConditionalTransferERC20 conditionalQuote = ConditionalTransferERC20(address(fixture.quoteToken));
        uint256 quoteInMaxWithProtocolFee = 10 ether;
        fixture.quoteToken.mint(user1, 11 ether);
        vm.prank(user1);
        fixture.quoteToken.approve(address(yachaRouter), quoteInMaxWithProtocolFee);
        conditionalQuote.configure(user1, address(yachaRouter), ConditionalTransferERC20.Behavior.Surcharge, 1_000);

        vm.expectPartialRevert(IYachaRouter.InvalidBalanceDelta.selector);
        vm.prank(user1);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.quoteToken.balanceOf(user1), 11 ether);
        assertEq(fixture.launchToken.balanceOf(user2), 0);
    }

    function test_exactInput_revertsWhenRecipientIsShortCredited() public {
        Fixture memory fixture = _createConditionalFixture("TaxedOutput");
        ConditionalTransferERC20 conditionalQuote = ConditionalTransferERC20(address(fixture.quoteToken));
        uint256 tokenIn = 10 ether;
        uint256 userTokenBefore = _fundAndApproveLaunch(fixture, user1, tokenIn);
        conditionalQuote.configure(address(yachaRouter), user2, ConditionalTransferERC20.Behavior.Tax, 1_000);

        vm.expectPartialRevert(IYachaRouter.InvalidBalanceDelta.selector);
        vm.prank(user1);
        yachaRouter.sell(
            IYachaRouter.SellParams({
                amountIn: tokenIn,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertEq(fixture.launchToken.balanceOf(user1), userTokenBefore);
        assertEq(fixture.quoteToken.balanceOf(user2), 0);
    }

    function test_exactInput_revertsForRouterAsProtocolFeeReceiver() public {
        Fixture memory fixture = launchBelowQuote;
        vm.prank(admin);
        protocolManager.setFeeReceiver(address(yachaRouter));
        _fundAndApproveQuote(fixture, user1, 10 ether);

        vm.expectRevert(IYachaRouter.InvalidRecipient.selector);
        vm.prank(user1);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: 10 ether,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );
    }

    function test_getAmountOutGraduated_buyMatchesExecutionFeeFormula() public {
        Fixture memory fixture = launchBelowQuote;
        uint256 quoteIn = 10 ether;
        uint256 protocolFee = FullMath.mulDivRoundingUp(quoteIn, fixture.protocolFeeRate, BPS);
        uint256 quoteInAfterProtocolFee = quoteIn - protocolFee;
        (uint256 tokenOut,,,) = quoterV2.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(fixture.quoteToken),
                tokenOut: address(fixture.launchToken),
                amountIn: quoteInAfterProtocolFee,
                fee: fixture.feeTier,
                sqrtPriceLimitX96: _priceLimit(address(fixture.quoteToken), address(fixture.launchToken))
            })
        );

        assertEq(yachaRouter.getAmountOut(address(fixture.launchToken), quoteIn, true), tokenOut);
        assertEq(yachaRouter.getDexAmountOut(address(fixture.launchToken), quoteIn, true), tokenOut);
    }

    function test_getAmountOutGraduated_sellMatchesExecutionFeeFormula() public {
        Fixture memory fixture = launchAboveQuote;
        uint256 tokenIn = 10 ether;
        (uint256 quoteOutBeforeProtocolFee,,,) = quoterV2.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(fixture.launchToken),
                tokenOut: address(fixture.quoteToken),
                amountIn: tokenIn,
                fee: fixture.feeTier,
                sqrtPriceLimitX96: _priceLimit(address(fixture.launchToken), address(fixture.quoteToken))
            })
        );
        uint256 protocolFee = FullMath.mulDivRoundingUp(quoteOutBeforeProtocolFee, fixture.protocolFeeRate, BPS);

        assertEq(
            yachaRouter.getAmountOut(address(fixture.launchToken), tokenIn, false),
            quoteOutBeforeProtocolFee - protocolFee
        );
        assertEq(
            yachaRouter.getDexAmountOut(address(fixture.launchToken), tokenIn, false),
            quoteOutBeforeProtocolFee - protocolFee
        );
    }

    function test_getAmountInGraduated_buyGrossesUpQuoterInput() public {
        Fixture memory fixture = launchAboveQuote;
        uint256 tokenOut = 1 ether;
        (uint256 poolQuoteIn,,,) = quoterV2.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(fixture.quoteToken),
                tokenOut: address(fixture.launchToken),
                amount: tokenOut,
                fee: fixture.feeTier,
                sqrtPriceLimitX96: _priceLimit(address(fixture.quoteToken), address(fixture.launchToken))
            })
        );
        uint256 quoteIn = FullMath.mulDivRoundingUp(poolQuoteIn, BPS, BPS - fixture.protocolFeeRate);

        assertEq(yachaRouter.getAmountIn(address(fixture.launchToken), tokenOut, true), quoteIn);
        assertEq(yachaRouter.getDexAmountIn(address(fixture.launchToken), tokenOut, true), quoteIn);
    }

    function test_getAmountInGraduated_sellGrossesUpRequestedNetOutput() public {
        Fixture memory fixture = launchBelowQuote;
        uint256 quoteOut = 1 ether;
        uint256 quoteOutBeforeProtocolFee = FullMath.mulDivRoundingUp(quoteOut, BPS, BPS - fixture.protocolFeeRate);
        (uint256 tokenIn,,,) = quoterV2.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(fixture.launchToken),
                tokenOut: address(fixture.quoteToken),
                amount: quoteOutBeforeProtocolFee,
                fee: fixture.feeTier,
                sqrtPriceLimitX96: _priceLimit(address(fixture.launchToken), address(fixture.quoteToken))
            })
        );

        assertEq(yachaRouter.getAmountIn(address(fixture.launchToken), quoteOut, false), tokenIn);
        assertEq(yachaRouter.getDexAmountIn(address(fixture.launchToken), quoteOut, false), tokenIn);
    }

    function test_getAmountInGraduated_buyRevertsWhenExactOutputCannotBeFilled() public {
        Fixture memory fixture = _createFixture("PartialQuoteBuy", true, LOW_FEE_TIER, LOW_PROTOCOL_FEE_RATE, true);

        vm.expectRevert();
        yachaRouter.getAmountIn(address(fixture.launchToken), PARTIAL_BALANCE, true);
    }

    function test_getAmountInGraduated_sellRevertsWhenExactOutputCannotBeFilled() public {
        Fixture memory fixture = _createFixture("PartialQuoteSell", false, LOW_FEE_TIER, LOW_PROTOCOL_FEE_RATE, true);

        vm.expectRevert();
        yachaRouter.getDexAmountIn(address(fixture.launchToken), PARTIAL_BALANCE, false);
    }

    function test_quoteFunctionsAllowStateChangingQuoterBehavior() public {
        Fixture memory fixture = launchBelowQuote;
        StateChangingQuoter stateChangingQuoter = new StateChangingQuoter(address(v3Factory));
        YachaRouter implementation = new YachaRouter();
        YachaRouter router = YachaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            YachaRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wnative),
                                address(v3SwapAdapter),
                                address(stateChangingQuoter)
                            )
                        )
                    )
                ))
        );

        assertEq(router.getDexAmountOut(address(fixture.launchToken), 1 ether, true), 123);
        assertEq(stateChangingQuoter.calls(), 1);
    }

    function test_stateChangingSwapDoesNotCallQuoter() public {
        Fixture memory fixture = launchBelowQuote;
        vm.mockCallRevert(
            address(quoterV2), abi.encodeWithSelector(IQuoterV2.quoteExactInputSingle.selector), bytes("QuoterCalled")
        );

        assertGt(_executeBuy(fixture, user1, 10 ether), 0);
    }

    function test_runtimeCodeSize_doesNotExceedEip170Limit() public {
        YachaRouter implementation = new YachaRouter();
        assertLe(address(implementation).code.length, EIP170_RUNTIME_LIMIT - MIN_RUNTIME_HEADROOM);
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        assertEq(msg.sender, _mintPool);
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        if (amount0Owed != 0) IERC20(pool.token0()).safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed != 0) IERC20(pool.token1()).safeTransfer(msg.sender, amount1Owed);
    }

    function _createFixture(
        string memory label,
        bool launchIsBelowQuote,
        uint24 feeTier,
        uint16 protocolFeeRate,
        bool nearUpperBoundary
    ) private returns (Fixture memory fixture) {
        MockERC20 first = new MockERC20(string.concat(label, " A"), string.concat(label, "A"), 18);
        MockERC20 second = new MockERC20(string.concat(label, " B"), string.concat(label, "B"), 18);
        fixture = _createFixtureFromTokens(
            label, first, second, launchIsBelowQuote, feeTier, protocolFeeRate, nearUpperBoundary
        );
    }

    function _createFixtureFromTokens(
        string memory,
        MockERC20 first,
        MockERC20 second,
        bool launchIsBelowQuote,
        uint24 feeTier,
        uint16 protocolFeeRate,
        bool nearUpperBoundary
    ) private returns (Fixture memory fixture) {
        (MockERC20 lower, MockERC20 higher) = address(first) < address(second) ? (first, second) : (second, first);
        MockERC20 launchToken = launchIsBelowQuote ? lower : higher;
        MockERC20 quoteToken = launchIsBelowQuote ? higher : lower;

        vm.startPrank(admin);
        protocolManager.addQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            protocolFeeRate
        );
        protocolManager.setV3QuoteConfig(address(quoteToken), feeTier, 0);
        vm.stopPrank();

        address poolAddress = v3Factory.createPool(address(launchToken), address(quoteToken), feeTier);
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        pool.initialize(nearUpperBoundary ? TickMath.getSqrtRatioAtTick(886_000) : uint160(1 << 96));

        uint256 mintBalance = nearUpperBoundary ? PARTIAL_BALANCE : REGULAR_BALANCE;
        launchToken.mint(address(this), mintBalance);
        quoteToken.mint(address(this), mintBalance);
        _mintPool = poolAddress;
        if (nearUpperBoundary) {
            int24 spacing = pool.tickSpacing();
            int24 lowerTick = (TickMath.MIN_TICK / spacing) * spacing;
            int24 upperTick = (TickMath.MAX_TICK / spacing) * spacing;
            pool.mint(address(this), lowerTick, upperTick, PARTIAL_LIQUIDITY, bytes(""));
        } else {
            pool.mint(address(this), -600, 600, REGULAR_LIQUIDITY, bytes(""));
        }
        _mintPool = address(0);

        tokenRegistry.registerV3(address(launchToken), poolAddress, address(quoteToken), feeTier);
        _mockGraduatedCurve(address(launchToken), address(quoteToken), poolAddress);
        fixture = Fixture({
            launchToken: launchToken,
            quoteToken: quoteToken,
            pool: poolAddress,
            feeTier: feeTier,
            protocolFeeRate: protocolFeeRate
        });
    }

    function _mockGraduatedCurve(address launchToken, address quoteToken, address pool) private {
        IBondingCurve.Curve memory curve;
        curve.token = launchToken;
        curve.quoteToken = quoteToken;
        curve.graduated = true;
        curve.dexType = ITokenRegistry.DexType.UniswapV3;
        curve.pair = pool;
        vm.mockCall(address(bondingCurve), abi.encodeCall(IBondingCurve.getCurve, (launchToken)), abi.encode(curve));
    }

    function _fundAndApproveQuote(Fixture memory fixture, address user, uint256 amount)
        private
        returns (uint256 balanceBefore)
    {
        fixture.quoteToken.mint(user, amount);
        balanceBefore = fixture.quoteToken.balanceOf(user);
        vm.prank(user);
        fixture.quoteToken.approve(address(yachaRouter), amount);
    }

    function _fundAndApproveLaunch(Fixture memory fixture, address user, uint256 amount)
        private
        returns (uint256 balanceBefore)
    {
        fixture.launchToken.mint(user, amount);
        balanceBefore = fixture.launchToken.balanceOf(user);
        vm.prank(user);
        fixture.launchToken.approve(address(yachaRouter), amount);
    }

    function _executeBuy(Fixture memory fixture, address user, uint256 quoteInMaxWithProtocolFee)
        private
        returns (uint256 tokenOut)
    {
        _fundAndApproveQuote(fixture, user, quoteInMaxWithProtocolFee);
        vm.prank(user);
        tokenOut = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user,
                deadline: block.timestamp
            })
        );
    }

    function _createConditionalFixture(string memory label) private returns (Fixture memory fixture) {
        ConditionalTransferERC20 first =
            new ConditionalTransferERC20(string.concat(label, " A"), string.concat(label, "A"));
        ConditionalTransferERC20 second =
            new ConditionalTransferERC20(string.concat(label, " B"), string.concat(label, "B"));
        fixture = _createFixtureFromTokens(
            label,
            MockERC20(address(first)),
            MockERC20(address(second)),
            true,
            LOW_FEE_TIER,
            LOW_PROTOCOL_FEE_RATE,
            false
        );
    }

    function _executeBuyAndReadProtocolFee(Fixture memory fixture, address user, uint256 quoteInMaxWithProtocolFee)
        private
        returns (uint256 protocolFee)
    {
        address currentFeeReceiver = protocolManager.feeReceiver();
        uint256 protocolFeeBefore = fixture.quoteToken.balanceOf(currentFeeReceiver);
        _executeBuy(fixture, user, quoteInMaxWithProtocolFee);
        protocolFee = fixture.quoteToken.balanceOf(currentFeeReceiver) - protocolFeeBefore;
    }

    function _buyProtocolFee(uint256 quoteInMaxWithProtocolFee, uint256 protocolFeeRate, uint256 quoteIn)
        private
        pure
        returns (uint256)
    {
        uint256 protocolFeeMax = FullMath.mulDivRoundingUp(quoteInMaxWithProtocolFee, protocolFeeRate, BPS);
        uint256 poolQuoteInMax = quoteInMaxWithProtocolFee - protocolFeeMax;
        return protocolFeeMax == 0 ? 0 : FullMath.mulDivRoundingUp(protocolFeeMax, quoteIn, poolQuoteInMax);
    }

    function _assertTradeEvent(
        Vm.Log[] memory logs,
        bytes32 eventSignature,
        address trader,
        address launchToken,
        uint256 amountIn,
        uint256 amountOut
    ) private {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(yachaRouter) || logs[i].topics[0] != eventSignature) {
                continue;
            }
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(trader))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(launchToken))));
            (uint256 eventAmountIn, uint256 eventAmountOut, bool graduated) =
                abi.decode(logs[i].data, (uint256, uint256, bool));
            assertEq(eventAmountIn, amountIn);
            assertEq(eventAmountOut, amountOut);
            assertTrue(graduated);
            return;
        }
        fail("router trade event not found");
    }

    function _priceLimit(address tokenIn, address tokenOut) private pure returns (uint160) {
        return tokenIn < tokenOut ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
    }
}
