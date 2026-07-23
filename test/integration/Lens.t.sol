// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {ILens} from "../../src/lens/ILens.sol";
import {SetUp} from "../SetUp.t.sol";
import {Lens} from "../../src/lens/Lens.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LensInterfaceTest is Test {
    function test_interfaceSelectors_matchApprovedApi() public pure {
        assertEq(ILens.getAmountIn.selector, bytes4(keccak256("getAmountIn(address,uint256,bool)")));
        assertEq(ILens.getAmountOut.selector, bytes4(keccak256("getAmountOut(address,uint256,bool)")));
        assertEq(ILens.isGraduated.selector, bytes4(keccak256("isGraduated(address)")));
        assertEq(ILens.isLocked.selector, bytes4(keccak256("isLocked(address)")));
        assertEq(ILens.availableBuyTokens.selector, bytes4(keccak256("availableBuyTokens(address)")));
        assertEq(ILens.getProgress.selector, bytes4(keccak256("getProgress(address)")));
        assertEq(ILens.getInitialBuyAmountOut.selector, bytes4(keccak256("getInitialBuyAmountOut(address,uint256)")));
    }
}

contract LensRouterStub {
    address public bondingCurve;
    address public tokenRegistry;
    address public authority;

    constructor(address bondingCurve_, address tokenRegistry_, address authority_) {
        bondingCurve = bondingCurve_;
        tokenRegistry = tokenRegistry_;
        authority = authority_;
    }
}

contract LensDependencyStub {}

contract LensCurveStub {
    error UnexpectedAmountInCall();

    mapping(address token => IBondingCurve.Curve curve) private _curves;
    bool private _revertOnAmountIn;

    function setCurve(address token, IBondingCurve.Curve calldata curve_) external {
        _curves[token] = curve_;
    }

    function setRevertOnAmountIn(bool revertOnAmountIn) external {
        _revertOnAmountIn = revertOnAmountIn;
    }

    function getCurve(address token) external view returns (IBondingCurve.Curve memory) {
        return _curves[token];
    }

    function getAmountIn(address, uint256, bool) external view returns (uint256) {
        if (_revertOnAmountIn) revert UnexpectedAmountInCall();
        return 1;
    }
}

contract LensProtocolManagerStub {
    mapping(address quoteToken => IProtocolManager.QuoteConfig config) private _configs;

    function setConfig(address quoteToken, IProtocolManager.QuoteConfig calldata config) external {
        _configs[quoteToken] = config;
    }

    function getConfig(address quoteToken) external view returns (IProtocolManager.QuoteConfig memory) {
        return _configs[quoteToken];
    }
}

