// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title FullLifecycleE2E -- End-to-end integration test for the full V3 token lifecycle
/// @notice Covers: create -> buy on curve -> graduate -> trade on DEX -> settlement -> vault distribution
contract FullLifecycleE2E is SetUp {
    // ═══════════════════════════════════════════════════════════════
    // Full Lifecycle: create -> curve buy -> graduate -> DEX trade
    //                 -> settlement -> vault distribution
    // ═══════════════════════════════════════════════════════════════

    function test_fullLifecycle() public {
        // Phase 1: Create token
        address token = _createToken();
        _verifyCreation(token);

        // Phase 2: Buy on bonding curve
        _verifyBuyOnCurve(token);

        // Phase 3: Graduate
        _graduateAndVerify(token);

        // Phase 4: Check DEX pair state
        _verifyDexPairState(token);

        // Phase 5-6: DEX buy + sell
        _verifyDexTrading(token);

        // Phase 7-11: Settlement + vault distribution
        _verifySettlement(token);
    }

    function _verifyCreation(address token) internal view {
        assertTrue(token != address(0), "Token should be deployed");
        assertEq(IERC20(token).totalSupply(), 1_000_000_000 ether, "Total supply should be 1B");
        assertEq(IToken(token).bondingCurve(), address(bondingCurve), "bondingCurve should match");
        assertFalse(IToken(token).isGraduated(), "Should not be graduated yet");

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        ITokenRegistry.TokenInfo memory info = tokenRegistry.getTokenInfo(token);
        address pair = info.pool;
        assertTrue(pair != address(0), "Pool should exist");
        assertEq(curve.pair, pair, "Curve pool should match registry pool");
        assertEq(pair, v3Factory.getPool(token, address(quoteToken), info.feeTier), "canonical V3 pool");

        IFeeCollector.FeeConfig memory feeConfig = feeCollector.getFeeConfig(pair);
        assertEq(feeConfig.creatorFeeRate, defaultCreatorFeeRate, "FeeCollector creatorFeeRate mismatch");
        assertEq(feeConfig.curveProtocolFeeRate, defaultCurveProtocolFee, "curveProtocolFeeRate mismatch");
        assertEq(feeConfig.dexProtocolFeeRate, defaultDexProtocolFee, "dexProtocolFeeRate mismatch");
        assertEq(creatorFeeProcessor.vaultCount(token), 1, "CreatorFeeProcessor should have 1 vault");
    }

    function _verifyBuyOnCurve(address token) internal {
        // Skip anti-sniping period for the newly created token
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        address pair = tokenRegistry.getPool(token);
        uint256 fcBalBefore = quoteToken.balanceOf(address(feeCollector));
        uint256 feeRecvBefore = quoteToken.balanceOf(feeReceiver);

        uint256 tokenOut = _buyOnCurve(user1, token, 10_000 ether);

        assertTrue(tokenOut > 0, "Should receive tokens from buy");
        assertEq(IERC20(token).balanceOf(user1), tokenOut, "User1 balance should match (no creator-fee-on-transfer)");

        uint256 creatorFeeAccumulated = quoteToken.balanceOf(address(feeCollector)) - fcBalBefore;
        assertTrue(creatorFeeAccumulated > 0, "FeeCollector should accumulate creator fee from buy");

        uint256 protocolFeePaid = quoteToken.balanceOf(feeReceiver) - feeRecvBefore;
        assertTrue(protocolFeePaid > 0, "FeeReceiver should get protocol fee from curve buy");

        assertEq(feeCollector.accumulatedFee(pair), creatorFeeAccumulated, "accumulatedFee should match balance");
    }

    function _graduateAndVerify(address token) internal {
        // Warp past sniping period for this token
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        _mintAndTransfer(user2, 800_000 ether);
        vm.prank(user2);
        bondingCurve.buy(user2, token);

        assertTrue(bondingCurve.getCurve(token).graduated, "Token should be graduated");
        assertTrue(IToken(token).isGraduated(), "Token.isGraduated() should be true");
    }

    function _verifyDexPairState(address token) internal view {
        address pool = tokenRegistry.getPool(token);
        (bytes32 quoteKey,,, uint128 quoteLiquidity, bytes32 tokenKey,,, uint128 tokenLiquidity) =
            lpManager.getPositions(token);
        assertNotEq(quoteKey, bytes32(0), "quote position exists");
        assertNotEq(tokenKey, bytes32(0), "token position exists");
        assertGt(quoteLiquidity, 0, "quote liquidity exists");
        assertGt(tokenLiquidity, 0, "token liquidity exists");
        assertEq(tokenRegistry.getPair(token), pool, "TokenRegistry pair alias should match pool");
    }

    function _verifyDexTrading(address token) internal {
        uint256 feeRecvBefore = quoteToken.balanceOf(feeReceiver);

        // DEX buy
        uint256 dexTokenOut = _dexBuy(user3, token, 5_000 ether);
        assertTrue(dexTokenOut > 0, "Should receive tokens from DEX buy");
        assertEq(IERC20(token).balanceOf(user3), dexTokenOut, "User3 balance should match DEX buy");

        // The V3 router sends its protocol fee directly to the current fee receiver.
        uint256 feeRecvAfterBuy = quoteToken.balanceOf(feeReceiver);
        assertTrue(feeRecvAfterBuy > feeRecvBefore, "FeeReceiver should get protocol fee from DEX buy");

        // DEX sell
        uint256 sellAmount = dexTokenOut / 2;
        uint256 dexQuoteOut = _dexSell(user3, token, sellAmount);
        assertTrue(dexQuoteOut > 0, "Should receive quote from DEX sell");

        uint256 feeRecvAfterSell = quoteToken.balanceOf(feeReceiver);
        assertTrue(feeRecvAfterSell > feeRecvAfterBuy, "FeeReceiver should get protocol fee from DEX sell");
    }

    function _verifySettlement(address token) internal {
        address pair = tokenRegistry.getPool(token);

        // Verify the fee system is functioning: feeReceiver should have received funds.
        uint256 feeRecvBalance = quoteToken.balanceOf(feeReceiver);
        assertTrue(feeRecvBalance > 0, "FeeReceiver should have received protocol fees");

        uint256 remaining = feeCollector.accumulatedFee(pair);
        assertGt(remaining, 0, "Creator fees should remain available for settlement");
        assertTrue(feeCollector.isSettleable(pair), "Creator fees should cross the settlement threshold");

        uint256 creditedBefore = creatorFeeVault.getBalance(token);
        feeCollector.settle(pair, 0);
        uint256 creditedAfter = creatorFeeVault.getBalance(token);

        assertEq(feeCollector.accumulatedFee(pair), 0, "Accumulated fee should be 0 after settlement");
        assertEq(creditedAfter - creditedBefore, remaining, "CreatorFeeVault should credit the settled amount");
        assertEq(
            quoteToken.balanceOf(address(creatorFeeVault)), creditedAfter, "CreatorFeeVault balance should back credits"
        );

        // Intermediate contracts should be empty
        assertEq(quoteToken.balanceOf(address(creatorFeeProcessor)), 0, "CreatorFeeProcessor should have 0 balance");
        assertEq(quoteToken.balanceOf(address(feeCollector)), 0, "FeeCollector should have 0 balance");
    }

    function test_create_revertsOnDuplicateVaultAddress() public {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](2);
        bytes memory setupData = abi.encode(creator);
        vaults[0] = IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 5000, setupData: setupData});
        vaults[1] = IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 5000, setupData: setupData});

        uint256 deployFee = protocolManager.deployFee(address(quoteToken));
        quoteToken.mint(creator, deployFee);
        vm.prank(creator);
        quoteToken.approve(address(giwaRouter), deployFee);

        vm.prank(creator);
        vm.expectRevert(IBondingCurve.DuplicateVault.selector);
        giwaRouter.create(
            IGiwaRouter.CreateParams({
                name: "DuplicateVault",
                symbol: "DV",
                tokenURI: "",
                quoteToken: address(quoteToken),
                creatorFeeRate: defaultCreatorFeeRate,
                vaults: vaults,
                salt: keccak256("duplicate-vault-e2e"),
                dexType: ITokenRegistry.DexType.UniswapV3,
                buyQuoteAmount: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // Vanilla Pair (no protocol/creator fees, only 0.25% LP fee)
    // ═══════════════════════════════════════════════════════════════

    function test_vanillaPair_noFees() public {
        // Create a vanilla pair directly via NadFunFactory (not through BondingCurve)
        MockERC20 tokenA = new MockERC20("VanillaToken", "VT", 18);
        address vanillaPair = nadFunFactory.createPair(address(tokenA), address(quoteToken));
        assertTrue(vanillaPair != address(0), "Vanilla pair should be created");

        // Add initial liquidity
        _addLiquidity(vanillaPair, tokenA, 1_000_000 ether, 100_000 ether);

        // Verify: feeCollector is set, but fee rate for vanillaPair is 0 (no setup called)
        address fc = INadFunPair(vanillaPair).feeCollector();
        assertTrue(fc != address(0), "Vanilla pair should have feeCollector set");
        IFeeCollector.FeeConfig memory vanillaConfig = IFeeCollector(fc).getFeeConfig(vanillaPair);
        assertEq(
            vanillaConfig.creatorFeeRate + vanillaConfig.curveProtocolFeeRate + vanillaConfig.dexProtocolFeeRate,
            0,
            "Vanilla pair fee rate should be 0"
        );

        // Swap and verify only 0.25% LP fee applies
        _swapAndVerifyVanilla(vanillaPair, tokenA);
    }

    function _addLiquidity(address pair, MockERC20 tokenA, uint256 tokenLiq, uint256 quoteLiq) internal {
        tokenA.mint(address(this), tokenLiq);
        quoteToken.mint(address(this), quoteLiq);
        tokenA.transfer(pair, tokenLiq);
        quoteToken.transfer(pair, quoteLiq);
        INadFunPair(pair).mint(address(this));
    }

    function _swapAndVerifyVanilla(address vanillaPair, MockERC20 tokenA) internal {
        uint256 swapAmount = 1_000 ether;
        uint256 fcBalBefore = quoteToken.balanceOf(address(feeCollector));

        // Source of truth: pair.getAmountOut (vanilla pair with no NadFun fee config)
        uint256 expectedOut = INadFunPair(vanillaPair).getAmountOut(address(quoteToken), swapAmount);

        quoteToken.mint(address(this), swapAmount);
        quoteToken.transfer(vanillaPair, swapAmount);

        // Cache reserves-before for K-invariant check
        (uint112 r0, uint112 r1,) = INadFunPair(vanillaPair).getReserves();

        // Execute swap
        address token0 = INadFunPair(vanillaPair).token0();
        if (address(quoteToken) == token0) {
            INadFunPair(vanillaPair).swap(0, expectedOut, user1, "");
        } else {
            INadFunPair(vanillaPair).swap(expectedOut, 0, user1, "");
        }

        // Verify: user received exact expected amount
        assertEq(tokenA.balanceOf(user1), expectedOut, "User should receive exact expected amount");

        // Verify: FeeCollector balance unchanged (no protocol/creator fee)
        assertEq(
            quoteToken.balanceOf(address(feeCollector)),
            fcBalBefore,
            "FeeCollector should NOT get fees from vanilla pair"
        );

        // Verify: K maintained/increased (LP fee increases K)
        (uint112 r0After, uint112 r1After,) = INadFunPair(vanillaPair).getReserves();
        assertTrue(uint256(r0After) * uint256(r1After) >= uint256(r0) * uint256(r1), "K should not decrease");
    }

    // ═══════════════════════════════════════════════════════════════
    // Settlement below threshold should be a no-op
    // ═══════════════════════════════════════════════════════════════

    function test_settleBelowThreshold_noOp() public {
        address token = _createToken();
        address pair = tokenRegistry.getPool(token);
        assertFalse(feeCollector.isSettleable(pair), "Should not be settleable with 0 fees");

        uint256 accBefore = feeCollector.accumulatedFee(pair);
        feeCollector.settle(pair, 0);
        assertEq(feeCollector.accumulatedFee(pair), accBefore, "Accumulated fee should be unchanged (no-op)");
    }

    // ═══════════════════════════════════════════════════════════════
    // Internal Helpers
    // ═══════════════════════════════════════════════════════════════

    function _dexBuy(address buyer, address token, uint256 quote) internal returns (uint256 tokenOut) {
        quoteToken.mint(buyer, quote);
        vm.prank(buyer);
        quoteToken.approve(address(giwaRouter), quote);
        vm.prank(buyer);
        tokenOut = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: quote, amountOutMin: 0, token: token, to: buyer, deadline: block.timestamp + 1
            })
        );
    }

    function _dexSell(address seller, address token, uint256 tokenAmount) internal returns (uint256 quoteOut) {
        vm.prank(seller);
        IERC20(token).approve(address(giwaRouter), tokenAmount);
        vm.prank(seller);
        quoteOut = giwaRouter.sell(
            IGiwaRouter.SellParams({
                amountIn: tokenAmount, amountOutMin: 0, token: token, to: seller, deadline: block.timestamp + 1
            })
        );
    }
}
