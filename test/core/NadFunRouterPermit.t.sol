// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Tests for NadFunRouter permit endpoints, including the front-run guard in `_permit`.
///         The internal `_permit` helper skips the permit call when allowance is already
///         sufficient so a front-running attacker cannot DoS users by consuming their nonce.

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {MockERC20Permit} from "../mocks/MockERC20Permit.sol";

contract NadFunRouterPermitTest is SetUp {
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
        quoteToken.approve(address(nadFunRouter), buyAmount);
        nadFunRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: seller, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    // ── sellWithPermit ──────────────────────────────────────────────

    function test_sellWithPermit_happyPath() public {
        uint256 sellAmount = IERC20(token).balanceOf(seller) / 4;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(sellerKey, token, seller, address(nadFunRouter), sellAmount, deadline);

        uint256 quoteBefore = quoteToken.balanceOf(seller);

        vm.prank(seller);
        uint256 amountOut = nadFunRouter.sellWithPermit(
            INadFunRouter.SellWithPermitParams({
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
            _signPermit(sellerKey, token, seller, address(nadFunRouter), sellAmount, deadline);

        // Attacker front-runs: pushes the user's signed permit directly. Nonce is consumed
        // but allowance is set, exactly as the permit is designed to work.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        IERC20Permit(token).permit(seller, address(nadFunRouter), sellAmount, deadline, v, r, s);
        assertEq(IERC20(token).allowance(seller, address(nadFunRouter)), sellAmount, "allowance set by attacker");

        // Router must still complete the sell: allowance pre-check skips the permit call.
        uint256 quoteBefore = quoteToken.balanceOf(seller);
        vm.prank(seller);
        uint256 amountOut = nadFunRouter.sellWithPermit(
            INadFunRouter.SellWithPermitParams({
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
        IERC20(token).approve(address(nadFunRouter), sellAmount);

        // Pass invalid permit params. The allowance pre-check must cause these to be ignored.
        vm.prank(seller);
        uint256 amountOut = nadFunRouter.sellWithPermit(
            INadFunRouter.SellWithPermitParams({
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
            buyerKey, address(fixture.permitQuote), buyer, address(nadFunRouter), fixture.excessAmount, deadline
        );

        vm.expectEmit(true, true, false, true, address(fixture.permitQuote));
        emit IERC20.Transfer(buyer, address(nadFunRouter), fixture.excessAmount);
        vm.expectEmit(true, true, false, true, address(fixture.permitQuote));
        emit IERC20.Transfer(address(nadFunRouter), address(bondingCurve), fixture.expectedQuoteIn);
        vm.expectEmit(true, true, false, true, address(fixture.permitQuote));
        emit IERC20.Transfer(address(nadFunRouter), buyer, fixture.expectedRefund);

        vm.prank(buyer);
        uint256 amountOut = nadFunRouter.buyWithPermit(
            INadFunRouter.BuyWithPermitParams({
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
        assertEq(fixture.permitQuote.balanceOf(address(nadFunRouter)), 0, "router should hold no quote");
    }

    // ── Helpers ─────────────────────────────────────────────────────

    function _createTokenWithQuote(MockERC20Permit permitQuote, bytes32 salt) internal returns (address permitToken) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(feeReceiver)
        });

        permitQuote.mint(creator, defaultDeployFee);
        vm.startPrank(creator);
        permitQuote.approve(address(nadFunRouter), defaultDeployFee);
        (permitToken,) = nadFunRouter.create(
            INadFunRouter.CreateParams({
                name: "PermitToken",
                symbol: "PRM",
                tokenURI: "",
                quoteToken: address(permitQuote),
                creatorFeeRate: defaultCreatorFeeRate,
                vaults: vaults,
                salt: salt,
                dexType: ITokenRegistry.DexType.UniswapV2,
                buyQuoteAmount: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function _preparePermitQuoteBuyFixture() internal returns (PermitBuyFixture memory fixture) {
        fixture.permitQuote = new MockERC20Permit("Permit Quote", "PQT", 18);

        vm.prank(admin);
        protocolManager.addQuoteToken(
            address(fixture.permitQuote),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee,
            settlementThreshold
        );

        fixture.permitToken = _createTokenWithQuote(fixture.permitQuote, keccak256("permit-quote-token"));
        vm.warp(block.timestamp + 100 minutes);

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(fixture.permitToken);
        uint256 targetTokens = (curve.virtualTokenReserve - curve.minTokenReserve) * 90 / 100;
        uint256 quoteNeeded = bondingCurve.getAmountIn(fixture.permitToken, targetTokens, true);

        fixture.permitQuote.mint(user1, quoteNeeded);
        vm.startPrank(user1);
        fixture.permitQuote.approve(address(nadFunRouter), quoteNeeded);
        nadFunRouter.buy(
            INadFunRouter.BuyParams({
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
