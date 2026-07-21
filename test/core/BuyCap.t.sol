// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for BuyCap.

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {BondingCurveLibrary} from "../../src/libraries/BondingCurveLibrary.sol";

contract BuyCapTest is SetUp {
    address vault;
    address token;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");

        vm.startPrank(admin);
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));
        vm.stopPrank();

        // Transfer deployFee to bondingCurve before create (balance detection)
        quoteToken.mint(address(this), defaultDeployFee);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee);
        (token,) = bondingCurve.create(_capParams());

        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    function test_buy_exceedsTarget_clampedAndExcessToFee() public {
        _buyHalfAvailable(user1);

        IBondingCurve.Curve memory curveMid = bondingCurve.getCurve(token);
        assertGt(curveMid.virtualTokenReserve - minTokenReserve, 0, "Should have available tokens before cap");

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);

        uint256 availableTokens = curveMid.virtualTokenReserve - curveMid.minTokenReserve;
        uint256 capBuyAmount = bondingCurve.getAmountIn(token, availableTokens, true) + 100 ether;
        _mintAndTransfer(user2, capBuyAmount);
        vm.prank(user2);
        bondingCurve.buy(user2, token);

        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        assertEq(curveAfter.virtualTokenReserve, minTokenReserve, "Should hit min reserve exactly");

        assertEq(quoteToken.balanceOf(user2), 0, "No refund to user");

        assertGt(quoteToken.balanceOf(feeReceiver) - feeReceiverBefore, 0, "Excess should go to feeReceiver");

        assertTrue(curveAfter.graduated, "Token should be graduated");
    }

    function test_buy_exactlyAtTarget_graduates() public {
        // 700,000 ether is enough to reach graduation with fees
        _mintAndTransfer(user1, 700_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        assertLe(curveAfter.virtualTokenReserve, minTokenReserve, "Should reach min reserve");
        assertTrue(curveAfter.graduated, "Token should be graduated");
    }

    function test_buy_belowTarget_normalBehavior() public {
        uint256 buyAmount = 1_000 ether;
        _mintAndTransfer(user1, buyAmount);

        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token);

        // V2 additive fee: totalFeeRate = curveProtocolFeeRate + creatorFeeRate
        uint256 totalFeeRate = uint256(defaultCurveProtocolFee) + 500;
        uint256 quoteInAfterFees = buyAmount * (10000 - totalFeeRate) / 10000;
        uint256 k = virtualReserve * virtualTokenReserve;
        uint256 newReserveIn = virtualReserve + quoteInAfterFees;
        uint256 newReserveOut = (k + newReserveIn - 1) / newReserveIn;
        uint256 expectedTokenOut = virtualTokenReserve - newReserveOut;
        assertEq(tokenOut, expectedTokenOut, "Token output should match normal bonding curve calculation");

        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        assertFalse(curveAfter.graduated, "Token should not be graduated");
    }

    function test_initialBuy_exceedsTarget_clampedExcessToFee() public {
        uint256 initialBuyAmount = 800_000 ether;
        quoteToken.mint(address(this), defaultDeployFee + initialBuyAmount);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee + initialBuyAmount);

        IBondingCurve.CreateTokenParams memory params = _capParamsWithSalt(keccak256("initialBuyCapTest"));
        params.buyQuoteAmount = initialBuyAmount;

        (address newToken,) = bondingCurve.create(params);

        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(newToken);
        assertEq(curveAfter.virtualTokenReserve, curveAfter.minTokenReserve, "Should hit min reserve exactly");
        assertTrue(curveAfter.graduated, "Token should graduate from initial buy cap");
    }

    function test_buy_exceedsTarget_excessAddedToFee() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0, 0
        ); // 1% curveProtocolFee

        _buyHalfAvailable(user1);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);

        IBondingCurve.Curve memory curveMid = bondingCurve.getCurve(token);
        uint256 availableTokens = curveMid.virtualTokenReserve - curveMid.minTokenReserve;
        uint256 bigBuyAmount = bondingCurve.getAmountIn(token, availableTokens, true) + 100 ether;
        _mintAndTransfer(user2, bigBuyAmount);
        vm.prank(user2);
        bondingCurve.buy(user2, token);

        uint256 feeCollected = quoteToken.balanceOf(feeReceiver) - feeReceiverBefore;
        uint256 protocolFeeOnly = (bigBuyAmount * 100) / 10000; // 1% of bigBuyAmount
        assertGt(feeCollected, protocolFeeOnly, "Fee should include excess quote beyond protocol fee");

        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        assertTrue(curveAfter.graduated, "Token should be graduated");
    }

    function test_getAmountOut_cappedAtTarget() public {
        _buyHalfAvailable(user1);

        IBondingCurve.Curve memory curveMid = bondingCurve.getCurve(token);
        uint256 availableTokens = curveMid.virtualTokenReserve - curveMid.minTokenReserve;

        uint256 capBuyAmount = bondingCurve.getAmountIn(token, availableTokens, true) + 100 ether;
        uint256 viewOut = bondingCurve.getAmountOut(token, capBuyAmount, true);
        assertLe(viewOut, availableTokens, "getAmountOut should be capped at available tokens");

        uint256 smallAmount = 100 ether;
        uint256 smallViewOut = bondingCurve.getAmountOut(token, smallAmount, true);
        // V2 additive fee: totalFeeRate = curveProtocolFeeRate + creatorFeeRate
        uint256 totalFeeRate = uint256(defaultCurveProtocolFee) + 500;
        uint256 afterCreatorFee = smallAmount * (10000 - totalFeeRate) / 10000;
        uint256 uncappedOut = BondingCurveLibrary.getAmountOut(
            afterCreatorFee, curveMid.k, curveMid.virtualQuoteReserve, curveMid.virtualTokenReserve
        );
        assertEq(smallViewOut, uncappedOut, "Small buy should not be capped");
    }

    function test_buy_snipingPenaltyWithCap() public {
        quoteToken.mint(address(this), defaultDeployFee);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee);
        (address snipingToken,) = bondingCurve.create(_capParamsWithSalt(keccak256("snipingCap")));

        // Roll to the last block of the sniping table (table[6] = 500 BPS = 5%) — small penalty
        // still applies and a big enough buy must still graduate the curve.
        IBondingCurve.Curve memory curveBefore = bondingCurve.getCurve(snipingToken);
        vm.roll(uint256(curveBefore.createdAtBlock) + 6);
        assertEq(bondingCurve.getSnipingPenalty(snipingToken), 500, "precondition: tail of sniping window");

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);

        uint256 bigBuyAmount = 800_000 ether;
        _mintAndTransfer(user1, bigBuyAmount);
        vm.prank(user1);
        bondingCurve.buy(user1, snipingToken);

        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(snipingToken);

        assertEq(curveAfter.virtualTokenReserve, curveAfter.minTokenReserve, "Should hit min reserve");
        assertTrue(curveAfter.graduated, "Should be graduated");

        uint256 feeReceiverAfter = quoteToken.balanceOf(feeReceiver);
        uint256 totalFee = feeReceiverAfter - feeReceiverBefore;
        assertGt(totalFee, 0, "FeeReceiver should receive sniping + excess fees");

        assertEq(quoteToken.balanceOf(user1), 0, "No refund to user");
    }

    function test_getAmountIn_revertsAboveAvailableTokenOut() public {
        _buyHalfAvailable(user1);

        IBondingCurve.Curve memory curveMid = bondingCurve.getCurve(token);
        uint256 availableTokens = curveMid.virtualTokenReserve - curveMid.minTokenReserve;

        vm.expectRevert(IBondingCurve.InsufficientTokenOut.selector);
        bondingCurve.getAmountIn(token, availableTokens + 100 ether, true);

        uint256 exactAmountIn = bondingCurve.getAmountIn(token, availableTokens, true);
        assertGt(exactAmountIn, 0, "Exact available request should return valid amount");

        uint256 smallAmountIn = bondingCurve.getAmountIn(token, 1000 ether, true);
        assertGt(smallAmountIn, 0, "Small request should return valid amount");
    }

    function _buyHalfAvailable(address buyer) internal {
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        uint256 halfAvailableTokens = (curve.virtualTokenReserve - curve.minTokenReserve) / 2;
        uint256 quoteIn = bondingCurve.getAmountIn(token, halfAvailableTokens, true);
        _mintAndTransfer(buyer, quoteIn);
        vm.prank(buyer);
        bondingCurve.buy(buyer, token);
    }

    function _capParams() internal view returns (IBondingCurve.CreateTokenParams memory params) {
        params = _capParamsWithSalt(keccak256("buyCap"));
    }

    function _capParamsWithSalt(bytes32 salt) internal view returns (IBondingCurve.CreateTokenParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});

        params = IBondingCurve.CreateTokenParams({
            name: "CapToken",
            symbol: "CAP",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: salt,
            dexType: ITokenRegistry.DexType.UniswapV3,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }
}
