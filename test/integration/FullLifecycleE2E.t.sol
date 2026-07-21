// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title FullLifecycleE2EV2 -- End-to-end integration test for the full token lifecycle
/// @notice Covers: create -> buy on curve -> graduate -> trade on DEX -> settlement -> vault distribution
contract FullLifecycleE2EV2 is SetUp {
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
        address pair = nadFunFactory.getPair(token, address(quoteToken));
        assertTrue(pair != address(0), "Pair should exist");
        assertEq(curve.pair, pair, "Curve pair should match factory pair");

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

        address pair = nadFunFactory.getPair(token, address(quoteToken));
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
        address pair = nadFunFactory.getPair(token, address(quoteToken));
        (uint112 r0, uint112 r1,) = INadFunPair(pair).getReserves();
        assertTrue(uint256(r0) > 0, "Pair reserve0 should be > 0");
        assertTrue(uint256(r1) > 0, "Pair reserve1 should be > 0");

        uint256 lpAtDead = IERC20(pair).balanceOf(address(0xdead));
        assertTrue(lpAtDead > 0, "LP tokens should be locked at 0xdead");

        assertEq(tokenRegistry.getPair(token), pair, "TokenRegistry pair should match");
    }

    function _verifyDexTrading(address token) internal {
        address pair = nadFunFactory.getPair(token, address(quoteToken));
        uint256 feeRecvBefore = quoteToken.balanceOf(feeReceiver);

        // DEX buy
        uint256 dexTokenOut = _dexBuy(user3, token, 5_000 ether);
        assertTrue(dexTokenOut > 0, "Should receive tokens from DEX buy");
        assertEq(IERC20(token).balanceOf(user3), dexTokenOut, "User3 balance should match DEX buy");

        // collectFee splits: protocol fee → feeReceiver instantly, creator fee → accumulated then auto-settled
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
        address pair = nadFunFactory.getPair(token, address(quoteToken));

        // Fees may have been auto-settled during swap (NadFunPair.swap calls settle).
        // Verify the fee system is functioning: feeReceiver should have received funds.
        uint256 feeRecvBalance = quoteToken.balanceOf(feeReceiver);
        assertTrue(feeRecvBalance > 0, "FeeReceiver should have received protocol fees");

        // If there are remaining accumulated fees, settle them
        uint256 remaining = feeCollector.accumulatedFee(pair);
        if (remaining > 0 && feeCollector.isSettleable(pair)) {
            feeCollector.settle(pair, 0);
            assertEq(feeCollector.accumulatedFee(pair), 0, "Accumulated fee should be 0 after settlement");
        }

        // Intermediate contracts should be empty
        assertEq(quoteToken.balanceOf(address(creatorFeeProcessor)), 0, "CreatorFeeProcessor should have 0 balance");
        assertEq(quoteToken.balanceOf(address(feeCollector)), 0, "FeeCollector should have 0 balance");
    }

    // ═══════════════════════════════════════════════════════════════
    // Full Lifecycle with BurnVault + LPVault
    // ═══════════════════════════════════════════════════════════════

    function test_fullLifecycle_multiVault() public {
        // Create token with 3 vaults: BurnVault 34%, LPVault 33%, CreatorFeeVault 33%
        address token = _createMultiVaultToken();
        assertEq(creatorFeeProcessor.vaultCount(token), 3, "Should have 3 vaults");

        // Graduate (warp past sniping period first)
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
        _graduateToken(token);
        assertTrue(IToken(token).isGraduated(), "Should be graduated");

        address pair = tokenRegistry.getPair(token);
        assertTrue(pair != address(0), "Pair should exist post-graduation");

        // Record state before DEX trades
        uint256 deadTokenBefore = IERC20(token).balanceOf(address(0xdead));
        uint256 deadLpBefore = IERC20(pair).balanceOf(address(0xdead));
        uint256 creatorBalBefore = quoteToken.balanceOf(creator);

        // Multiple DEX buys + a sell to accumulate fees
        // NadFunPair.swap() auto-settles fees when above threshold,
        // so vault distribution happens during the swaps themselves.
        _accumulateFeesViaDex(token);

        // Auto-settle should have cleared all fees. If any residual remains, settle manually.
        uint256 residual = feeCollector.accumulatedFee(pair);
        if (residual > 0 && feeCollector.isSettleable(pair)) {
            feeCollector.settle(pair, 0);
        }

        // Verify BurnVault: 0xdead should have more tokens burned
        assertTrue(
            IERC20(token).balanceOf(address(0xdead)) > deadTokenBefore, "BurnVault should have burned tokens to 0xdead"
        );

        // Verify LPVault: 0xdead should have more LP tokens
        assertTrue(
            IERC20(pair).balanceOf(address(0xdead)) > deadLpBefore, "LPVault should have added LP and burned to 0xdead"
        );

        // Verify CreatorFeeVault: vault should have accumulated quoteToken for creator
        uint256 vaultBalance = creatorFeeVault.getBalance(token);
        assertTrue(vaultBalance > 0, "CreatorFeeVault should have accumulated fees for creator");

        // Creator claims accumulated fees
        vm.prank(creator);
        creatorFeeVault.claim(token);
        assertTrue(quoteToken.balanceOf(creator) > creatorBalBefore, "Creator should receive quote after claim");

        // CreatorFeeProcessor should be empty (everything distributed to vaults)
        assertEq(quoteToken.balanceOf(address(creatorFeeProcessor)), 0, "CreatorFeeProcessor should have 0 balance");

        // Accumulated creator fee should be fully settled (0 remaining)
        assertEq(feeCollector.accumulatedFee(pair), 0, "Accumulated fee should be 0 after settlement");
    }

    function test_create_revertsOnDuplicateVaultAddress() public {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](2);
        vaults[0] = IBondingCurve.VaultAllocation({vault: address(burnVault), bps: 5000, setupData: ""});
        vaults[1] = IBondingCurve.VaultAllocation({vault: address(burnVault), bps: 5000, setupData: ""});

        uint256 deployFee = protocolManager.deployFee(address(quoteToken));
        quoteToken.mint(creator, deployFee);
        vm.prank(creator);
        quoteToken.approve(address(nadFunRouter), deployFee);

        vm.prank(creator);
        vm.expectRevert(IBondingCurve.DuplicateVault.selector);
        nadFunRouter.create(
            INadFunRouter.CreateParams({
                name: "DuplicateVault",
                symbol: "DV",
                tokenURI: "",
                quoteToken: address(quoteToken),
                creatorFeeRate: defaultCreatorFeeRate,
                vaults: vaults,
                salt: keccak256("duplicate-vault-e2e"),
                dexType: ITokenRegistry.DexType.UniswapV2,
                buyQuoteAmount: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    function _createMultiVaultToken() internal returns (address token) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](3);
        vaults[0] = IBondingCurve.VaultAllocation({vault: address(burnVault), bps: 3400, setupData: ""});
        vaults[1] = IBondingCurve.VaultAllocation({vault: address(lpVault), bps: 3300, setupData: ""});
        vaults[2] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 3300, setupData: abi.encode(creator)});

        IBondingCurve.CreateTokenParams memory params = IBondingCurve.CreateTokenParams({
            name: "MultiVault",
            symbol: "MV",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: defaultCreatorFeeRate,
            vaults: vaults,
            salt: keccak256("multi-vault-e2e"),
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: creator,
            buyQuoteAmount: 0
        });

        token = _createViaRouter(params, creator);
    }

    function _accumulateFeesViaDex(address token) internal {
        uint256 feeRecvBefore = quoteToken.balanceOf(feeReceiver);

        for (uint256 i = 0; i < 5; i++) {
            _dexBuy(user1, token, 10_000 ether);
        }

        uint256 user1Bal = IERC20(token).balanceOf(user1);
        if (user1Bal > 0) {
            _dexSell(user1, token, user1Bal / 3);
        }

        // Protocol fee → feeReceiver instantly via collectFee
        uint256 feeRecvAfter = quoteToken.balanceOf(feeReceiver);
        assertTrue(feeRecvAfter > feeRecvBefore, "FeeReceiver should get protocol fee from DEX trades");
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
    // Multiple settlements over the lifecycle
    // ═══════════════════════════════════════════════════════════════

    function test_multipleSettlements() public {
        address token = _createToken();
        address pair = nadFunFactory.getPair(token, address(quoteToken));
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
        _graduateToken(token);

        // settle() is now called externally, not auto-triggered by swap.
        // Verify that explicit settle() drains accumulated fees after each round.

        uint256 feeRecvBefore = quoteToken.balanceOf(feeReceiver);
        vm.prank(admin);
        protocolManager.setSettlementThreshold(address(quoteToken), 1);

        // Round 1
        _dexBuy(user1, token, 5_000 ether);
        feeCollector.settle(pair, 0);
        assertEq(feeCollector.accumulatedFee(pair), 0, "Should be 0 after explicit settle in round 1");

        // Round 2
        _dexBuy(user2, token, 5_000 ether);
        feeCollector.settle(pair, 0);
        assertEq(feeCollector.accumulatedFee(pair), 0, "Should be 0 after explicit settle in round 2");

        // Round 3: buy + sell
        _dexBuy(user3, token, 5_000 ether);
        _dexSell(user3, token, IERC20(token).balanceOf(user3) / 2);
        feeCollector.settle(pair, 0);
        assertEq(feeCollector.accumulatedFee(pair), 0, "Should be 0 after explicit settle in round 3");

        // Verify feeReceiver got funds across all rounds
        assertTrue(
            quoteToken.balanceOf(feeReceiver) > feeRecvBefore,
            "FeeReceiver should have received fees across multiple settlements"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // Settlement below threshold should be a no-op
    // ═══════════════════════════════════════════════════════════════

    function test_settleBelowThreshold_noOp() public {
        address token = _createToken();
        address pair = nadFunFactory.getPair(token, address(quoteToken));
        assertFalse(feeCollector.isSettleable(pair), "Should not be settleable with 0 fees");

        uint256 accBefore = feeCollector.accumulatedFee(pair);
        feeCollector.settle(pair, 0);
        assertEq(feeCollector.accumulatedFee(pair), accBefore, "Accumulated fee should be unchanged (no-op)");
    }

    // ═══════════════════════════════════════════════════════════════
    // Internal Helpers
    // ═══════════════════════════════════════════════════════════════

    function _dexBuy(address buyer, address token, uint256 quote) internal returns (uint256 tokenOut) {
        _mintAndApprove(buyer, address(nadFunRouter), quote);
        vm.prank(buyer);
        tokenOut = nadFunRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: quote, amountOutMin: 0, token: token, to: buyer, deadline: block.timestamp + 1
            })
        );
    }

    function _dexSell(address seller, address token, uint256 tokenAmount) internal returns (uint256 quoteOut) {
        vm.prank(seller);
        IERC20(token).approve(address(nadFunRouter), tokenAmount);
        vm.prank(seller);
        quoteOut = nadFunRouter.sell(
            INadFunRouter.SellParams({
                amountIn: tokenAmount, amountOutMin: 0, token: token, to: seller, deadline: block.timestamp + 1
            })
        );
    }
}