contract LensDefensiveBranchesTest is Test {
    Lens internal lens;
    LensCurveStub internal curveStub;
    LensProtocolManagerStub internal managerStub;
    address internal token = makeAddr("stubToken");
    address internal quoteToken = makeAddr("stubQuote");

    function setUp() public {
        curveStub = new LensCurveStub();
        managerStub = new LensProtocolManagerStub();
        LensDependencyStub registryStub = new LensDependencyStub();
        LensRouterStub routerStub = new LensRouterStub(address(curveStub), address(registryStub), address(managerStub));
        lens = new Lens(address(routerStub));
    }

    function test_availableBuyTokens_revertsWhenVirtualTokenReserveIsBelowMinimum() public {
        curveStub.setCurve(token, _curve(100, 39, 40));

        vm.expectRevert(ILens.InvalidCurveConfig.selector);
        lens.availableBuyTokens(token);
    }

    function test_availableBuyTokens_zeroAvailabilityDoesNotCallCurveAmountIn() public {
        curveStub.setCurve(token, _curve(100, 40, 40));
        curveStub.setRevertOnAmountIn(true);

        (uint256 availableBuyToken, uint256 requiredQuoteAmount) = lens.availableBuyTokens(token);

        assertEq(availableBuyToken, 0);
        assertEq(requiredQuoteAmount, 0);
    }

    function test_getProgress_revertsWhenInitialTokenReserveEqualsMinimum() public {
        curveStub.setCurve(token, _curve(40, 40, 40));

        vm.expectRevert(ILens.InvalidCurveConfig.selector);
        lens.getProgress(token);
    }

    function test_getProgress_revertsWhenInitialTokenReserveIsBelowMinimum() public {
        curveStub.setCurve(token, _curve(39, 39, 40));

        vm.expectRevert(ILens.InvalidCurveConfig.selector);
        lens.getProgress(token);
    }

    function test_getProgress_revertsWhenVirtualTokenReserveExceedsInitial() public {
        curveStub.setCurve(token, _curve(100, 101, 40));

        vm.expectRevert(ILens.InvalidCurveConfig.selector);
        lens.getProgress(token);
    }

    function test_getProgress_revertsWhenVirtualTokenReserveIsBelowMinimum() public {
        curveStub.setCurve(token, _curve(100, 39, 40));

        vm.expectRevert(ILens.InvalidCurveConfig.selector);
        lens.getProgress(token);
    }

    function test_initialBuy_revertsWhenVirtualReserveIsZero() public {
        managerStub.setConfig(quoteToken, _config(0, 100, 40));

        vm.expectRevert(ILens.InvalidCurveConfig.selector);
        lens.getInitialBuyAmountOut(quoteToken, 1);
    }

    function test_initialBuy_revertsWhenVirtualTokenReserveEqualsMinimum() public {
        managerStub.setConfig(quoteToken, _config(100, 40, 40));

        vm.expectRevert(ILens.InvalidCurveConfig.selector);
        lens.getInitialBuyAmountOut(quoteToken, 1);
    }

    function test_initialBuy_revertsWhenVirtualTokenReserveIsBelowMinimum() public {
        managerStub.setConfig(quoteToken, _config(100, 39, 40));

        vm.expectRevert(ILens.InvalidCurveConfig.selector);
        lens.getInitialBuyAmountOut(quoteToken, 1);
    }

    function test_initialBuy_revertsWhenReserveProductWouldOverflow() public {
        managerStub.setConfig(quoteToken, _config(type(uint256).max, 2, 1));

        vm.expectRevert(ILens.InvalidCurveConfig.selector);
        lens.getInitialBuyAmountOut(quoteToken, 1);
    }

    function _curve(uint256 initialTokenReserve, uint256 virtualTokenReserve, uint256 minTokenReserve)
        private
        view
        returns (IBondingCurve.Curve memory curve_)
    {
        curve_.token = token;
        curve_.virtualTokenReserve = virtualTokenReserve;
        curve_.minTokenReserve = minTokenReserve;
        curve_.initialTokenReserve = initialTokenReserve;
    }

    function _config(uint256 virtualReserve, uint256 virtualTokenReserve, uint256 minTokenReserve)
        private
        pure
        returns (IProtocolManager.QuoteConfig memory config)
    {
        config.virtualReserve = virtualReserve;
        config.virtualTokenReserve = virtualTokenReserve;
        config.minTokenReserve = minTokenReserve;
        config.active = true;
    }
}

