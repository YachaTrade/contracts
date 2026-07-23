// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Tests for YachaRouter permit endpoints, including the front-run guard in `_permit`.
///         The internal `_permit` helper skips the permit call when allowance is already
///         sufficient so a front-running attacker cannot DoS users by consuming their nonce.

import {SetUp} from "../SetUp.t.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IYachaRouter} from "../../src/interfaces/IYachaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {MockERC20Permit} from "../mocks/MockERC20Permit.sol";

contract YachaRouterPermitTest is SetUp {
    uint256 internal sellerKey = 0xA11CE;
    address internal seller;

    address internal token;

    struct PermitBuyFixture {
        MockERC20Permit permitQuote;
        address permitToken;
        uint256 excessAmount;
        uint256 expectedTokenOut;
        uint256 expectedQuoteIn;
        uint256 expectedRefund;
    }

    struct PermitV3Fixture {
        MockERC20Permit launchToken;
        MockERC20Permit quoteToken;
        address pool;
    }

    uint24 private constant PERMIT_V3_FEE_TIER = 500;
    uint128 private constant PERMIT_V3_LIQUIDITY = 1_000_000 ether;
    uint256 private constant PERMIT_V3_BALANCE = 1_000_000_000 ether;
    uint256 private graduatedTraderKey = 0xBEEF;
    address private graduatedTrader;
    address private _mintPool;
    PermitV3Fixture private permitV3;

    function setUp() public override {
        super.setUp();

        seller = vm.addr(sellerKey);

        token = _createToken();

        // Skip past the anti-sniping window so regular fees apply.
        vm.warp(block.timestamp + 100 minutes);

        // Give seller a token balance to sell.
        uint256 buyAmount = 1 ether;
        quoteToken.mint(seller, buyAmount);
        vm.startPrank(seller);
        quoteToken.approve(address(yachaRouter), buyAmount);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: seller, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        graduatedTrader = vm.addr(graduatedTraderKey);
        vm.prank(admin);
        protocolManager.setOperatorPermission(
            address(this), address(tokenRegistry), TokenRegistry.registerV3.selector, true
        );
        permitV3 = _createPermitV3Fixture();
    }

    // ── sellWithPermit ──────────────────────────────────────────────

    function test_sellWithPermit_happyPath() public {
        uint256 sellAmount = IERC20(token).balanceOf(seller) / 4;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(sellerKey, token, seller, address(yachaRouter), sellAmount, deadline);

        uint256 quoteBefore = quoteToken.balanceOf(seller);

        vm.prank(seller);
        uint256 amountOut = yachaRouter.sellWithPermit(
            IYachaRouter.SellWithPermitParams({
                amountIn: sellAmount,
                amountOutMin: 0,
                amountAllowance: sellAmount,
                token: token,
                to: seller,
                deadline: deadline,
                v: v,
                r: r,
                s: s
            })
        );

        assertGt(amountOut, 0, "should receive quote");
        assertEq(quoteToken.balanceOf(seller), quoteBefore + amountOut, "quote credited to seller");
    }

    function test_sellWithPermit_frontRunConsumesSignature_stillSucceeds() public {
        uint256 sellAmount = IERC20(token).balanceOf(seller) / 4;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(sellerKey, token, seller, address(yachaRouter), sellAmount, deadline);

        // Attacker front-runs: pushes the user's signed permit directly. Nonce is consumed
        // but allowance is set, exactly as the permit is designed to work.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        IERC20Permit(token).permit(seller, address(yachaRouter), sellAmount, deadline, v, r, s);
        assertEq(IERC20(token).allowance(seller, address(yachaRouter)), sellAmount, "allowance set by attacker");

        // Router must still complete the sell: allowance pre-check skips the permit call.
        uint256 quoteBefore = quoteToken.balanceOf(seller);
        vm.prank(seller);
        uint256 amountOut = yachaRouter.sellWithPermit(
            IYachaRouter.SellWithPermitParams({
                amountIn: sellAmount,
                amountOutMin: 0,
                amountAllowance: sellAmount,
                token: token,
                to: seller,
                deadline: deadline,
                v: v,
                r: r,
                s: s
            })
        );

        assertGt(amountOut, 0, "sell completed despite nonce being consumed");
        assertEq(quoteToken.balanceOf(seller), quoteBefore + amountOut, "quote credited to seller");
    }

    function test_sellWithPermit_preApproved_skipsPermit() public {
        uint256 sellAmount = IERC20(token).balanceOf(seller) / 4;
        uint256 deadline = block.timestamp + 1 hours;

        // Seller already approved via a direct approve(); no valid signature needed.
        vm.prank(seller);
        IERC20(token).approve(address(yachaRouter), sellAmount);

        // Pass invalid permit params. The allowance pre-check must cause these to be ignored.
        vm.prank(seller);
        uint256 amountOut = yachaRouter.sellWithPermit(
            IYachaRouter.SellWithPermitParams({
                amountIn: sellAmount,
                amountOutMin: 0,
                amountAllowance: sellAmount,
                token: token,
                to: seller,
                deadline: deadline,
                v: 27,
                r: bytes32(0),
                s: bytes32(0)
            })
        );

        assertGt(amountOut, 0, "sell completed with pre-existing allowance");
    }

    // ── buyWithPermit ───────────────────────────────────────────────

    function test_buyWithPermit_bondingCurve_refundsExcessQuote() public {
        uint256 buyerKey = 0xB0B;
        address buyer = vm.addr(buyerKey);
        PermitBuyFixture memory fixture = _preparePermitQuoteBuyFixture();

        fixture.permitQuote.mint(buyer, fixture.excessAmount);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            buyerKey, address(fixture.permitQuote), buyer, address(yachaRouter), fixture.excessAmount, deadline
        );

        vm.prank(buyer);
        uint256 amountOut = yachaRouter.buyWithPermit(
            IYachaRouter.BuyWithPermitParams({
                amountIn: fixture.excessAmount,
                amountOutMin: 0,
                amountAllowance: fixture.excessAmount,
                token: fixture.permitToken,
                to: buyer,
                deadline: deadline,
                v: v,
                r: r,
                s: s
            })
        );

        assertEq(amountOut, fixture.expectedTokenOut, "token out should match capped quote");
        assertEq(fixture.permitQuote.balanceOf(buyer), fixture.expectedRefund, "buyer should receive quote refund");
        assertEq(fixture.permitQuote.balanceOf(address(yachaRouter)), 0, "router should hold no quote");
    }

    function test_buyWithPermit_bondingCurve_checksSlippageBeforeRefund() public {
        uint256 buyerKey = 0xB0B;
        address buyer = vm.addr(buyerKey);
        PermitBuyFixture memory fixture = _preparePermitQuoteBuyFixture();

        fixture.permitQuote.mint(buyer, fixture.excessAmount);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            buyerKey, address(fixture.permitQuote), buyer, address(yachaRouter), fixture.excessAmount, deadline
        );
        vm.mockCallRevert(
            address(fixture.permitQuote),
            abi.encodeCall(IERC20.transfer, (buyer, fixture.expectedRefund)),
            abi.encodeWithSignature("RefundAttempted()")
        );

        vm.prank(buyer);
        vm.expectRevert(IYachaRouter.InsufficientOutput.selector);
        yachaRouter.buyWithPermit(
            IYachaRouter.BuyWithPermitParams({
                amountIn: fixture.excessAmount,
                amountOutMin: fixture.expectedTokenOut + 1,
                amountAllowance: fixture.excessAmount,
                token: fixture.permitToken,
                to: buyer,
                deadline: deadline,
                v: v,
                r: r,
                s: s
            })
        );
    }

    function test_buyWithPermitGraduated_chargesSameFeeAsApprovedBuy() public {
        PermitV3Fixture memory fixture = permitV3;
        uint256 snapshot = vm.snapshotState();
        (uint256 approvedTokenOut, uint256 approvedQuoteIn, uint256 approvedProtocolFee) =
            _approvedGraduatedBuy(fixture, graduatedTrader, 10 ether);
        vm.revertToState(snapshot);

        (uint256 permitTokenOut, uint256 permitQuoteIn, uint256 permitProtocolFee) = _permitGraduatedBuy(10 ether);

        assertEq(permitTokenOut, approvedTokenOut);
        assertEq(permitQuoteIn, approvedQuoteIn);
        assertEq(permitProtocolFee, approvedProtocolFee);
        assertGt(permitProtocolFee, 0);
    }

    function test_sellWithPermitGraduated_chargesSameFeeAsApprovedSell() public {
        PermitV3Fixture memory fixture = permitV3;
        uint256 snapshot = vm.snapshotState();
        (uint256 approvedQuoteOut, uint256 approvedTokenIn, uint256 approvedProtocolFee) =
            _approvedGraduatedSell(fixture, graduatedTrader, 10 ether);
        vm.revertToState(snapshot);

        (uint256 permitQuoteOut, uint256 permitTokenIn, uint256 permitProtocolFee) = _permitGraduatedSell(10 ether);

        assertEq(permitQuoteOut, approvedQuoteOut);
        assertEq(permitTokenIn, approvedTokenIn);
        assertEq(permitProtocolFee, approvedProtocolFee);
        assertGt(permitProtocolFee, 0);
    }

    function test_permitFrontRunWithSufficientAllowanceStillSucceedsAfterGraduation() public {
        PermitV3Fixture memory fixture = permitV3;
        uint256 quoteInMaxWithProtocolFee = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;
        fixture.quoteToken.mint(graduatedTrader, quoteInMaxWithProtocolFee);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            graduatedTraderKey,
            address(fixture.quoteToken),
            graduatedTrader,
            address(yachaRouter),
            quoteInMaxWithProtocolFee,
            deadline
        );

        vm.prank(makeAddr("graduatedPermitAttacker"));
        fixture.quoteToken.permit(graduatedTrader, address(yachaRouter), quoteInMaxWithProtocolFee, deadline, v, r, s);

        vm.prank(graduatedTrader);
        uint256 tokenOut = yachaRouter.buyWithPermit(
            IYachaRouter.BuyWithPermitParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                amountAllowance: quoteInMaxWithProtocolFee,
                token: address(fixture.launchToken),
                to: graduatedTrader,
                deadline: deadline,
                v: v,
                r: r,
                s: s
            })
        );

        assertGt(tokenOut, 0);
        assertEq(fixture.launchToken.balanceOf(graduatedTrader), tokenOut);
    }

    // ── Helpers ─────────────────────────────────────────────────────

    function _createTokenWithQuote(MockERC20Permit permitQuote, bytes32 salt) internal returns (address permitToken) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(feeReceiver)
        });

        permitQuote.mint(creator, defaultDeployFee);
        vm.startPrank(creator);
        permitQuote.approve(address(yachaRouter), defaultDeployFee);
        (permitToken,) = yachaRouter.create(
            IYachaRouter.CreateParams({
                name: "PermitToken",
                symbol: "PRM",
                tokenURI: "",
                quoteToken: address(permitQuote),
                vaults: vaults,
                salt: salt,
                dexType: ITokenRegistry.DexType.UniswapV3,
                buyQuoteAmount: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function _createPermitV3Fixture() private returns (PermitV3Fixture memory fixture) {
        MockERC20Permit first = new MockERC20Permit("Graduated Permit A", "GPA", 18);
        MockERC20Permit second = new MockERC20Permit("Graduated Permit B", "GPB", 18);
        (fixture.launchToken, fixture.quoteToken) = address(first) < address(second) ? (first, second) : (second, first);

        vm.startPrank(admin);
        protocolManager.addQuoteToken(
            address(fixture.quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee
        );
        protocolManager.setV3QuoteConfig(address(fixture.quoteToken), PERMIT_V3_FEE_TIER, 0);
        vm.stopPrank();

        fixture.pool =
            v3Factory.createPool(address(fixture.launchToken), address(fixture.quoteToken), PERMIT_V3_FEE_TIER);
        IUniswapV3Pool pool = IUniswapV3Pool(fixture.pool);
        pool.initialize(uint160(1 << 96));
        fixture.launchToken.mint(address(this), PERMIT_V3_BALANCE);
        fixture.quoteToken.mint(address(this), PERMIT_V3_BALANCE);
        _mintPool = fixture.pool;
        pool.mint(address(this), -600, 600, PERMIT_V3_LIQUIDITY, bytes(""));
        _mintPool = address(0);

        tokenRegistry.registerV3(
            address(fixture.launchToken), fixture.pool, address(fixture.quoteToken), PERMIT_V3_FEE_TIER
        );
        IBondingCurve.Curve memory curve;
        curve.token = address(fixture.launchToken);
        curve.quoteToken = address(fixture.quoteToken);
        curve.graduated = true;
        curve.dexType = ITokenRegistry.DexType.UniswapV3;
        curve.pair = fixture.pool;
        vm.mockCall(
            address(bondingCurve),
            abi.encodeCall(IBondingCurve.getCurve, (address(fixture.launchToken))),
            abi.encode(curve)
        );
    }

    function _approvedGraduatedBuy(PermitV3Fixture memory fixture, address buyer, uint256 quoteInMaxWithProtocolFee)
        private
        returns (uint256 tokenOut, uint256 quoteInWithProtocolFee, uint256 protocolFee)
    {
        fixture.quoteToken.mint(buyer, quoteInMaxWithProtocolFee);
        uint256 buyerQuoteBefore = fixture.quoteToken.balanceOf(buyer);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        vm.startPrank(buyer);
        fixture.quoteToken.approve(address(yachaRouter), quoteInMaxWithProtocolFee);
        tokenOut = yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: buyer,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        quoteInWithProtocolFee = buyerQuoteBefore - fixture.quoteToken.balanceOf(buyer);
        protocolFee = fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore;
    }

    function _permitGraduatedBuy(uint256 quoteInMaxWithProtocolFee)
        private
        returns (uint256 tokenOut, uint256 quoteInWithProtocolFee, uint256 protocolFee)
    {
        PermitV3Fixture memory fixture = permitV3;
        uint256 deadline = block.timestamp + 1 hours;
        fixture.quoteToken.mint(graduatedTrader, quoteInMaxWithProtocolFee);
        uint256 buyerQuoteBefore = fixture.quoteToken.balanceOf(graduatedTrader);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            graduatedTraderKey,
            address(fixture.quoteToken),
            graduatedTrader,
            address(yachaRouter),
            quoteInMaxWithProtocolFee,
            deadline
        );
        vm.prank(graduatedTrader);
        tokenOut = yachaRouter.buyWithPermit(
            IYachaRouter.BuyWithPermitParams({
                amountIn: quoteInMaxWithProtocolFee,
                amountOutMin: 1,
                amountAllowance: quoteInMaxWithProtocolFee,
                token: address(fixture.launchToken),
                to: graduatedTrader,
                deadline: deadline,
                v: v,
                r: r,
                s: s
            })
        );
        quoteInWithProtocolFee = buyerQuoteBefore - fixture.quoteToken.balanceOf(graduatedTrader);
        protocolFee = fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore;
    }

    function _approvedGraduatedSell(PermitV3Fixture memory fixture, address seller_, uint256 tokenInMax)
        private
        returns (uint256 quoteOut, uint256 tokenIn, uint256 protocolFee)
    {
        fixture.launchToken.mint(seller_, tokenInMax);
        uint256 sellerTokenBefore = fixture.launchToken.balanceOf(seller_);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        vm.startPrank(seller_);
        fixture.launchToken.approve(address(yachaRouter), tokenInMax);
        quoteOut = yachaRouter.sell(
            IYachaRouter.SellParams({
                amountIn: tokenInMax,
                amountOutMin: 1,
                token: address(fixture.launchToken),
                to: seller_,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        tokenIn = sellerTokenBefore - fixture.launchToken.balanceOf(seller_);
        protocolFee = fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore;
    }

    function _permitGraduatedSell(uint256 tokenInMax)
        private
        returns (uint256 quoteOut, uint256 tokenIn, uint256 protocolFee)
    {
        PermitV3Fixture memory fixture = permitV3;
        uint256 deadline = block.timestamp + 1 hours;
        fixture.launchToken.mint(graduatedTrader, tokenInMax);
        uint256 sellerTokenBefore = fixture.launchToken.balanceOf(graduatedTrader);
        uint256 feeReceiverQuoteBefore = fixture.quoteToken.balanceOf(feeReceiver);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            graduatedTraderKey,
            address(fixture.launchToken),
            graduatedTrader,
            address(yachaRouter),
            tokenInMax,
            deadline
        );
        vm.prank(graduatedTrader);
        quoteOut = yachaRouter.sellWithPermit(
            IYachaRouter.SellWithPermitParams({
                amountIn: tokenInMax,
                amountOutMin: 1,
                amountAllowance: tokenInMax,
                token: address(fixture.launchToken),
                to: graduatedTrader,
                deadline: deadline,
                v: v,
                r: r,
                s: s
            })
        );
        tokenIn = sellerTokenBefore - fixture.launchToken.balanceOf(graduatedTrader);
        protocolFee = fixture.quoteToken.balanceOf(feeReceiver) - feeReceiverQuoteBefore;
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        assertEq(msg.sender, _mintPool);
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        if (amount0Owed != 0) IERC20(pool.token0()).transfer(msg.sender, amount0Owed);
        if (amount1Owed != 0) IERC20(pool.token1()).transfer(msg.sender, amount1Owed);
    }

    function _preparePermitQuoteBuyFixture() internal returns (PermitBuyFixture memory fixture) {
        fixture.permitQuote = new MockERC20Permit("Permit Quote", "PQT", 18);

        vm.startPrank(admin);
        protocolManager.addQuoteToken(
            address(fixture.permitQuote),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee
        );
        protocolManager.setV3QuoteConfig(
            address(fixture.permitQuote), DEFAULT_V3_FEE_TIER, DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS
        );
        vm.stopPrank();

        fixture.permitToken = _createTokenWithQuote(fixture.permitQuote, keccak256("permit-quote-token"));
        vm.warp(block.timestamp + 100 minutes);

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(fixture.permitToken);
        uint256 targetTokens = (curve.virtualTokenReserve - curve.minTokenReserve) * 90 / 100;
        uint256 quoteNeeded = bondingCurve.getAmountIn(fixture.permitToken, targetTokens, true);

        fixture.permitQuote.mint(user1, quoteNeeded);
        vm.startPrank(user1);
        fixture.permitQuote.approve(address(yachaRouter), quoteNeeded);
        yachaRouter.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteNeeded,
                amountOutMin: 0,
                token: fixture.permitToken,
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(fixture.permitToken);
        uint256 remainingTokens = curveAfter.virtualTokenReserve - curveAfter.minTokenReserve;
        uint256 exactNeeded = bondingCurve.getAmountIn(fixture.permitToken, remainingTokens, true);
        fixture.excessAmount = exactNeeded * 10;
        fixture.expectedTokenOut = bondingCurve.getAmountOut(fixture.permitToken, fixture.excessAmount, true);
        fixture.expectedQuoteIn = bondingCurve.getAmountIn(fixture.permitToken, fixture.expectedTokenOut, true);
        if (fixture.expectedQuoteIn > fixture.excessAmount) fixture.expectedQuoteIn = fixture.excessAmount;
        fixture.expectedRefund = fixture.excessAmount - fixture.expectedQuoteIn;
    }

    function _signPermit(
        uint256 ownerKey,
        address token_,
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_
    ) internal view returns (uint8, bytes32, bytes32) {
        uint256 nonce = IERC20Permit(token_).nonces(owner_);
        bytes32 typeHash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typeHash, owner_, spender_, value_, nonce, deadline_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token_).DOMAIN_SEPARATOR(), structHash));
        return vm.sign(ownerKey, digest);
    }
}
