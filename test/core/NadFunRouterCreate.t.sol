// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for NadFunRouterCreate.

import {console} from "forge-std/Test.sol";
import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {NadFunRouter} from "../../src/router/NadFunRouter.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {MockLvMonMinter} from "../mocks/MockLvMonMinter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract NadFunRouterCreateTest is SetUp {
    NadFunRouter router;
    MockERC20 lvmon;
    MockLvMonMinter lvmonMinter;
    address vault;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");

        wmon = new MockWMON();
        lvmon = new MockERC20("Liquid Staked MON", "LVMON", 18);
        lvmonMinter = new MockLvMonMinter(admin, address(0), address(wmon), address(lvmon));

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

        // Deploy NadFunRouter (UUPS proxy)
        NadFunRouter routerImpl = new NadFunRouter();
        router = NadFunRouter(
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
                                address(lvmonMinter)
                            )
                        )
                    )
                ))
        );

        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(router));
        vm.stopPrank();

        vm.deal(address(wmon), 1000 ether);
    }

    function test_create_withInitialBuy() public {
        INadFunRouter.CreateParams memory params = _createParams(1 ether);

        uint256 totalQuote = protocolManager.deployFee(address(wmon)) + 1 ether;
        wmon.mint(user1, totalQuote);
        vm.prank(user1);
        wmon.approve(address(router), totalQuote);

        vm.prank(user1);
        (address token, uint256 tokenOut) = router.create(params);

        assertTrue(token != address(0), "Token should be created");
        assertGt(tokenOut, 0, "Should receive tokens");
        assertEq(IERC20(token).balanceOf(user1), tokenOut, "Balance should match");
    }

    function test_createWithNative() public {
        INadFunRouter.CreateParams memory params = _createParams(1 ether);
        params.salt = keccak256("nativeCreate");

        uint256 deployFee = protocolManager.deployFee(address(wmon));
        uint256 totalRequired = deployFee + 1 ether;
        vm.deal(user1, totalRequired);

        vm.prank(user1);
        (address token, uint256 tokenOut) = router.createWithNative{value: totalRequired}(params);

        assertTrue(token != address(0), "Token should be created");
        assertGt(tokenOut, 0, "Should receive tokens");
    }

    function test_createWithNative_lvmonQuote_mintsLvmon() public {
        INadFunRouter.CreateParams memory params = _createParams(1 ether);
        params.quoteToken = address(lvmon);
        params.salt = keccak256("nativeCreateLvmon");

        uint256 deployFee = protocolManager.deployFee(address(lvmon));
        uint256 quoteRequired = deployFee + 1 ether;
        vm.deal(user1, quoteRequired);

        vm.prank(user1);
        (address token, uint256 tokenOut) = router.createWithNative{value: quoteRequired}(params);

        assertTrue(token != address(0), "Token should be created");
        assertGt(tokenOut, 0, "Should receive tokens");
        assertEq(bondingCurve.getCurve(token).quoteToken, address(lvmon), "Curve quote should be LVMON");
        assertEq(tokenRegistry.getQuoteToken(token), address(lvmon), "Registry quote should be LVMON");
        assertEq(lvmon.balanceOf(address(router)), 0, "Router should hold no LVMON");
        assertEq(address(lvmonMinter).balance, quoteRequired, "LVMON minter should receive native");
    }

    function test_create_creatorIsUser_notRouter() public {
        INadFunRouter.CreateParams memory params = _createParams(1 ether);
        params.salt = keccak256("creatorCheck");

        uint256 totalQuote = protocolManager.deployFee(address(wmon)) + 1 ether;
        wmon.mint(user1, totalQuote);
        vm.prank(user1);
        wmon.approve(address(router), totalQuote);

        vm.prank(user1);
        (address token,) = router.create(params);

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        assertEq(curve.creator, user1, "Creator should be user1, not router");
    }

    function test_create_only() public {
        INadFunRouter.CreateParams memory params = _createParams(0);
        params.salt = keccak256("createOnly");

        uint256 deployFee = protocolManager.deployFee(address(wmon));
        wmon.mint(user1, deployFee);
        vm.prank(user1);
        wmon.approve(address(router), deployFee);

        vm.prank(user1);
        (address token, uint256 tokenOut) = router.create(params);

        assertTrue(token != address(0), "Token should be created");
        assertEq(tokenOut, 0, "Should receive no tokens");
    }

    function test_create_prefundedQuoteGoesToFeeReceiver() public {
        uint256 buyQuoteAmount = 1 ether;
        uint256 donation = 3 ether;

        INadFunRouter.CreateParams memory prefundedParams = _createParams(buyQuoteAmount);
        prefundedParams.salt = keccak256("prefunded-create");

        wmon.mint(user2, donation);
        vm.prank(user2);
        wmon.transfer(address(bondingCurve), donation);

        uint256 feeReceiverBeforePrefunded = wmon.balanceOf(feeReceiver);
        (, uint256 prefundedTokenOut) = _createViaRouter(user1, prefundedParams);
        uint256 feeReceiverDeltaPrefunded = wmon.balanceOf(feeReceiver) - feeReceiverBeforePrefunded;

        INadFunRouter.CreateParams memory cleanParams = _createParams(buyQuoteAmount);
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

    function _createViaRouter(address caller, INadFunRouter.CreateParams memory params)
        internal
        returns (address token, uint256 tokenOut)
    {
        uint256 totalQuote = protocolManager.deployFee(address(wmon)) + params.buyQuoteAmount;
        wmon.mint(caller, totalQuote);
        vm.prank(caller);
        wmon.approve(address(router), totalQuote);

        vm.prank(caller);
        (token, tokenOut) = router.create(params);
    }

    function _createParams(uint256 buyQuoteAmount) internal view returns (INadFunRouter.CreateParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});

        params = INadFunRouter.CreateParams({
            name: "NadFunCreate",
            symbol: "NFC",
            tokenURI: "",
            quoteToken: address(wmon),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: keccak256("nadFunRouterCreate"),
            dexType: ITokenRegistry.DexType.UniswapV2,
            buyQuoteAmount: buyQuoteAmount,
            deadline: block.timestamp + 1
        });
    }
}
