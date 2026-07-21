// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {INadFunRouter02} from "../../src/interfaces/INadFunRouter02.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract RouterLiquidityTest is SetUp {
    function test_factoryAndWeth_getters() public view {
        assertEq(nadFunRouter02.factory(), address(nadFunFactory));
        assertEq(nadFunRouter02.WETH(), address(wmon));
    }

    function test_setFactory_onlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        nadFunRouter02.setFactory(address(0x1234));
    }

    function test_createPair_createsAndSorts() public {
        address a = address(new MockERC20("A", "A", 18));
        address b = address(new MockERC20("B", "B", 18));
        address pair = nadFunRouter02.createPair(a, b);
        assertEq(pair, nadFunFactory.getPair(a, b));
        assertTrue(pair != address(0));
    }

    function test_createPair_revertsOnDuplicate() public {
        address a = address(new MockERC20("A", "A", 18));
        address b = address(new MockERC20("B", "B", 18));
        nadFunRouter02.createPair(a, b);
        vm.expectRevert(); // NadFunFactory.PairExists
        nadFunRouter02.createPair(a, b);
    }

    function test_quote_view() public view {
        assertEq(nadFunRouter02.quote(100, 1000, 5000), 500);
    }

    function test_getAmountOut_lpFeeOnly() public view {
        uint256 out = nadFunRouter02.getAmountOut(1000, 1_000_000, 1_000_000);
        assertGt(out, 0);
        assertLt(out, 1000);
    }

    /// @dev Graduate a token; return token + its pair (quoteToken-quoted).
    function _graduatedToken() internal returns (address token, address pair) {
        token = _createToken();
        _skipAntiSniping();
        _graduateToken(token);
        pair = nadFunFactory.getPair(token, address(quoteToken));
        assertTrue(pair != address(0), "pair exists");
    }

    /// @dev Give `who` `quoteAmt` quoteToken for LP, plus tokens bought on the DEX, all approved to both routers.
    function _fundProvider(address who, address token, uint256 quoteAmt) internal {
        quoteToken.mint(who, quoteAmt); // for adding liquidity
        quoteToken.mint(who, quoteAmt); // extra to buy token with
        vm.startPrank(who);
        quoteToken.approve(address(nadFunRouter), type(uint256).max);
        quoteToken.approve(address(nadFunRouter02), type(uint256).max);
        nadFunRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: quoteAmt, amountOutMin: 0, token: token, to: who, deadline: block.timestamp + 1
            })
        );
        IERC20Like(token).approve(address(nadFunRouter), type(uint256).max);
        IERC20Like(token).approve(address(nadFunRouter02), type(uint256).max);
        vm.stopPrank();
    }

    function test_addLiquidity_existingPair_optimalRatio() public {
        (address token, address pair) = _graduatedToken();
        _fundProvider(user2, token, 1_000 ether);
        uint256 tokenBal = IERC20Like(token).balanceOf(user2);
        assertGt(tokenBal, 0);

        vm.startPrank(user2);
        (uint256 amountA, uint256 amountB, uint256 liq) = nadFunRouter02.addLiquidity(
            token, address(quoteToken), tokenBal, 1_000 ether, 0, 0, user2, block.timestamp + 1
        );
        vm.stopPrank();

        assertGt(liq, 0, "LP minted");
        assertGt(IERC20Like(pair).balanceOf(user2), 0, "provider holds LP");
        assertTrue(amountA == tokenBal || amountB == 1_000 ether, "one side maxed");
    }

    function test_addLiquidity_revertsExpiredDeadline() public {
        (address token,) = _graduatedToken();
        vm.expectRevert(INadFunRouter02.ExpiredDeadline.selector);
        nadFunRouter02.addLiquidity(token, address(quoteToken), 1, 1, 0, 0, user2, block.timestamp - 1);
    }

    /// @dev Plain ERC20 + wmon pair seeded with liquidity by the test contract. Returns token, pair.
    ///      Pool ratio = 1_000_000 token : 1_000 wmon (1000:1).
    function _wmonPairWithLiquidity() internal returns (address token, address pair) {
        MockERC20 t = new MockERC20("WT", "WT", 18);
        token = address(t);
        uint256 tAmt = 1_000_000 ether;
        uint256 wAmt = 1_000 ether;
        t.mint(address(this), tAmt);
        vm.deal(address(this), wAmt);
        wmon.deposit{value: wAmt}();
        t.approve(address(nadFunRouter), type(uint256).max);
        t.approve(address(nadFunRouter02), type(uint256).max);
        wmon.approve(address(nadFunRouter), type(uint256).max);
        wmon.approve(address(nadFunRouter02), type(uint256).max);
        nadFunRouter02.addLiquidity(token, address(wmon), tAmt, wAmt, 0, 0, address(this), block.timestamp + 1);
        pair = nadFunFactory.getPair(token, address(wmon));
        require(pair != address(0), "wmon pair");
    }

    function test_removeLiquidity_returnsProportional() public {
        (address token, address pair) = _graduatedToken();
        _fundProvider(user2, token, 1_000 ether);
        uint256 tokenBal = IERC20Like(token).balanceOf(user2);
        vm.startPrank(user2);
        (,, uint256 liq) = nadFunRouter02.addLiquidity(
            token, address(quoteToken), tokenBal, 1_000 ether, 0, 0, user2, block.timestamp + 1
        );
        IERC20Like(pair).approve(address(nadFunRouter), type(uint256).max);
        IERC20Like(pair).approve(address(nadFunRouter02), type(uint256).max);
        uint256 tBefore = IERC20Like(token).balanceOf(user2);
        uint256 qBefore = quoteToken.balanceOf(user2);
        (uint256 amountA, uint256 amountB) =
            nadFunRouter02.removeLiquidity(token, address(quoteToken), liq, 0, 0, user2, block.timestamp + 1);
        vm.stopPrank();
        assertGt(amountA, 0);
        assertGt(amountB, 0);
        assertEq(IERC20Like(token).balanceOf(user2), tBefore + amountA);
        assertEq(quoteToken.balanceOf(user2), qBefore + amountB);
        assertEq(IERC20Like(pair).balanceOf(user2), 0, "LP fully burned");
    }

    function test_removeLiquidity_revertsSlippage() public {
        (address token, address pair) = _graduatedToken();
        _fundProvider(user2, token, 1_000 ether);
        uint256 tokenBal = IERC20Like(token).balanceOf(user2);
        vm.startPrank(user2);
        (,, uint256 liq) = nadFunRouter02.addLiquidity(
            token, address(quoteToken), tokenBal, 1_000 ether, 0, 0, user2, block.timestamp + 1
        );
        IERC20Like(pair).approve(address(nadFunRouter), type(uint256).max);
        IERC20Like(pair).approve(address(nadFunRouter02), type(uint256).max);
        vm.expectRevert();
        nadFunRouter02.removeLiquidity(
            token, address(quoteToken), liq, type(uint256).max, 0, user2, block.timestamp + 1
        );
        vm.stopPrank();
    }

    function test_removeLiquidityETH_unwrapsToNative() public {
        (address token, address pair) = _wmonPairWithLiquidity();
        MockERC20(token).mint(user2, 100_000 ether);
        vm.deal(user2, 100 ether);
        vm.startPrank(user2);
        MockERC20(token).approve(address(nadFunRouter), type(uint256).max);
        MockERC20(token).approve(address(nadFunRouter02), type(uint256).max);
        (,, uint256 liq) =
            nadFunRouter02.addLiquidityETH{value: 50 ether}(token, 10_000 ether, 0, 0, user2, block.timestamp + 1);
        IERC20Like(pair).approve(address(nadFunRouter), type(uint256).max);
        IERC20Like(pair).approve(address(nadFunRouter02), type(uint256).max);
        uint256 ethBefore = user2.balance;
        (uint256 amountToken, uint256 amountETH) =
            nadFunRouter02.removeLiquidityETH(token, liq, 0, 0, user2, block.timestamp + 1);
        vm.stopPrank();
        assertGt(amountToken, 0);
        assertGt(amountETH, 0);
        assertEq(user2.balance, ethBefore + amountETH, "received native MON");
    }

    function test_addLiquidityETH_wrapsAndRefunds() public {
        (address token, address pair) = _wmonPairWithLiquidity();
        MockERC20(token).mint(user2, 10_000 ether);
        vm.deal(user2, 100 ether);
        vm.startPrank(user2);
        MockERC20(token).approve(address(nadFunRouter), type(uint256).max);
        MockERC20(token).approve(address(nadFunRouter02), type(uint256).max);
        uint256 ethBefore = user2.balance;
        // pool 1_000_000:1_000 → optimal wmon for 10_000 token = 10 ether; we send 50 → 40 refund
        (uint256 amountToken, uint256 amountETH, uint256 liq) =
            nadFunRouter02.addLiquidityETH{value: 50 ether}(token, 10_000 ether, 0, 0, user2, block.timestamp + 1);
        vm.stopPrank();
        assertGt(liq, 0);
        assertGt(IERC20Like(pair).balanceOf(user2), 0);
        assertLt(amountETH, 50 ether, "some MON refunded");
        assertEq(user2.balance, ethBefore - amountETH, "excess MON refunded exactly");
        assertGt(amountToken, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Permit digest helper
    // ─────────────────────────────────────────────────────────────────────────

    function _lpPermitDigest(address pair, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        uint256 nonce = IERC20Permit(pair).nonces(owner);
        bytes32 structHash = keccak256(abi.encode(typehash, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", IERC20Permit(pair).DOMAIN_SEPARATOR(), structHash));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Task 9 — removeLiquidityWithPermit + removeLiquidityETHWithPermit
    // ─────────────────────────────────────────────────────────────────────────

    function test_removeLiquidityWithPermit_noPriorApprove() public {
        uint256 pk = 0xA11CE;
        address provider = vm.addr(pk);
        (address token, address pair) = _graduatedToken();
        _fundProvider(provider, token, 1_000 ether);
        uint256 liq = _addLiqAndGetLp(provider, token);
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, pair, provider, liq, deadline);
        _removeWithPermitAndAssert(provider, token, pair, liq, deadline, v, r, s);
    }

    function _removeWithPermitAndAssert(
        address provider,
        address token,
        address pair,
        uint256 liq,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        _doRemoveWithPermit(provider, token, liq, deadline, v, r, s);
        assertEq(IERC20Like(pair).balanceOf(provider), 0, "LP burned via permit, no prior approve");
    }

    function _doRemoveWithPermit(
        address provider,
        address token,
        uint256 liq,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) private {
        vm.prank(provider);
        (uint256 amountA, uint256 amountB) = nadFunRouter02.removeLiquidityWithPermit(
            token, address(quoteToken), liq, 0, 0, provider, deadline, false, v, r, s
        );
        assertGt(amountA, 0);
        assertGt(amountB, 0);
    }

    function _addLiqAndGetLp(address provider, address token) internal returns (uint256 liq) {
        uint256 tokenBal = IERC20Like(token).balanceOf(provider);
        vm.startPrank(provider);
        (,, liq) = nadFunRouter02.addLiquidity(
            token, address(quoteToken), tokenBal, 1_000 ether, 0, 0, provider, block.timestamp + 1
        );
        vm.stopPrank();
    }

    function _signPermit(uint256 pk, address pair, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = _lpPermitDigest(pair, owner, address(nadFunRouter02), value, deadline);
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_removeLiquidityETHWithPermit() public {
        uint256 pk = 0xB0B;
        address provider = vm.addr(pk);
        (address token, address pair) = _wmonPairWithLiquidity();
        uint256 liq = _addLiqETHAndGetLp(provider, token);
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, pair, provider, liq, deadline);
        _removeETHWithPermitAndAssert(provider, token, liq, deadline, v, r, s);
    }

    function _removeETHWithPermitAndAssert(
        address provider,
        address token,
        uint256 liq,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        uint256 ethBefore = provider.balance;
        vm.prank(provider);
        (uint256 amountToken, uint256 amountETH) =
            nadFunRouter02.removeLiquidityETHWithPermit(token, liq, 0, 0, provider, deadline, false, v, r, s);
        assertGt(amountToken, 0);
        assertEq(provider.balance, ethBefore + amountETH, "received MON via permit");
    }

    function _addLiqETHAndGetLp(address provider, address token) internal returns (uint256 liq) {
        MockERC20(token).mint(provider, 100_000 ether);
        vm.deal(provider, 100 ether);
        vm.startPrank(provider);
        MockERC20(token).approve(address(nadFunRouter), type(uint256).max);
        MockERC20(token).approve(address(nadFunRouter02), type(uint256).max);
        (,, liq) =
            nadFunRouter02.addLiquidityETH{value: 50 ether}(token, 10_000 ether, 0, 0, provider, block.timestamp + 1);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Safety: pre-graduation addLiquidity must revert (Token._update guard)
    // ─────────────────────────────────────────────────────────────────────────

    function test_addLiquidity_preGraduation_reverts() public {
        address token = _createToken(); // NOT graduated → pair exists but Token blocks transfers to it
        _skipAntiSniping();
        quoteToken.mint(user2, 1_000 ether);
        vm.startPrank(user2);
        quoteToken.approve(address(nadFunRouter), type(uint256).max);
        quoteToken.approve(address(nadFunRouter02), type(uint256).max);
        // buy some token on the curve so the provider holds token (pre-graduation, routes to bonding curve)
        nadFunRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: 100 ether, amountOutMin: 0, token: token, to: user2, deadline: block.timestamp + 1
            })
        );
        uint256 tokenBal = IERC20Like(token).balanceOf(user2);
        assertGt(tokenBal, 0, "provider holds token");
        IERC20Like(token).approve(address(nadFunRouter), type(uint256).max);
        IERC20Like(token).approve(address(nadFunRouter02), type(uint256).max);
        // addLiquidity must revert: Token.sol blocks transfer to the pre-graduation pair
        vm.expectRevert();
        nadFunRouter02.addLiquidity(token, address(quoteToken), tokenBal, 100 ether, 0, 0, user2, block.timestamp + 1);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Task 10 — removeLiquidityETHSupportingFOT + ...WithPermit variant
    // ─────────────────────────────────────────────────────────────────────────

    function test_removeLiquidityETHSupportingFOT_receivesTokenAndMon() public {
        (address token, address pair) = _wmonPairWithLiquidity();
        MockERC20(token).mint(user2, 100_000 ether);
        vm.deal(user2, 100 ether);
        vm.startPrank(user2);
        MockERC20(token).approve(address(nadFunRouter), type(uint256).max);
        MockERC20(token).approve(address(nadFunRouter02), type(uint256).max);
        (,, uint256 liq) =
            nadFunRouter02.addLiquidityETH{value: 50 ether}(token, 10_000 ether, 0, 0, user2, block.timestamp + 1);
        IERC20Like(pair).approve(address(nadFunRouter), type(uint256).max);
        IERC20Like(pair).approve(address(nadFunRouter02), type(uint256).max);
        uint256 ethBefore = user2.balance;
        uint256 tokBefore = IERC20Like(token).balanceOf(user2);
        uint256 amountETH = nadFunRouter02.removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liq, 0, 0, user2, block.timestamp + 1
        );
        vm.stopPrank();
        assertGt(amountETH, 0);
        assertEq(user2.balance, ethBefore + amountETH, "received MON");
        assertGt(IERC20Like(token).balanceOf(user2), tokBefore, "received token");
    }
}
