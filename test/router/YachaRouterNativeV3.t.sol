// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {SetUp} from "../SetUp.t.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IYachaRouter} from "../../src/interfaces/IYachaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC20Permit} from "../mocks/MockERC20Permit.sol";

contract RejectNativeReceiver {}

contract YachaRouterNativeV3Test is SetUp {
    using SafeERC20 for IERC20;

    struct Fixture {
        MockERC20Permit launchToken;
        address pool;
        uint24 feeTier;
        uint16 protocolFeeRate;
    }

    uint256 private constant BPS = 10_000;
    uint24 private constant NATIVE_FEE_TIER = 500;
    uint16 private constant NATIVE_PROTOCOL_FEE_RATE = 35;
    uint128 private constant REGULAR_LIQUIDITY = 1_000_000 ether;
    uint128 private constant PARTIAL_LIQUIDITY = 1e30;
    uint256 private constant REGULAR_BALANCE = 1_000_000_000 ether;
    uint256 private constant PARTIAL_BALANCE = 1e52;
    uint256 private constant PARTIAL_INPUT = 1e50;

    uint256 private nativeSellerKey = 0xA11CE;
    address private nativeSeller;
    address private _mintPool;
    Fixture private regularNative;
    Fixture private partialNative;

    function setUp() public override {
        super.setUp();
        nativeSeller = vm.addr(nativeSellerKey);

        vm.startPrank(admin);
        protocolManager.addQuoteToken(
            address(wnative),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            NATIVE_PROTOCOL_FEE_RATE
        );
        protocolManager.setV3QuoteConfig(address(wnative), NATIVE_FEE_TIER, 0);
        protocolManager.setOperatorPermission(
            address(this), address(tokenRegistry), TokenRegistry.registerV3.selector, true
        );
        vm.stopPrank();

        regularNative = _createNativeFixture("Native Regular", false);
        partialNative = _createNativeFixture("Native Partial", true);
        vm.deal(address(wnative), PARTIAL_BALANCE);
    }

    function test_buyWithNativeGraduated_wrapsOnlyMsgValueAndRefundsUnusedNative() public {
        Fixture memory fixture = partialNative;
        uint256 quoteInMax = PARTIAL_INPUT;
        uint256 wnativeDonation = 7 ether;
        uint256 nativeDonation = 11 ether;
        wnative.mint(address(yachaRouter), wnativeDonation);
        vm.deal(address(yachaRouter), nativeDonation);
        vm.deal(user1, quoteInMax + 1 ether);
        uint256 userNativeBefore = user1.balance;
        uint256 poolQuoteBefore = wnative.balanceOf(fixture.pool);
        uint256 feeReceiverQuoteBefore = wnative.balanceOf(feeReceiver);

        vm.prank(user1);
        uint256 tokenOut = yachaRouter.buyWithNative{value: quoteInMax}(
            IYachaRouter.BuyWithNativeParams({
                amountOutMin: 1, token: address(fixture.launchToken), to: user2, deadline: block.timestamp
            })
        );

        uint256 poolQuoteIn = wnative.balanceOf(fixture.pool) - poolQuoteBefore;
        uint256 protocolFeeMax = FullMath.mulDivRoundingUp(quoteInMax, fixture.protocolFeeRate, BPS);
        uint256 poolQuoteInMax = quoteInMax - protocolFeeMax;
        uint256 protocolFee = FullMath.mulDivRoundingUp(protocolFeeMax, poolQuoteIn, poolQuoteInMax);
        assertGt(tokenOut, 0);
        assertLt(poolQuoteIn, poolQuoteInMax);
        assertEq(userNativeBefore - user1.balance, poolQuoteIn + protocolFee);
        assertEq(wnative.balanceOf(feeReceiver) - feeReceiverQuoteBefore, protocolFee);
        assertEq(wnative.balanceOf(address(yachaRouter)), wnativeDonation);
        assertEq(address(yachaRouter).balance, nativeDonation);
    }

    function test_exactOutBuyWithNativeGraduated_refundsUnusedNative() public {
        Fixture memory fixture = regularNative;
        uint256 quoteInMax = 10 ether;
        uint256 tokenOut = 1 ether;
        uint256 wnativeDonation = 7 ether;
        uint256 nativeDonation = 11 ether;
        wnative.mint(address(yachaRouter), wnativeDonation);
        vm.deal(address(yachaRouter), nativeDonation);
        vm.deal(user1, quoteInMax);
        uint256 userNativeBefore = user1.balance;
        uint256 recipientTokenBefore = fixture.launchToken.balanceOf(user2);

        vm.prank(user1);
        uint256 quoteIn = yachaRouter.exactOutBuyWithNative{value: quoteInMax}(
            IYachaRouter.ExactOutBuyWithNativeParams({
                amountOut: tokenOut, token: address(fixture.launchToken), to: user2, deadline: block.timestamp
            })
        );

        assertGt(quoteIn, 0);
        assertLt(quoteIn, quoteInMax);
        assertEq(userNativeBefore - user1.balance, quoteIn);
        assertEq(fixture.launchToken.balanceOf(user2) - recipientTokenBefore, tokenOut);
        assertEq(wnative.balanceOf(address(yachaRouter)), wnativeDonation);
        assertEq(address(yachaRouter).balance, nativeDonation);
    }

    function test_sellToNativeGraduated_paysFeeInWnativeAndSendsNetNative() public {
        Fixture memory fixture = regularNative;
        uint256 tokenInMax = 10 ether;
        _fundAndApproveLaunch(fixture, user1, tokenInMax);
        uint256 userNativeBefore = user1.balance;
        uint256 feeReceiverQuoteBefore = wnative.balanceOf(feeReceiver);
        uint256 poolQuoteBefore = wnative.balanceOf(fixture.pool);

        vm.prank(user1);
        uint256 nativeOut = yachaRouter.sellToNative(
            IYachaRouter.SellToNativeParams({
                amountIn: tokenInMax,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user1,
                deadline: block.timestamp
            })
        );

        uint256 quoteOutBeforeProtocolFee = poolQuoteBefore - wnative.balanceOf(fixture.pool);
        uint256 protocolFee = FullMath.mulDivRoundingUp(quoteOutBeforeProtocolFee, fixture.protocolFeeRate, BPS);
        assertEq(nativeOut, quoteOutBeforeProtocolFee - protocolFee);
        assertEq(user1.balance - userNativeBefore, nativeOut);
        assertEq(wnative.balanceOf(feeReceiver) - feeReceiverQuoteBefore, protocolFee);
    }

    function test_sellToNativeWithPermitGraduated_usesSharedAccounting() public {
        Fixture memory fixture = regularNative;
        uint256 tokenInMax = 10 ether;
        fixture.launchToken.mint(nativeSeller, tokenInMax);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            nativeSellerKey, address(fixture.launchToken), nativeSeller, address(yachaRouter), tokenInMax, deadline
        );
        uint256 nativeBefore = nativeSeller.balance;

        vm.prank(nativeSeller);
        uint256 nativeOut = yachaRouter.sellToNativeWithPermit(
            IYachaRouter.SellToNativeWithPermitParams({
                amountIn: tokenInMax,
                amountOutMin: 1,
                amountAllowance: tokenInMax,
                token: address(fixture.launchToken),
                to: nativeSeller,
                deadline: deadline,
                v: v,
                r: r,
                s: s
            })
        );

        assertGt(nativeOut, 0);
        assertEq(nativeSeller.balance - nativeBefore, nativeOut);
    }

    function test_exactOutSellToNativeGraduated_sendsExactNetNativeAndReturnsTokenInput() public {
        Fixture memory fixture = regularNative;
        uint256 amountInMax = 10 ether;
        uint256 nativeOut = 1 ether;
        uint256 wnativeDonation = 7 ether;
        uint256 nativeDonation = 11 ether;
        wnative.mint(address(yachaRouter), wnativeDonation);
        vm.deal(address(yachaRouter), nativeDonation);
        uint256 userTokenBefore = _fundAndApproveLaunch(fixture, user1, amountInMax);
        uint256 recipientNativeBefore = user2.balance;

        vm.prank(user1);
        uint256 tokenIn = yachaRouter.exactOutSellToNative(
            IYachaRouter.ExactOutSellToNativeParams({
                amountInMax: amountInMax,
                amountOut: nativeOut,
                token: address(fixture.launchToken),
                to: user2,
                deadline: block.timestamp
            })
        );

        assertGt(tokenIn, 0);
        assertLt(tokenIn, amountInMax);
        assertEq(userTokenBefore - fixture.launchToken.balanceOf(user1), tokenIn);
        assertEq(user2.balance - recipientNativeBefore, nativeOut);
        assertEq(wnative.balanceOf(address(yachaRouter)), wnativeDonation);
        assertEq(address(yachaRouter).balance, nativeDonation);
    }

    function test_nativeV3Route_rejectsNonWnativeQuoteTokenBeforePermitOrAssetMovement() public {
        address foreignToken = _createForeignQuoteFixture();

        vm.deal(user1, 2 ether);
        vm.expectRevert(IYachaRouter.InvalidNativeQuoteToken.selector);
        vm.prank(user1);
        yachaRouter.buyWithNative{value: 1 ether}(
            IYachaRouter.BuyWithNativeParams({
                amountOutMin: 0, token: foreignToken, to: user1, deadline: block.timestamp
            })
        );

        vm.expectRevert(IYachaRouter.InvalidNativeQuoteToken.selector);
        vm.prank(user1);
        yachaRouter.sellToNativeWithPermit(
            IYachaRouter.SellToNativeWithPermitParams({
                amountIn: 1 ether,
                amountOutMin: 0,
                amountAllowance: 1 ether,
                token: foreignToken,
                to: user1,
                deadline: block.timestamp,
                v: 27,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function test_nativeV3Route_doesNotSweepPreexistingWnativeOrNative() public {
        Fixture memory fixture = regularNative;
        uint256 wnativeDonation = 3 ether;
        uint256 nativeDonation = 5 ether;
        wnative.mint(address(yachaRouter), wnativeDonation);
        vm.deal(address(yachaRouter), nativeDonation);
        _fundAndApproveLaunch(fixture, user1, 10 ether);

        vm.prank(user1);
        yachaRouter.sellToNative(
            IYachaRouter.SellToNativeParams({
                amountIn: 10 ether,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: user1,
                deadline: block.timestamp
            })
        );

        assertEq(wnative.balanceOf(address(yachaRouter)), wnativeDonation);
        assertEq(address(yachaRouter).balance, nativeDonation);
    }

    function test_sellToNativeGraduated_revertsAtomicallyWhenRecipientRejectsNative() public {
        Fixture memory fixture = regularNative;
        RejectNativeReceiver receiver = new RejectNativeReceiver();
        uint256 tokenIn = 10 ether;
        uint256 userTokenBefore = _fundAndApproveLaunch(fixture, user1, tokenIn);
        uint256 poolTokenBefore = fixture.launchToken.balanceOf(fixture.pool);
        uint256 feeReceiverQuoteBefore = wnative.balanceOf(feeReceiver);

        vm.expectRevert(IYachaRouter.NativeTransferFailed.selector);
        vm.prank(user1);
        yachaRouter.sellToNative(
            IYachaRouter.SellToNativeParams({
                amountIn: tokenIn,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: address(receiver),
                deadline: block.timestamp
            })
        );

        assertEq(fixture.launchToken.balanceOf(user1), userTokenBefore);
        assertEq(fixture.launchToken.balanceOf(fixture.pool), poolTokenBefore);
        assertEq(wnative.balanceOf(feeReceiver), feeReceiverQuoteBefore);
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        assertEq(msg.sender, _mintPool);
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        if (amount0Owed != 0) IERC20(pool.token0()).safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed != 0) IERC20(pool.token1()).safeTransfer(msg.sender, amount1Owed);
    }

    function _createNativeFixture(string memory label, bool partialFill) private returns (Fixture memory fixture) {
        fixture.launchToken = new MockERC20Permit(label, label, 18);
        fixture.pool = v3Factory.createPool(address(fixture.launchToken), address(wnative), NATIVE_FEE_TIER);
        fixture.feeTier = NATIVE_FEE_TIER;
        fixture.protocolFeeRate = NATIVE_PROTOCOL_FEE_RATE;

        IUniswapV3Pool pool = IUniswapV3Pool(fixture.pool);
        uint160 sqrtPrice;
        if (partialFill) {
            sqrtPrice = TickMath.getSqrtRatioAtTick(
                address(wnative) < address(fixture.launchToken) ? int24(-886_000) : int24(886_000)
            );
        } else {
            sqrtPrice = uint160(1 << 96);
        }
        pool.initialize(sqrtPrice);

        uint256 balance = partialFill ? PARTIAL_BALANCE : REGULAR_BALANCE;
        fixture.launchToken.mint(address(this), balance);
        wnative.mint(address(this), balance);
        _mintPool = fixture.pool;
        if (partialFill) {
            int24 spacing = pool.tickSpacing();
            pool.mint(
                address(this),
                (TickMath.MIN_TICK / spacing) * spacing,
                (TickMath.MAX_TICK / spacing) * spacing,
                PARTIAL_LIQUIDITY,
                bytes("")
            );
        } else {
            pool.mint(address(this), -600, 600, REGULAR_LIQUIDITY, bytes(""));
        }
        _mintPool = address(0);

        tokenRegistry.registerV3(address(fixture.launchToken), fixture.pool, address(wnative), fixture.feeTier);
        _mockGraduatedCurve(address(fixture.launchToken), address(wnative), fixture.pool);
    }

    function _createForeignQuoteFixture() private returns (address launchToken) {
        MockERC20Permit launch = new MockERC20Permit("Foreign Launch", "FL", 18);
        MockERC20 foreignQuote = new MockERC20("Foreign Quote", "FQ", 18);
        vm.startPrank(admin);
        protocolManager.addQuoteToken(
            address(foreignQuote),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            NATIVE_PROTOCOL_FEE_RATE
        );
        protocolManager.setV3QuoteConfig(address(foreignQuote), NATIVE_FEE_TIER, 0);
        vm.stopPrank();
        address pool = v3Factory.createPool(address(launch), address(foreignQuote), NATIVE_FEE_TIER);
        tokenRegistry.registerV3(address(launch), pool, address(foreignQuote), NATIVE_FEE_TIER);
        _mockGraduatedCurve(address(launch), address(foreignQuote), pool);
        launchToken = address(launch);
    }

    function _mockGraduatedCurve(address token, address quote, address pool) private {
        IBondingCurve.Curve memory curve;
        curve.token = token;
        curve.quoteToken = quote;
        curve.graduated = true;
        curve.dexType = ITokenRegistry.DexType.UniswapV3;
        curve.pair = pool;
        vm.mockCall(address(bondingCurve), abi.encodeCall(IBondingCurve.getCurve, (token)), abi.encode(curve));
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

    function _signPermit(
        uint256 ownerKey,
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) private view returns (uint8, bytes32, bytes32) {
        uint256 nonce = IERC20Permit(token).nonces(owner);
        bytes32 typeHash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typeHash, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        return vm.sign(ownerKey, digest);
    }
}