contract LensIntegrationTest is SetUp {
    Lens internal lens;
    address internal token;

    function setUp() public override {
        super.setUp();
        lens = new Lens(address(giwaRouter));
        token = _createToken();
    }

    function test_constructor_revertsForZeroOrNonContractRouter() public {
        vm.expectRevert(ILens.InvalidDependency.selector);
        new Lens(address(0));

        vm.expectRevert(ILens.InvalidDependency.selector);
        new Lens(makeAddr("nonContractRouter"));
    }

    function test_constructor_revertsForInvalidDiscoveredDependency() public {
        LensRouterStub missingCurve = new LensRouterStub(address(0), address(tokenRegistry), address(protocolManager));
        vm.expectRevert(ILens.InvalidDependency.selector);
        new Lens(address(missingCurve));

        LensRouterStub missingRegistry = new LensRouterStub(address(bondingCurve), address(0), address(protocolManager));
        vm.expectRevert(ILens.InvalidDependency.selector);
        new Lens(address(missingRegistry));

        LensRouterStub missingManager = new LensRouterStub(address(bondingCurve), address(tokenRegistry), address(0));
        vm.expectRevert(ILens.InvalidDependency.selector);
        new Lens(address(missingManager));
    }

    function test_compatibilityGetters_resolveUnifiedRouterDependencies() public view {
        assertEq(address(lens.giwaRouter()), address(giwaRouter));
        assertEq(lens.curve(), address(bondingCurve));
        assertEq(lens.curveRouter(), address(giwaRouter));
        assertEq(lens.dexRouter(), address(giwaRouter));
        assertEq(lens.tokenRegistry(), address(tokenRegistry));
    }

    function test_lifecycleState_mapsAtomicGraduationToLock() public {
        assertFalse(lens.isGraduated(token));
        assertFalse(lens.isLocked(token));

        _skipAntiSniping();
        _graduateToken(token);

        assertTrue(lens.isGraduated(token));
        assertTrue(lens.isLocked(token));
    }

    function test_lifecycleState_revertsForUnknownToken() public {
        address unknown = makeAddr("unknownToken");
        vm.expectRevert(ILens.TokenNotFound.selector);
        lens.isGraduated(unknown);
        vm.expectRevert(ILens.TokenNotFound.selector);
        lens.isLocked(unknown);
    }

    function test_preGraduationQuotes_returnUnifiedRouterAndMatchRouter() public {
        {
            (address router, uint256 amountOut) = lens.getAmountOut(token, 100 ether, true);
            assertEq(router, address(giwaRouter));
            assertEq(amountOut, giwaRouter.getAmountOut(token, 100 ether, true));
        }
        {
            (address router, uint256 amountOut) = lens.getAmountOut(token, 1_000 ether, false);
            assertEq(router, address(giwaRouter));
            assertEq(amountOut, giwaRouter.getAmountOut(token, 1_000 ether, false));
        }
        {
            (address router, uint256 amountIn) = lens.getAmountIn(token, 1_000 ether, true);
            assertEq(router, address(giwaRouter));
            assertEq(amountIn, giwaRouter.getAmountIn(token, 1_000 ether, true));
        }
        {
            (address router, uint256 amountIn) = lens.getAmountIn(token, 10 ether, false);
            assertEq(router, address(giwaRouter));
            assertEq(amountIn, giwaRouter.getAmountIn(token, 10 ether, false));
        }
    }

    function test_graduatedQuotes_returnUnifiedRouterAndMatchV3Router() public {
        _skipAntiSniping();
        _graduateToken(token);

        {
            uint256 quoteIn = 10 ether;
            (address router, uint256 tokenOut) = lens.getAmountOut(token, quoteIn, true);
            assertEq(router, address(giwaRouter));
            assertEq(tokenOut, giwaRouter.getAmountOut(token, quoteIn, true));
        }
        {
            uint256 tokenIn = 1_000 ether;
            (address router, uint256 quoteOut) = lens.getAmountOut(token, tokenIn, false);
            assertEq(router, address(giwaRouter));
            assertEq(quoteOut, giwaRouter.getAmountOut(token, tokenIn, false));
        }
        {
            uint256 tokenOut = 1_000 ether;
            (address router, uint256 quoteIn) = lens.getAmountIn(token, tokenOut, true);
            assertEq(router, address(giwaRouter));
            assertEq(quoteIn, giwaRouter.getAmountIn(token, tokenOut, true));
        }
        {
            uint256 quoteOut = 1 ether;
            (address router, uint256 tokenIn) = lens.getAmountIn(token, quoteOut, false);
            assertEq(router, address(giwaRouter));
            assertEq(tokenIn, giwaRouter.getAmountIn(token, quoteOut, false));
        }
    }

    function test_graduatedSummaries_areTerminal() public {
        _skipAntiSniping();
        _graduateToken(token);

        assertTrue(lens.isGraduated(token));
        assertTrue(lens.isLocked(token));
        assertEq(lens.getProgress(token), 10_000);
        (uint256 available, uint256 requiredQuote) = lens.availableBuyTokens(token);
        assertEq(available, 0);
        assertEq(requiredQuote, 0);
    }

    function test_availableBuyTokens_matchesCurveFeeAwareQuote() public view {
        IBondingCurve.Curve memory curve_ = bondingCurve.getCurve(token);
        uint256 available = curve_.virtualTokenReserve - curve_.minTokenReserve;

        (uint256 lensAvailable, uint256 requiredQuote) = lens.availableBuyTokens(token);

        assertEq(lensAvailable, available);
        assertEq(requiredQuote, bondingCurve.getAmountIn(token, available, true));
    }

    function test_progress_tracksCurveReserves() public {
        assertEq(lens.getProgress(token), 0);

        _buyOnCurve(user1, token, 10_000 ether);
        IBondingCurve.Curve memory curve_ = bondingCurve.getCurve(token);
        uint256 expected = (curve_.initialTokenReserve - curve_.virtualTokenReserve) * 10_000
            / (curve_.initialTokenReserve - curve_.minTokenReserve);

        assertEq(lens.getProgress(token), expected);
    }

    function test_curveQueries_revertForUnknownToken() public {
        address unknown = makeAddr("unknownCurveToken");
        vm.expectRevert(ILens.TokenNotFound.selector);
        lens.getAmountOut(unknown, 1 ether, true);
        vm.expectRevert(ILens.TokenNotFound.selector);
        lens.getAmountIn(unknown, 1 ether, true);
        vm.expectRevert(ILens.TokenNotFound.selector);
        lens.availableBuyTokens(unknown);
        vm.expectRevert(ILens.TokenNotFound.selector);
        lens.getProgress(unknown);
    }

    function test_initialBuy_returnsZeroForZeroInput() public view {
        assertEq(lens.getInitialBuyAmountOut(address(quoteToken), 0), 0);
    }

    function test_initialBuy_revertsForInactiveQuote() public {
        vm.expectRevert(ILens.QuoteTokenNotAllowed.selector);
        lens.getInitialBuyAmountOut(makeAddr("inactiveQuote"), 1 ether);
    }

    function test_initialBuy_matchesActualCreateForDefaultQuote() public {
        uint256 quoteIn = 25_000 ether;
        uint256 quoted = lens.getInitialBuyAmountOut(address(quoteToken), quoteIn);
        (, uint256 actual) = _createWithInitialBuy(quoteToken, quoteIn, keccak256("defaultQuoteInitial"));
        assertEq(quoted, actual);
    }

    function test_initialBuy_oneAtomicUnitRevertsLikeActualCreate() public {
        uint256 quoteIn = 1;

        vm.expectRevert(bytes("Invalid inputs"));
        lens.getInitialBuyAmountOut(address(quoteToken), quoteIn);

        _expectCreateWithInitialBuyRevert(quoteToken, quoteIn, keccak256("oneAtomicUnitInitial"));
    }

    function test_initialBuy_nonDivisibleFeeMatchesActualCreate() public {
        uint256 quoteIn = 101;
        uint256 quoted = lens.getInitialBuyAmountOut(address(quoteToken), quoteIn);
        (, uint256 actual) = _createWithInitialBuy(quoteToken, quoteIn, keccak256("nonDivisibleFeeInitial"));
        assertEq(quoted, actual);
    }

    function test_initialBuy_supportsDistinctSecondQuoteConfig() public {
        MockERC20 quote6 = new MockERC20("USD Quote", "USDQ", 6);
        vm.startPrank(admin);
        protocolManager.addV3QuoteToken(
            address(quote6),
            50_000e6,
            virtualTokenReserve,
            minTokenReserve,
            10e6,
            1_000e6,
            250,
            50,
            DEFAULT_V3_FEE_TIER,
            DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS
        );
        vm.stopPrank();

        uint256 quoteIn = 15_000e6;
        uint256 defaultQuoteResult = lens.getInitialBuyAmountOut(address(quoteToken), 15_000 ether);
        uint256 secondQuoteResult = lens.getInitialBuyAmountOut(address(quote6), quoteIn);
        (, uint256 actual) = _createWithInitialBuy(quote6, quoteIn, keccak256("secondQuoteInitial"));

        assertNotEq(secondQuoteResult, defaultQuoteResult);
        assertEq(secondQuoteResult, actual);
    }

    function test_initialBuy_reflectsActiveQuoteConfigUpdateWithoutLensRedeployment() public {
        uint256 quoteIn = 25_000 ether;
        address originalLens = address(lens);
        uint256 quoteBeforeUpdate = lens.getInitialBuyAmountOut(address(quoteToken), quoteIn);

        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            500,
            defaultDexProtocolFee
        );

        uint256 quoteAfterUpdate = lens.getInitialBuyAmountOut(address(quoteToken), quoteIn);
        (, uint256 actual) = _createWithInitialBuy(quoteToken, quoteIn, keccak256("updatedQuoteConfigInitial"));

        assertEq(address(lens), originalLens);
        assertNotEq(quoteAfterUpdate, quoteBeforeUpdate);
        assertEq(quoteAfterUpdate, actual);
    }

    function test_initialBuy_capsAtConfiguredAvailableTokens() public view {
        IProtocolManager.QuoteConfig memory config = protocolManager.getConfig(address(quoteToken));
        uint256 available = config.virtualTokenReserve - config.minTokenReserve;
        assertEq(lens.getInitialBuyAmountOut(address(quoteToken), type(uint128).max), available);
    }

    function _createWithInitialBuy(MockERC20 quote, uint256 quoteIn, bytes32 salt)
        private
        returns (address createdToken, uint256 tokenOut)
    {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10_000, setupData: abi.encode(feeReceiver)
        });

        uint256 requiredQuote = protocolManager.deployFee(address(quote)) + quoteIn;
        quote.mint(creator, requiredQuote);
        vm.prank(creator);
        quote.approve(address(giwaRouter), requiredQuote);
        vm.prank(creator);
        (createdToken, tokenOut) = giwaRouter.create(
            IGiwaRouter.CreateParams({
                name: "Initial Buy Token",
                symbol: "IBT",
                tokenURI: "",
                quoteToken: address(quote),
                vaults: vaults,
                salt: salt,
                dexType: ITokenRegistry.DexType.UniswapV3,
                buyQuoteAmount: quoteIn,
                deadline: block.timestamp
            })
        );
    }

    function _expectCreateWithInitialBuyRevert(MockERC20 quote, uint256 quoteIn, bytes32 salt) private {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10_000, setupData: abi.encode(feeReceiver)
        });

        uint256 requiredQuote = protocolManager.deployFee(address(quote)) + quoteIn;
        quote.mint(creator, requiredQuote);
        vm.prank(creator);
        quote.approve(address(giwaRouter), requiredQuote);
        vm.expectRevert(bytes("Invalid inputs"));
        vm.prank(creator);
        giwaRouter.create(
            IGiwaRouter.CreateParams({
                name: "Initial Buy Token",
                symbol: "IBT",
                tokenURI: "",
                quoteToken: address(quote),
                vaults: vaults,
                salt: salt,
                dexType: ITokenRegistry.DexType.UniswapV3,
                buyQuoteAmount: quoteIn,
                deadline: block.timestamp
            })
        );
    }
}
