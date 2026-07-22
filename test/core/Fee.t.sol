// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for Fee.

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract FeeTest is SetUp {
    address vault;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");

        // Reset quoteToken with 500M target for graduation test
        vm.startPrank(admin);
        protocolManager.removeQuoteToken(address(quoteToken));
        protocolManager.addQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 0, 0
        );
        protocolManager.setV3QuoteConfig(address(quoteToken), DEFAULT_V3_FEE_TIER, DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS);
        // Grant ROUTER_ROLE to test contract and user1 for direct bondingCurve.create() calls
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), user1);
        vm.stopPrank();
    }

    function test_setFees() public {
        vm.startPrank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            0.01 ether,
            defaultGraduateFee,
            100,
            70
        );
        vm.stopPrank();

        assertEq(protocolManager.deployFee(address(quoteToken)), 0.01 ether);
        assertEq(protocolManager.graduateFee(address(quoteToken)), defaultGraduateFee);
        assertEq(protocolManager.curveProtocolFeeRate(address(quoteToken)), 100);
        assertEq(protocolManager.dexProtocolFeeRate(address(quoteToken)), 70);
    }

    function test_setCurveProtocolFee_revertsExcessive() public {
        vm.prank(admin);
        vm.expectRevert("Protocol fee too high");
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, 0, 1001, 0
        ); // > 10%
    }

    function test_setDexProtocolFee_revertsExcessive() public {
        vm.prank(admin);
        vm.expectRevert("Dex protocol fee too high");
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, 0, 0, 1001
        ); // > 10%
    }

    function test_setProtocolFee_revertsNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, 0, 100, 0
        );
    }

    function test_buy_chargesOnlyProtocolFeeToCurrentFeeReceiver_andViewMatchesExecution() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0
        ); // curveProtocolFee 1%

        address token = _createTokenWithVault(keccak256("fee-buy"));
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        address currentFeeReceiver = makeAddr("currentFeeReceiver");
        vm.prank(admin);
        protocolManager.setFeeReceiver(currentFeeReceiver);

        uint256 buyAmount = 10_000 ether;
        uint256 quotedTokenOut = bondingCurve.getAmountOut(token, buyAmount, true);
        _mintAndApproveCurve(user1, buyAmount);

        uint256 feeReceiverBefore = quoteToken.balanceOf(currentFeeReceiver);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token, buyAmount);

        uint256 feeReceiverGot = quoteToken.balanceOf(currentFeeReceiver) - feeReceiverBefore;
        uint256 expectedProtocolFee = FixedPointMathLib.mulDivUp(buyAmount, 100, 10000);
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);

        assertEq(tokenOut, quotedTokenOut, "buy execution must match the view");
        assertEq(feeReceiverGot, expectedProtocolFee, "current feeReceiver gets the full charged fee");
        assertEq(
            curve.virtualQuoteReserve - curve.initialQuoteReserve,
            buyAmount - expectedProtocolFee,
            "only the protocol fee is deducted"
        );
    }

    function test_sell_chargesOnlyProtocolFeeToCurrentFeeReceiver_andViewMatchesExecution() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0
        ); // curveProtocolFee 1%

        address token = _createTokenWithVault(keccak256("fee-sell"));
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        // Buy first
        _mintAndApproveCurve(user1, 10_000 ether);
        vm.prank(user1);
        uint256 tokensOut = bondingCurve.buy(user1, token, 10_000 ether);

        vm.prank(user1);
        IERC20(token).approve(address(bondingCurve), tokensOut);

        address currentFeeReceiver = makeAddr("currentSellFeeReceiver");
        vm.prank(admin);
        protocolManager.setFeeReceiver(currentFeeReceiver);

        uint256 quotedQuoteOut = bondingCurve.getAmountOut(token, tokensOut, false);
        IBondingCurve.Curve memory curveBefore = bondingCurve.getCurve(token);
        uint256 feeReceiverBefore = quoteToken.balanceOf(currentFeeReceiver);
        uint256 userBefore = quoteToken.balanceOf(user1);

        vm.prank(user1);
        uint256 quoteOut = bondingCurve.sell(user1, token, tokensOut);

        uint256 feeReceiverGot = quoteToken.balanceOf(currentFeeReceiver) - feeReceiverBefore;
        uint256 userReceived = quoteToken.balanceOf(user1) - userBefore;
        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);

        uint256 grossQuoteOut = curveBefore.virtualQuoteReserve - curveAfter.virtualQuoteReserve;
        uint256 expectedProtocolFee = FixedPointMathLib.mulDivUp(grossQuoteOut, 100, 10000);

        assertEq(quoteOut, quotedQuoteOut, "sell execution must match the view");
        assertEq(quoteOut, grossQuoteOut - expectedProtocolFee, "only the protocol fee is deducted");
        assertEq(feeReceiverGot, expectedProtocolFee, "current feeReceiver gets the full charged fee");
        assertEq(userReceived, quoteOut, "User should receive quoteOut");
    }

    function test_bondingCurveUsesCurrentCurveProtocolFeeAfterQuoteUpdate() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0
        ); // curveProtocolFee 1%

        address token = _createTokenWithVault(keccak256("snapshot-curve-fee"));
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        uint256 quoteIn = 10_000 ether;

        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 300, 0
        ); // live curveProtocolFee changes to 3%

        assertEq(
            protocolManager.curveProtocolFeeRate(address(quoteToken)), 300, "ProtocolManager live fee should update"
        );
        uint256 quotedTokenOut = bondingCurve.getAmountOut(token, quoteIn, true);

        _mintAndApproveCurve(user1, quoteIn);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token, quoteIn);

        uint256 feeReceiverGot = quoteToken.balanceOf(feeReceiver) - feeReceiverBefore;
        uint256 expectedProtocolFee = FixedPointMathLib.mulDivUp(quoteIn, 300, 10000);

        assertEq(tokenOut, quotedTokenOut, "view and execution should use the same live fee");
        assertEq(feeReceiverGot, expectedProtocolFee, "Protocol fee should use the current configured rate");
    }

    function test_create_initialBuy_chargesOnlyProtocolFeeToCurrentFeeReceiver() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0
        );

        uint256 buyQuoteAmount = 10_000 ether;
        IBondingCurve.CreateTokenParams memory params = _feeDefaultParams(keccak256("initial-buy-fee"));
        params.creator = user1;
        params.buyQuoteAmount = buyQuoteAmount;
        _mintAndApproveCurve(user1, buyQuoteAmount);

        address currentFeeReceiver = makeAddr("initialBuyFeeReceiver");
        vm.prank(admin);
        protocolManager.setFeeReceiver(currentFeeReceiver);

        vm.prank(user1);
        (address token, uint256 tokenOut) = bondingCurve.create(params);

        uint256 expectedProtocolFee = FixedPointMathLib.mulDivUp(buyQuoteAmount, 100, 10000);
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);

        assertGt(tokenOut, 0, "initial buy should receive launch tokens");
        assertEq(
            quoteToken.balanceOf(currentFeeReceiver), expectedProtocolFee, "current fee receiver gets protocol fee"
        );
        assertEq(
            curve.virtualQuoteReserve - curve.initialQuoteReserve,
            buyQuoteAmount - expectedProtocolFee,
            "initial buy deducts only protocol fee"
        );
    }

    function test_create_deployFee() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            0.01 ether,
            defaultGraduateFee,
            0,
            0
        );

        // User must transfer deploy fee to BC (balance detection)
        quoteToken.mint(user1, 0.01 ether);
        vm.prank(user1);
        quoteToken.approve(address(bondingCurve), 0.01 ether);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);

        vm.prank(user1);
        (address token,) = bondingCurve.create(_feeDefaultParams(keccak256("deploy-fee")));

        assertNotEq(token, address(0));
        uint256 feeCollected = quoteToken.balanceOf(feeReceiver) - feeReceiverBefore;
        assertEq(feeCollected, 0.01 ether, "Deploy fee should be collected");
    }

    function test_create_noDeployFee_whenZero() public {
        // deploy fee defaults to zero in this fee-focused setup
        vm.prank(user1);
        (address token,) = bondingCurve.create(_feeDefaultParams(keccak256("no-fee")));
        assertNotEq(token, address(0));
    }

    function test_graduate_fee() public {
        uint256 gradFee = defaultGraduateFee + 1 ether;
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, gradFee, 0, 0
        );

        address token = _createTokenWithVault(keccak256("grad-fee"));
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);

        // Buy enough to graduate (excess goes to feeReceiver along with grad fee)
        _mintAndApproveCurve(user1, 700_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token, 700_000 ether);

        assertTrue(bondingCurve.getCurve(token).graduated, "Should be graduated");

        uint256 feeCollected = quoteToken.balanceOf(feeReceiver) - feeReceiverBefore;
        // feeReceiver gets: protocolFee (0%) + excessQuote (from clamping) + graduateFee
        // At minimum, feeReceiver should have received the graduate fee
        assertGe(feeCollected, gradFee, "Graduate fee should be included in total fees collected");
    }

    function test_quoteSpecific_deployFee_isolation() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.startPrank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1_000_000_000 ether, 800_000_000 ether, 10e6, 0, 0, 0);
        protocolManager.updateQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            0.01 ether,
            defaultGraduateFee,
            0,
            0
        );
        vm.stopPrank();

        assertEq(
            protocolManager.deployFee(address(quoteToken)), 0.01 ether, "quoteToken deployFee should be 0.01 ether"
        );
        assertEq(protocolManager.deployFee(address(usdc)), 10e6, "USDC deployFee should be 10 USDC");

        quoteToken.mint(user1, 0.01 ether);
        vm.prank(user1);
        quoteToken.approve(address(bondingCurve), 0.01 ether);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);
        vm.prank(user1);
        (address token1,) = bondingCurve.create(_feeDefaultParams(keccak256("quote-specific-1")));

        assertNotEq(token1, address(0));
        assertEq(
            quoteToken.balanceOf(feeReceiver) - feeReceiverBefore,
            0.01 ether,
            "Should collect 0.01 ether from quoteToken create"
        );
    }

    function test_quoteSpecific_feesSetViaAddQuoteToken() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1_000_000_000 ether, 800_000_000 ether, 5e6, 50e6, 0, 0);

        assertEq(protocolManager.deployFee(address(usdc)), 5e6, "USDC deployFee from addQuoteToken");
        assertEq(protocolManager.graduateFee(address(usdc)), 50e6, "USDC graduateFee from addQuoteToken");
        assertEq(protocolManager.deployFee(address(quoteToken)), 0, "quoteToken deployFee unchanged");
        assertEq(
            protocolManager.graduateFee(address(quoteToken)), defaultGraduateFee, "quoteToken graduateFee unchanged"
        );
    }

    function _createTokenWithVault(bytes32 salt) internal returns (address token) {
        (token,) = bondingCurve.create(_feeDefaultParams(salt));
    }

    function _mintAndApproveCurve(address account, uint256 amount) internal {
        quoteToken.mint(account, amount);
        vm.prank(account);
        quoteToken.approve(address(bondingCurve), amount);
    }

    function _feeDefaultParams(bytes32 salt) internal view returns (IBondingCurve.CreateTokenParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});

        params = IBondingCurve.CreateTokenParams({
            name: "FeeTest",
            symbol: "FT",
            tokenURI: "",
            quoteToken: address(quoteToken),
            vaults: vaults,
            salt: salt,
            dexType: ITokenRegistry.DexType.UniswapV3,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }
}
