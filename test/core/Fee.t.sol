// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for Fee.

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
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
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 0, 0, 0
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
            70,
            0
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
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, 0, 1001, 0, 0
        ); // > 10%
    }

    function test_setDexProtocolFee_revertsExcessive() public {
        vm.prank(admin);
        vm.expectRevert("Dex protocol fee too high");
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, 0, 0, 1001, 0
        ); // > 10%
    }

    function test_setProtocolFee_revertsNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, 0, 100, 0, 0
        );
    }

    // BondingCurve forwards (protocolFee + creatorFee) to FeeCollector, which performs the single
    // split. feeReceiver receives exactly the protocol portion; creator portion accumulates in FC.
    function test_buy_protocolFee() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0, 0
        ); // curveProtocolFee 1%

        address token = _createTokenWithVault(keccak256("fee-buy"));
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        uint256 buyAmount = 10_000 ether;
        _mintAndTransfer(user1, buyAmount);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);
        uint256 fcBefore = quoteToken.balanceOf(address(feeCollector));
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        uint256 feeReceiverGot = quoteToken.balanceOf(feeReceiver) - feeReceiverBefore;
        uint256 creatorFeeInCollector = quoteToken.balanceOf(address(feeCollector)) - fcBefore;

        // totalFeeRate = 100 + 500 = 600 BPS
        // protocolFee = mulDivUp(buyAmount, 100, 10000) = 100 ether
        // creatorFee  = mulDivUp(buyAmount, 600, 10000) - 100 = 500 ether
        uint256 expectedProtocolFee = FixedPointMathLib.mulDivUp(buyAmount, 100, 10000);
        uint256 expectedTotalFee = FixedPointMathLib.mulDivUp(buyAmount, 600, 10000);
        uint256 expectedCreatorFee = expectedTotalFee - expectedProtocolFee;

        assertEq(feeReceiverGot, expectedProtocolFee, "feeReceiver gets protocolFee only (single split)");
        assertEq(creatorFeeInCollector, expectedCreatorFee, "FeeCollector accumulates full creatorFee");
    }

    function test_sell_protocolFee() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0, 0
        ); // curveProtocolFee 1%

        address token = _createTokenWithVault(keccak256("fee-sell"));
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        // Buy first
        _mintAndTransfer(user1, 10_000 ether);
        vm.prank(user1);
        uint256 tokensOut = bondingCurve.buy(user1, token);

        vm.prank(user1);
        IERC20(token).transfer(address(bondingCurve), tokensOut);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);
        uint256 fcBefore = quoteToken.balanceOf(address(feeCollector));
        uint256 userBefore = quoteToken.balanceOf(user1);

        vm.prank(user1);
        uint256 quoteOut = bondingCurve.sell(user1, token);

        uint256 feeReceiverGot = quoteToken.balanceOf(feeReceiver) - feeReceiverBefore;
        uint256 creatorFeeInCollector = quoteToken.balanceOf(address(feeCollector)) - fcBefore;
        uint256 userReceived = quoteToken.balanceOf(user1) - userBefore;

        // grossQuote recovered from balance deltas (quoteOut + all fees)
        uint256 grossQuoteOut = quoteOut + feeReceiverGot + creatorFeeInCollector;

        uint256 expectedProtocolFee = FixedPointMathLib.mulDivUp(grossQuoteOut, 100, 10000);
        uint256 expectedTotalFee = FixedPointMathLib.mulDivUp(grossQuoteOut, 600, 10000);
        uint256 expectedCreatorFee = expectedTotalFee - expectedProtocolFee;

        assertEq(feeReceiverGot, expectedProtocolFee, "feeReceiver gets protocolFee only (single split)");
        assertEq(creatorFeeInCollector, expectedCreatorFee, "FeeCollector accumulates full creatorFee");
        assertEq(userReceived, quoteOut, "User should receive quoteOut");
    }

    function test_bondingCurveUsesSnapshotCurveProtocolFeeAfterQuoteUpdate() public {
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 100, 0, 0
        ); // curveProtocolFee 1%

        address token = _createTokenWithVault(keccak256("snapshot-curve-fee"));
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        IFeeCollector.FeeConfig memory config = feeCollector.getFeeConfig(curve.pair);
        assertEq(config.curveProtocolFeeRate, 100, "FeeCollector should snapshot creation-time curve fee");
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        uint256 quoteIn = 10_000 ether;
        uint256 tokenOut = bondingCurve.getAmountOut(token, quoteIn, true);
        uint256 quoteInBeforeUpdate = bondingCurve.getAmountIn(token, tokenOut, true);

        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 300, 0, 0
        ); // live curveProtocolFee changes to 3%

        assertEq(
            protocolManager.curveProtocolFeeRate(address(quoteToken)), 300, "ProtocolManager live fee should update"
        );
        assertEq(
            bondingCurve.getAmountIn(token, tokenOut, true),
            quoteInBeforeUpdate,
            "Existing pair quotes should continue using the cached curve fee"
        );

        _mintAndTransfer(user1, quoteIn);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);
        uint256 fcBefore = quoteToken.balanceOf(address(feeCollector));
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        uint256 feeReceiverGot = quoteToken.balanceOf(feeReceiver) - feeReceiverBefore;
        uint256 creatorFeeInCollector = quoteToken.balanceOf(address(feeCollector)) - fcBefore;

        uint256 expectedProtocolFee = FixedPointMathLib.mulDivUp(quoteIn, 100, 10000);
        uint256 expectedTotalFee = FixedPointMathLib.mulDivUp(quoteIn, 600, 10000);
        uint256 expectedCreatorFee = expectedTotalFee - expectedProtocolFee;

        assertEq(feeReceiverGot, expectedProtocolFee, "Protocol fee should use cached curve fee");
        assertEq(creatorFeeInCollector, expectedCreatorFee, "Creator fee should use cached curve fee split");
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
            0,
            0
        );

        // User must transfer deploy fee to BC (balance detection)
        quoteToken.mint(user1, 0.01 ether);
        vm.prank(user1);
        quoteToken.transfer(address(bondingCurve), 0.01 ether);

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
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, gradFee, 0, 0, 0
        );

        address token = _createTokenWithVault(keccak256("grad-fee"));
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);

        // Buy enough to graduate (excess goes to feeReceiver along with grad fee)
        _mintAndTransfer(user1, 700_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        assertTrue(bondingCurve.getCurve(token).graduated, "Should be graduated");

        uint256 feeCollected = quoteToken.balanceOf(feeReceiver) - feeReceiverBefore;
        // feeReceiver gets: protocolFee (0%) + excessQuote (from clamping) + graduateFee
        // At minimum, feeReceiver should have received the graduate fee
        assertGe(feeCollected, gradFee, "Graduate fee should be included in total fees collected");
    }

    function test_quoteSpecific_deployFee_isolation() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.startPrank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1_000_000_000 ether, 800_000_000 ether, 10e6, 0, 0, 0, 0);
        protocolManager.updateQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            0.01 ether,
            defaultGraduateFee,
            0,
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
        quoteToken.transfer(address(bondingCurve), 0.01 ether);

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
        protocolManager.addQuoteToken(
            address(usdc), 15_000e6, 1_000_000_000 ether, 800_000_000 ether, 5e6, 50e6, 0, 0, 0
        );

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

    function _feeDefaultParams(bytes32 salt) internal view returns (IBondingCurve.CreateTokenParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});

        params = IBondingCurve.CreateTokenParams({
            name: "FeeTest",
            symbol: "FT",
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
