// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {FeeTo} from "../../src/core/FeeTo.sol";
import {IFeeTo} from "../../src/interfaces/IFeeTo.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

contract FeeToTest is SetUp {
    FeeTo internal feeTo;
    address internal operator;
    address internal token;
    address internal pair;

    bytes4 internal constant CLAIM_SELECTOR = IFeeTo.claim.selector;
    bytes4 internal constant BURN_SELECTOR = IFeeTo.burn.selector;

    function setUp() public virtual override {
        super.setUp();
        operator = makeAddr("operator");

        FeeTo impl = new FeeTo();
        feeTo = FeeTo(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(FeeTo.initialize, (address(protocolManager), address(giwaRouter)))
                )
            )
        );

        vm.startPrank(admin);
        protocolManager.setFactoryFeeTo(address(nadFunFactory), address(feeTo));
        protocolManager.setOperatorPermission(operator, address(feeTo), CLAIM_SELECTOR, true);
        protocolManager.setOperatorPermission(operator, address(feeTo), BURN_SELECTOR, true);
        vm.stopPrank();

        (token, pair) = _createV2Market("FeeToTest", "FT");
    }

    // -- Helpers --------------------------------------------------------

    function _swap(uint256 buyAmount) internal {
        _swapToken(token, pair, buyAmount);
    }

    function _createV2Market(string memory name, string memory symbol)
        internal
        returns (address token_, address pair_)
    {
        MockERC20 baseToken = new MockERC20(name, symbol, 18);
        token_ = address(baseToken);
        pair_ = nadFunFactory.createPair(token_, address(quoteToken));

        uint256 tokenLiquidity = 1_000_000 ether;
        uint256 quoteLiquidity = 100_000 ether;
        baseToken.mint(address(this), tokenLiquidity);
        quoteToken.mint(address(this), quoteLiquidity);
        baseToken.transfer(pair_, tokenLiquidity);
        quoteToken.transfer(pair_, quoteLiquidity);
        INadFunPair(pair_).mint(address(this));
    }

    function _swapToken(address token_, address pair_, uint256 buyAmount) internal {
        quoteToken.mint(user2, buyAmount);
        vm.startPrank(user2);
        quoteToken.transfer(address(nadSwapAdapter), buyAmount);
        uint256 tokenOut = nadSwapAdapter.swap(pair_, address(quoteToken), token_, buyAmount, user2, "");
        IERC20(token_).transfer(address(nadSwapAdapter), tokenOut);
        nadSwapAdapter.swap(pair_, token_, address(quoteToken), tokenOut, user2, "");
        vm.stopPrank();
    }

    function _fundOperator(uint256 quoteAmount) internal {
        quoteToken.mint(operator, quoteAmount);
        vm.prank(operator);
        quoteToken.approve(address(feeTo), quoteAmount);
    }

    function _singleEntry(uint256 quoteIn) internal view returns (IFeeTo.ClaimParams[] memory params) {
        params = new IFeeTo.ClaimParams[](1);
        params[0] = IFeeTo.ClaimParams({pair: pair, token: token, quote: address(quoteToken), quoteIn: quoteIn});
    }

    function _claim(uint256 quoteIn) internal returns (uint256[] memory) {
        IFeeTo.ClaimParams[] memory params = _singleEntry(quoteIn);
        vm.prank(operator);
        return feeTo.claim(params, block.timestamp + 1);
    }

    // -- Initialization -------------------------------------------------

    function test_initialize_setsState() public view {
        assertEq(feeTo.router(), address(giwaRouter));
        assertEq(feeTo.authority(), address(protocolManager));
    }

    function test_initialize_rejectsZeroRouter() public {
        FeeTo impl = new FeeTo();
        vm.expectRevert(IFeeTo.InvalidRecipient.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(FeeTo.initialize, (address(protocolManager), address(0))));
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        feeTo.initialize(address(protocolManager), address(giwaRouter));
    }

    function test_setAuthority_alwaysReverts() public {
        vm.expectRevert();
        feeTo.setAuthority(address(this));
    }

    // -- Access + validation ------------------------------------------

    function test_claim_revertsForUnauthorizedCaller() public {
        _fundOperator(1 ether);
        IFeeTo.ClaimParams[] memory params = _singleEntry(1 ether);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        feeTo.claim(params, block.timestamp + 1);
    }

    function test_claim_revertsOnEmptyBatch() public {
        IFeeTo.ClaimParams[] memory params = new IFeeTo.ClaimParams[](0);
        vm.prank(operator);
        vm.expectRevert(IFeeTo.EmptyBatch.selector);
        feeTo.claim(params, block.timestamp + 1);
    }

    function test_claim_revertsOnZeroQuoteIn() public {
        IFeeTo.ClaimParams[] memory params = _singleEntry(0);
        vm.prank(operator);
        vm.expectRevert(IFeeTo.InvalidQuoteIn.selector);
        feeTo.claim(params, block.timestamp + 1);
    }

    function test_claim_revertsOnExpiredDeadline() public {
        _fundOperator(1 ether);
        IFeeTo.ClaimParams[] memory params = _singleEntry(1 ether);
        vm.prank(operator);
        vm.expectRevert(IFeeTo.ExpiredDeadline.selector);
        feeTo.claim(params, block.timestamp - 1);
    }

    function test_claim_revertsWhenQuoteNotInPair() public {
        _fundOperator(1 ether);
        IFeeTo.ClaimParams[] memory params = _singleEntry(1 ether);
        params[0].quote = makeAddr("bogus");
        vm.prank(operator);
        vm.expectRevert(IFeeTo.InvalidPair.selector);
        feeTo.claim(params, block.timestamp + 1);
    }

    function test_claim_revertsWhenTokenNotInPair() public {
        _fundOperator(1 ether);
        IFeeTo.ClaimParams[] memory params = _singleEntry(1 ether);
        params[0].token = makeAddr("bogus");
        vm.prank(operator);
        vm.expectRevert(IFeeTo.InvalidPair.selector);
        feeTo.claim(params, block.timestamp + 1);
    }

    // -- Happy path ----------------------------------------------------

    function test_claim_singleEntry_refundsPrincipalAndForwardsExcess() public {
        _swap(50_000 ether);
        uint256 recipientBefore = quoteToken.balanceOf(protocolManager.feeReceiver());

        _fundOperator(10 ether);
        uint256[] memory outs = _claim(10 ether);

        assertEq(outs.length, 1);
        uint256 refund = quoteToken.balanceOf(operator);
        uint256 recipientDelta = quoteToken.balanceOf(protocolManager.feeReceiver()) - recipientBefore;

        assertGt(refund, 0, "operator refund > 0");
        assertLe(refund, 10 ether, "refund <= principal");
        assertGe(recipientDelta, outs[0], "recipient delta >= per-entry quoteOut");
        assertEq(quoteToken.balanceOf(address(feeTo)), 0, "no leftover quote");
        assertEq(IERC20(token).balanceOf(address(feeTo)), 0, "no leftover token");
        assertEq(IERC20(pair).balanceOf(address(feeTo)), 0, "no leftover LP");
    }

    function test_claim_zeroDilution_principalReturnedNoExcess() public {
        _fundOperator(5 ether);
        uint256[] memory outs = _claim(5 ether);
        assertEq(outs[0], 0, "no per-entry excess without dilution");
        uint256 refund = quoteToken.balanceOf(operator);
        assertGt(refund, 0, "partial refund");
        assertLt(refund, 5 ether, "swap fees reduce refund below principal");
    }

    function test_claim_emitsClaimedPerEntry() public {
        _swap(50_000 ether);
        _fundOperator(5 ether);
        IFeeTo.ClaimParams[] memory params = _singleEntry(5 ether);
        vm.prank(operator);
        vm.expectEmit(true, true, false, false);
        emit IFeeTo.Claimed(pair, token, 5 ether, 0);
        feeTo.claim(params, block.timestamp + 1);
    }

    // -- Batch (multiple pairs) ---------------------------------------

    function test_claim_batchTwoPairsSameQuote() public {
        (address token2, address pair2) = _createV2Market("FeeToTest2", "FT2");

        _swap(50_000 ether);
        _swapToken(token2, pair2, 50_000 ether);

        _fundOperator(20 ether);

        IFeeTo.ClaimParams[] memory params = new IFeeTo.ClaimParams[](2);
        params[0] = IFeeTo.ClaimParams({pair: pair, token: token, quote: address(quoteToken), quoteIn: 10 ether});
        params[1] = IFeeTo.ClaimParams({pair: pair2, token: token2, quote: address(quoteToken), quoteIn: 10 ether});

        vm.prank(operator);
        uint256[] memory outs = feeTo.claim(params, block.timestamp + 1);

        assertEq(outs.length, 2);
        uint256 refund = quoteToken.balanceOf(operator);
        assertGt(refund, 0, "operator gets refund");
        assertLe(refund, 20 ether, "refund <= total principal");
        assertEq(quoteToken.balanceOf(address(feeTo)), 0, "no leftover quote");
    }

    function test_claim_feeReceiverChangesWithProtocolManager() public {
        address newReceiver = makeAddr("newReceiver");
        vm.prank(admin);
        protocolManager.setFeeReceiver(newReceiver);

        _swap(50_000 ether);
        _fundOperator(1 ether);
        uint256 before = quoteToken.balanceOf(newReceiver);
        uint256[] memory outs = _claim(1 ether);
        assertGe(quoteToken.balanceOf(newReceiver) - before, outs[0]);
    }

    // -- burn ----------------------------------------------------------

    /// @dev Seed dilution LP onto FeeTo: generate k growth via swaps, then have an
    ///      external LP trigger `pair.mint()` -> `_mintFee` deposits dilution LP at
    ///      factory.feeTo() which is the FeeTo contract.
    function _seedDilutionLpOnFeeTo() internal {
        _swap(80_000 ether);
        // External LP adds a small position to trigger _mintFee.
        (uint112 r0, uint112 r1,) = INadFunPair(pair).getReserves();
        uint256 totalSupply = IERC20(pair).totalSupply();
        // Mint enough on both sides that liquidity > 0
        uint256 quoteIn = uint256(r0) / totalSupply + 1 ether;
        uint256 tokenIn = uint256(r1) / totalSupply + 1 ether;
        if (INadFunPair(pair).token0() == address(quoteToken)) {
            (quoteIn, tokenIn) = (quoteIn, tokenIn);
        } else {
            (quoteIn, tokenIn) = (tokenIn, quoteIn);
        }
        quoteToken.mint(address(this), quoteIn);
        deal(token, address(this), tokenIn);
        quoteToken.transfer(pair, quoteIn);
        IERC20(token).transfer(pair, tokenIn);
        INadFunPair(pair).mint(address(this));
    }

    function test_burn_revertsOnEmptyBatch() public {
        address[] memory pairs = new address[](0);
        vm.prank(operator);
        vm.expectRevert(IFeeTo.EmptyBatch.selector);
        feeTo.burn(pairs);
    }

    function test_burn_revertsForUnauthorizedCaller() public {
        address[] memory pairs = new address[](1);
        pairs[0] = pair;
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        feeTo.burn(pairs);
    }

    function test_burn_noLpOnFeeTo_returnsZeros() public {
        address[] memory pairs = new address[](1);
        pairs[0] = pair;
        vm.prank(operator);
        (uint256[] memory a0, uint256[] memory a1) = feeTo.burn(pairs);
        assertEq(a0[0], 0);
        assertEq(a1[0], 0);
    }

    function test_burn_forwardsUnderlyingToFeeReceiver() public {
        _seedDilutionLpOnFeeTo();
        uint256 lpOnFeeTo = IERC20(pair).balanceOf(address(feeTo));
        assertGt(lpOnFeeTo, 0, "precondition: dilution LP accumulated on FeeTo");

        address recipient = protocolManager.feeReceiver();
        address t0 = INadFunPair(pair).token0();
        address t1 = INadFunPair(pair).token1();
        uint256 t0Before = IERC20(t0).balanceOf(recipient);
        uint256 t1Before = IERC20(t1).balanceOf(recipient);

        address[] memory pairs = new address[](1);
        pairs[0] = pair;
        vm.prank(operator);
        (uint256[] memory a0, uint256[] memory a1) = feeTo.burn(pairs);

        assertGt(a0[0] + a1[0], 0, "burn returned underlyings");
        assertEq(IERC20(t0).balanceOf(recipient) - t0Before, a0[0], "token0 forwarded to recipient");
        assertEq(IERC20(t1).balanceOf(recipient) - t1Before, a1[0], "token1 forwarded to recipient");
        assertEq(IERC20(pair).balanceOf(address(feeTo)), 0, "all LP burned");
    }
}
