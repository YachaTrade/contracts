// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for GiwaRouterCreate.

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract GiwaRouterCreateTest is SetUp {
    MockERC20 lvmon;
    address vault;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");

        wmon = new MockWMON();
        lvmon = new MockERC20("Liquid Staked MON", "LVMON", 18);

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
        protocolManager.setV3QuoteConfig(address(wmon), DEFAULT_V3_FEE_TIER, DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS);
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
        protocolManager.setV3QuoteConfig(address(lvmon), DEFAULT_V3_FEE_TIER, DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS);

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

        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(giwaRouter));
        vm.stopPrank();

        vm.deal(address(wmon), 1000 ether);
    }

    function test_create_withInitialBuy() public {
        IGiwaRouter.CreateParams memory params = _createParams(1 ether);

        uint256 totalQuote = protocolManager.deployFee(address(wmon)) + 1 ether;
        wmon.mint(user1, totalQuote);
        vm.prank(user1);
        wmon.approve(address(giwaRouter), totalQuote);

        vm.prank(user1);
        (address token, uint256 tokenOut) = giwaRouter.create(params);

        assertTrue(token != address(0), "Token should be created");
        assertGt(tokenOut, 0, "Should receive tokens");
        assertEq(IERC20(token).balanceOf(user1), tokenOut, "Balance should match");
    }

    function test_createWithNative() public {
        IGiwaRouter.CreateParams memory params = _createParams(1 ether);
        params.salt = keccak256("nativeCreate");

        uint256 deployFee = protocolManager.deployFee(address(wmon));
        uint256 totalRequired = deployFee + 1 ether;
        vm.deal(user1, totalRequired);

        vm.prank(user1);
        (address token, uint256 tokenOut) = giwaRouter.createWithNative{value: totalRequired}(params);

        assertTrue(token != address(0), "Token should be created");
        assertGt(tokenOut, 0, "Should receive tokens");
    }

    function test_create_lvmonQuote_withErc20_succeeds() public {
        IGiwaRouter.CreateParams memory params = _createParams(1 ether);
        params.quoteToken = address(lvmon);
        params.salt = keccak256("erc20CreateLvmon");

        uint256 deployFee = protocolManager.deployFee(address(lvmon));
        uint256 quoteRequired = deployFee + 1 ether;
        lvmon.mint(user1, quoteRequired);

        vm.startPrank(user1);
        lvmon.approve(address(giwaRouter), quoteRequired);
        (address token, uint256 tokenOut) = giwaRouter.create(params);
        vm.stopPrank();

        assertTrue(token != address(0), "Token should be created");
        assertGt(tokenOut, 0, "Should receive tokens");
        assertEq(bondingCurve.getCurve(token).quoteToken, address(lvmon), "Curve quote should be LVMON");
        assertEq(tokenRegistry.getQuoteToken(token), address(lvmon), "Registry quote should be LVMON");
        assertEq(lvmon.balanceOf(address(giwaRouter)), 0, "Router should hold no LVMON");
    }

    function test_createWithNative_lvmonQuote_reverts() public {
        IGiwaRouter.CreateParams memory params = _createParams(1 ether);
        params.quoteToken = address(lvmon);
        params.salt = keccak256("nativeCreateLvmon");

        uint256 quoteRequired = protocolManager.deployFee(address(lvmon)) + 1 ether;
        vm.deal(user1, quoteRequired);

        vm.prank(user1);
        vm.expectRevert(IGiwaRouter.InvalidNativeQuoteToken.selector);
        giwaRouter.createWithNative{value: quoteRequired}(params);
    }

    function test_create_creatorIsUser_notRouter() public {
        IGiwaRouter.CreateParams memory params = _createParams(1 ether);
        params.salt = keccak256("creatorCheck");

        uint256 totalQuote = protocolManager.deployFee(address(wmon)) + 1 ether;
        wmon.mint(user1, totalQuote);
        vm.prank(user1);
        wmon.approve(address(giwaRouter), totalQuote);

        vm.prank(user1);
        (address token,) = giwaRouter.create(params);

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        assertEq(curve.creator, user1, "Creator should be user1, not giwaRouter");
    }

    function test_create_only() public {
        IGiwaRouter.CreateParams memory params = _createParams(0);
        params.salt = keccak256("createOnly");

        uint256 deployFee = protocolManager.deployFee(address(wmon));
        wmon.mint(user1, deployFee);
        vm.prank(user1);
        wmon.approve(address(giwaRouter), deployFee);

        vm.prank(user1);
        (address token, uint256 tokenOut) = giwaRouter.create(params);

        assertTrue(token != address(0), "Token should be created");
        assertEq(tokenOut, 0, "Should receive no tokens");
    }

    function test_create_prefundedQuoteGoesToFeeReceiver() public {
        uint256 buyQuoteAmount = 1 ether;
        uint256 donation = 3 ether;

        IGiwaRouter.CreateParams memory prefundedParams = _createParams(buyQuoteAmount);
        prefundedParams.salt = keccak256("prefunded-create");

        wmon.mint(user2, donation);
        vm.prank(user2);
        wmon.transfer(address(bondingCurve), donation);

        uint256 feeReceiverBeforePrefunded = wmon.balanceOf(feeReceiver);
        (, uint256 prefundedTokenOut) = _createViaRouter(user1, prefundedParams);
        uint256 feeReceiverDeltaPrefunded = wmon.balanceOf(feeReceiver) - feeReceiverBeforePrefunded;

        IGiwaRouter.CreateParams memory cleanParams = _createParams(buyQuoteAmount);
        cleanParams.salt = keccak256("clean-create");

        uint256 feeReceiverBeforeClean = wmon.balanceOf(feeReceiver);
        (, uint256 cleanTokenOut) = _createViaRouter(user1, cleanParams);
        uint256 feeReceiverDeltaClean = wmon.balanceOf(feeReceiver) - feeReceiverBeforeClean;

        assertEq(prefundedTokenOut, cleanTokenOut, "Prefunded quote must not increase creator initial buy");
        assertEq(
            feeReceiverDeltaPrefunded,
            feeReceiverDeltaClean + donation,
            "Prefunded quote should be swept to feeReceiver"
        );
    }

    function _createViaRouter(address caller, IGiwaRouter.CreateParams memory params)
        internal
        returns (address token, uint256 tokenOut)
    {
        uint256 totalQuote = protocolManager.deployFee(address(wmon)) + params.buyQuoteAmount;
        wmon.mint(caller, totalQuote);
        vm.prank(caller);
        wmon.approve(address(giwaRouter), totalQuote);

        vm.prank(caller);
        (token, tokenOut) = giwaRouter.create(params);
    }

    function _createParams(uint256 buyQuoteAmount) internal view returns (IGiwaRouter.CreateParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});

        params = IGiwaRouter.CreateParams({
            name: "NadFunCreate",
            symbol: "NFC",
            tokenURI: "",
            quoteToken: address(wmon),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: keccak256("giwaRouterCreate"),
            dexType: ITokenRegistry.DexType.UniswapV3,
            buyQuoteAmount: buyQuoteAmount,
            deadline: block.timestamp + 1
        });
    }
}
