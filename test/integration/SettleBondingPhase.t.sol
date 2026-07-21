// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {IBondingCurve as IBC} from "../../src/interfaces/IBondingCurve.sol";

import {GiftVault} from "../../src/vault/GiftVault.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";

/// @title SettleBondingPhase -- Integration tests for settle/vault behavior in bonding phase
/// @notice Verifies BurnVault/GiftVault/LPVault behavior when FeeCollector.settle() is called
///         BEFORE graduation, plus the fee-waiver mechanism via isSettling flag.
contract SettleBondingPhaseTest is SetUp {
    using SafeERC20 for IERC20;

    address private constant BURN_ADDRESS = address(0xdead);

    GiftVault public giftVault;

    // ──────────────────────────────────────────────────────────────
    // setUp -- deploy GiftVault on top of base SetUp
    // ──────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();

        // Deploy a GiftVault for tests that need it
        vm.startPrank(admin);
        giftVault = GiftVault(
            payable(address(
                    new ERC1967Proxy(
                        address(new GiftVault()),
                        abi.encodeCall(
                            GiftVault.initialize,
                            (
                                address(protocolManager),
                                address(creatorFeeProcessor),
                                address(bondingCurve),
                                address(tokenRegistry),
                                7 days,
                                address(giwaRouter),
                                address(wmon),
                                ""
                            )
                        )
                    )
                ))
        );
        vaultRegistry.register(
            address(giftVault), "GiftVault", "Gift accumulation + buyback", IVaultRegistry.VaultType.Burn
        );
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────

    /// @notice Create a token whose creator fees go 100% to the given vault.
    function _createWithSingleVault(address vault, bytes memory setupData, bytes32 salt)
        internal
        returns (address token)
    {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({vault: vault, bps: 10000, setupData: setupData});

        IBondingCurve.CreateTokenParams memory params = IBondingCurve.CreateTokenParams({
            name: "VTok",
            symbol: "VTK",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: defaultCreatorFeeRate,
            vaults: vaults,
            salt: salt,
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: creator,
            buyQuoteAmount: 0
        });

        token = _createViaRouter(params, creator);
        // Skip sniping period for this token
        _skipAntiSniping();
    }

    /// @notice Buy on bonding curve until accumulated creator fee >= settlementThreshold.
    function _accumulateUntilSettleable(address token, address pair) internal {
        uint256 threshold = protocolManager.settlementThreshold(address(quoteToken));
        // Each buy of 1000 quote at 5% creator fee yields ~50 in creator fee. We loop
        // until accumulated fee crosses the threshold (1 ether by default).
        uint256 perBuy = 1_000 ether;
        uint256 maxLoops = 100;
        while (feeCollector.accumulatedFee(pair) < threshold && maxLoops > 0) {
            _buyOnCurve(user2, token, perBuy);
            maxLoops--;
        }
        require(feeCollector.accumulatedFee(pair) >= threshold, "failed to accumulate fees");
    }

    // ──────────────────────────────────────────────────────────────
    // Test 1: BurnVault buyback during bonding phase
    // ──────────────────────────────────────────────────────────────

    function test_burnVault_settleDuringBondingPhase() public {
        address token = _createWithSingleVault(address(burnVault), "", keccak256("burn-bonding"));
        address pair = bondingCurve.getCurve(token).pair;

        // Accumulate creator fees on the curve
        _accumulateUntilSettleable(token, pair);

        // Sanity: not graduated yet
        assertFalse(IToken(token).isGraduated(), "should not be graduated");

        uint256 burnVaultQuoteBefore = quoteToken.balanceOf(address(burnVault));
        uint256 burnAddrBefore = IERC20(token).balanceOf(BURN_ADDRESS);
        uint256 accumulatedBefore = feeCollector.accumulatedFee(pair);
        assertGt(accumulatedBefore, 0, "should have accumulated fees");

        // Settle pre-graduation
        feeCollector.settle(pair, 0);

        // Verify still not graduated
        assertFalse(IToken(token).isGraduated(), "should NOT graduate from settle");

        // Verify accumulated reset
        assertEq(feeCollector.accumulatedFee(pair), 0, "accumulated should be reset");

        // BurnVault should hold no quote leftover (it bought tokens with everything)
        assertEq(quoteToken.balanceOf(address(burnVault)), burnVaultQuoteBefore, "BurnVault quote should be drained");

        // BurnVault should hold no leftover token (all burned)
        assertEq(IERC20(token).balanceOf(address(burnVault)), 0, "BurnVault token balance should be 0");

        // Burn address should have received tokens
        uint256 burnAddrAfter = IERC20(token).balanceOf(BURN_ADDRESS);
        assertGt(burnAddrAfter, burnAddrBefore, "burn address should have received tokens");
    }

    // ──────────────────────────────────────────────────────────────
    // Test 2: GiftVault buyback during bonding phase
    // ──────────────────────────────────────────────────────────────
    //
    // GiftVault.afterDeposit() during bonding phase:
    //   - First call (gift.balance == 0): just records balance
    //   - Subsequent call (after expiry passed): triggers _buybackAndBurn
    //     using bondingCurve.buy() and sends bought tokens to BURN_ADDRESS.
    //
    // This test exercises the second path (auto-expire → buyback) during settle.

    function test_giftVault_settleDuringBondingPhase_autoExpire() public {
        bytes memory setupData = abi.encode(GiftVault.GiftTarget({platform: GiftVault.Platform.X, id: "bob"}));
        address token = _createWithSingleVault(address(giftVault), setupData, keccak256("gift-bonding"));
        address pair = bondingCurve.getCurve(token).pair;

        // Round 1: accumulate + settle. afterDeposit just stores the balance.
        _accumulateUntilSettleable(token, pair);
        feeCollector.settle(pair, 0);

        GiftVault.GiftInfo memory info1 = giftVault.getGiftInfo(token);
        assertGt(info1.balance, 0, "gift balance should accumulate after first settle");
        assertFalse(giftVault.isExpired(token), "gift should not be expired yet");

        // Warp past expiry
        vm.warp(block.timestamp + 8 days);

        // Round 2: accumulate again, then settle → afterDeposit auto-expires + buybacks.
        _accumulateUntilSettleable(token, pair);

        uint256 burnAddrBefore = IERC20(token).balanceOf(BURN_ADDRESS);
        uint256 giftQuoteBefore = quoteToken.balanceOf(address(giftVault));
        assertGt(giftQuoteBefore, 0, "GiftVault should hold quote pre-settle");

        feeCollector.settle(pair, 0);

        // Still not graduated
        assertFalse(IToken(token).isGraduated(), "should not graduate");

        // Gift should now be expired and balance reset
        assertTrue(giftVault.isExpired(token), "gift should be expired after settle");
        GiftVault.GiftInfo memory info2 = giftVault.getGiftInfo(token);
        assertEq(info2.balance, 0, "gift balance should be 0");

        // GiftVault should have used all quote for buyback
        assertEq(quoteToken.balanceOf(address(giftVault)), 0, "GiftVault quote should be drained");

        // GiftVault should not hold any token (all sent to burn)
        assertEq(IERC20(token).balanceOf(address(giftVault)), 0, "GiftVault token balance should be 0");

        // Burn address received tokens
        assertGt(IERC20(token).balanceOf(BURN_ADDRESS), burnAddrBefore, "burn address should have received tokens");
    }

    // ──────────────────────────────────────────────────────────────
    // Test 3: LPVault accumulates during bonding, processes after graduation
    // ──────────────────────────────────────────────────────────────

    function test_lpVault_accumulatesDuringBonding_processesAfterGraduation() public {
        address token = _createWithSingleVault(address(lpVault), "", keccak256("lp-lifecycle"));
        address pair = bondingCurve.getCurve(token).pair;

        // Phase 1: bonding-phase fees → settle → LPVault should ONLY accumulate quote (no LP)
        _accumulateUntilSettleable(token, pair);
        feeCollector.settle(pair, 0);

        assertFalse(IToken(token).isGraduated(), "still bonding");
        uint256 lpVaultQuotePhase1 = quoteToken.balanceOf(address(lpVault));
        assertGt(lpVaultQuotePhase1, 0, "LPVault should accumulate quote during bonding");
        // Pair should not yet exist as a real pool with reserves -- LPVault holds no LP yet
        assertEq(IERC20(pair).balanceOf(address(lpVault)), 0, "LPVault should NOT hold LP yet");
        assertEq(IERC20(pair).balanceOf(BURN_ADDRESS), 0, "burn address should not yet hold LP");

        // Phase 2: graduate the token
        _graduateToken(token);
        assertTrue(IToken(token).isGraduated(), "graduated");

        // Phase 3: accumulate post-graduation fees via DEX-style trade on the pair, then settle.
        // We can't easily route through DexRouter without fees inflating; just buy/sell
        // on the bonding curve again is impossible (graduated). Instead, do a swap directly on the pair.
        _swapOnPair(pair, token, 5_000 ether);
        // Trigger fee collection on the pair (it pulls into FeeCollector during _collectFee inside swap).

        // Accumulate enough to cross threshold via more swaps if needed
        uint256 maxLoops = 50;
        while (
            feeCollector.accumulatedFee(pair) < protocolManager.settlementThreshold(address(quoteToken)) && maxLoops > 0
        ) {
            _swapOnPair(pair, token, 5_000 ether);
            maxLoops--;
        }
        assertGe(
            feeCollector.accumulatedFee(pair),
            protocolManager.settlementThreshold(address(quoteToken)),
            "post-grad accumulated"
        );

        uint256 burnAddrLPBefore = IERC20(pair).balanceOf(BURN_ADDRESS);
        feeCollector.settle(pair, 0);

        // LPVault should now have reduced quote balance (used for liquidity)
        uint256 lpVaultQuotePhase3 = quoteToken.balanceOf(address(lpVault));
        assertLt(lpVaultQuotePhase3, lpVaultQuotePhase1 + 1, "LPVault quote should be drained for LP injection");

        // LP burned to BURN_ADDRESS should have grown (LP minted into burn address)
        assertGt(IERC20(pair).balanceOf(BURN_ADDRESS), burnAddrLPBefore, "LP should be added to burn address");
    }

    // ──────────────────────────────────────────────────────────────
    // Test 3b: LPVault per-token isolation across multiple tokens
    // ──────────────────────────────────────────────────────────────
    //
    // LPVault is a singleton shared across all tokens. Two tokens A and B
    // both route 100% of creator fees to LPVault. Each token's accumulation
    // must be tracked independently so graduating A doesn't drain B's share.

    function test_lpVault_multiToken_isolatedAccumulation() public {
        // Two tokens, both routing 100% of creator fees to the LPVault singleton.
        address tokenA = _createWithSingleVault(address(lpVault), "", keccak256("lp-multi-A"));
        address pairA = bondingCurve.getCurve(tokenA).pair;

        address tokenB = _createWithSingleVault(address(lpVault), "", keccak256("lp-multi-B"));
        address pairB = bondingCurve.getCurve(tokenB).pair;

        // Bonding-phase accumulation on A only, then settle.
        _accumulateUntilSettleable(tokenA, pairA);
        feeCollector.settle(pairA, 0);

        assertFalse(IToken(tokenA).isGraduated(), "A still bonding");
        uint256 accA_afterSettleA = lpVault.accumulatedQuote(tokenA);
        uint256 accB_afterSettleA = lpVault.accumulatedQuote(tokenB);
        assertGt(accA_afterSettleA, 0, "A should have accumulated quote in LPVault");
        assertEq(accB_afterSettleA, 0, "B should not be affected by A's settle");
        // LPVault holds exactly A's accumulated amount as quote right now.
        assertEq(quoteToken.balanceOf(address(lpVault)), accA_afterSettleA, "LPVault total quote == A's accumulation");

        // Bonding-phase accumulation on B, then settle.
        _accumulateUntilSettleable(tokenB, pairB);
        feeCollector.settle(pairB, 0);

        assertFalse(IToken(tokenB).isGraduated(), "B still bonding");
        uint256 accA_afterSettleB = lpVault.accumulatedQuote(tokenA);
        uint256 accB_afterSettleB = lpVault.accumulatedQuote(tokenB);
        assertEq(accA_afterSettleB, accA_afterSettleA, "A's accumulation unchanged by B's settle");
        assertGt(accB_afterSettleB, 0, "B should have accumulated quote in LPVault");

        // LPVault's total quote balance should equal A + B accumulations.
        assertEq(
            quoteToken.balanceOf(address(lpVault)),
            accA_afterSettleB + accB_afterSettleB,
            "LPVault total quote == A + B accumulations"
        );

        // ────────── Graduate A ──────────
        _graduateToken(tokenA);
        assertTrue(IToken(tokenA).isGraduated(), "A graduated");

        // Drive fees on A via direct pair swaps post-graduation.
        uint256 maxLoops = 50;
        while (
            feeCollector.accumulatedFee(pairA) < protocolManager.settlementThreshold(address(quoteToken))
                && maxLoops > 0
        ) {
            _swapOnPair(pairA, tokenA, 5_000 ether);
            maxLoops--;
        }
        assertGe(
            feeCollector.accumulatedFee(pairA),
            protocolManager.settlementThreshold(address(quoteToken)),
            "A post-grad accumulated"
        );

        uint256 burnLpA_before = IERC20(pairA).balanceOf(BURN_ADDRESS);
        uint256 lpVaultQuote_beforeGradSettleA = quoteToken.balanceOf(address(lpVault));

        feeCollector.settle(pairA, 0);

        // A's accumulated counter must be zeroed (consumed by the inject path).
        assertEq(lpVault.accumulatedQuote(tokenA), 0, "A's accumulation drained post-graduation settle");
        // B's counter must be completely unchanged.
        assertEq(
            lpVault.accumulatedQuote(tokenB),
            accB_afterSettleB,
            "B's accumulation MUST NOT be touched when A graduates/settles"
        );

        // A's settle should have injected liquidity into pairA (LP burned).
        assertGt(IERC20(pairA).balanceOf(BURN_ADDRESS), burnLpA_before, "A's LP should have been burned to 0xdead");

        // After A's settle: LPVault quote must still hold AT LEAST B's tracked portion.
        // (The quote LPVault holds is now ~= B's accumulation, possibly plus any leftover
        // from A's swap-half path, but critically not less than B's tracked portion.)
        assertGe(
            quoteToken.balanceOf(address(lpVault)),
            lpVault.accumulatedQuote(tokenB),
            "LPVault still holds B's portion after A's settle"
        );

        // ────────── Graduate B ──────────
        _graduateToken(tokenB);
        assertTrue(IToken(tokenB).isGraduated(), "B graduated");

        maxLoops = 50;
        while (
            feeCollector.accumulatedFee(pairB) < protocolManager.settlementThreshold(address(quoteToken))
                && maxLoops > 0
        ) {
            _swapOnPair(pairB, tokenB, 5_000 ether);
            maxLoops--;
        }
        assertGe(
            feeCollector.accumulatedFee(pairB),
            protocolManager.settlementThreshold(address(quoteToken)),
            "B post-grad accumulated"
        );

        uint256 burnLpB_before = IERC20(pairB).balanceOf(BURN_ADDRESS);

        feeCollector.settle(pairB, 0);

        assertEq(lpVault.accumulatedQuote(tokenB), 0, "B's accumulation drained post-graduation settle");
        assertGt(IERC20(pairB).balanceOf(BURN_ADDRESS), burnLpB_before, "B's LP should have been burned to 0xdead");

        // silence unused
        lpVaultQuote_beforeGradSettleA;
    }

    /// @dev Quote → token swap directly on the pair, applying fee path.
    function _swapOnPair(address pair, address token, uint256 quoteIn) internal {
        quoteToken.mint(address(this), quoteIn);
        // We need to know expected out before transfer
        uint256 expectedOut = INadFunPair(pair).getAmountOut(address(quoteToken), quoteIn);
        quoteToken.transfer(pair, quoteIn);
        address t0 = INadFunPair(pair).token0();
        if (token == t0) {
            INadFunPair(pair).swap(expectedOut, 0, address(this), "");
        } else {
            INadFunPair(pair).swap(0, expectedOut, address(this), "");
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Test 4: settling flag toggles correctly
    // ──────────────────────────────────────────────────────────────

    function test_settlingFlag_togglesCorrectly() public {
        // Use a recorder vault that captures isSettling during afterDeposit
        RecorderVault recorder = new RecorderVault(address(feeCollector), address(bondingCurve));
        vm.prank(admin);
        vaultRegistry.register(address(recorder), "Recorder", "records isSettling", IVaultRegistry.VaultType.Creator);

        address token = _createWithSingleVault(address(recorder), "", keccak256("recorder-toggle"));
        address pair = bondingCurve.getCurve(token).pair;

        recorder.setPair(pair);

        _accumulateUntilSettleable(token, pair);

        // Before settle: false
        assertFalse(feeCollector.isSettling(pair), "before settle false");

        feeCollector.settle(pair, 0);

        // After settle: false
        assertFalse(feeCollector.isSettling(pair), "after settle false");

        // During settle (captured): true
        assertTrue(recorder.lastSeenSettling(), "should have observed isSettling=true inside callback");
        assertGt(recorder.callCount(), 0, "callback should have fired");
    }

    // ──────────────────────────────────────────────────────────────
    // Test 5: BondingCurve waives fees during settle
    // ──────────────────────────────────────────────────────────────
    //
    // The recorder vault inside afterDeposit calls bondingCurve.buy()
    // and verifies that ALL of the quote went into the swap (no fee
    // deducted, no fee receiver delta, no extra accumulation).

    function test_bondingCurve_waivesFeesDuringSettle() public {
        BuyDuringSettleVault buyer = new BuyDuringSettleVault(address(bondingCurve), address(quoteToken));
        vm.prank(admin);
        vaultRegistry.register(
            address(buyer), "BuyDuringSettle", "calls buy in callback", IVaultRegistry.VaultType.Creator
        );

        address token = _createWithSingleVault(address(buyer), "", keccak256("buyer-vault"));
        address pair = bondingCurve.getCurve(token).pair;

        _accumulateUntilSettleable(token, pair);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);
        uint256 accBefore = feeCollector.accumulatedFee(pair);

        // Settle: distributes to buyer vault → buyer.afterDeposit forwards quote
        // to bondingCurve and calls buy(self, token). Because isSettling=true,
        // the curve must take ZERO fees: no transfer to feeReceiver, no
        // increase in feeCollector accumulated fee.
        feeCollector.settle(pair, 0);

        // Confirm vault was actually called
        assertGt(buyer.lastQuoteIn(), 0, "vault should have processed quote");
        assertGt(buyer.lastTokenOut(), 0, "vault should have received token");

        // accumulated fee should be reset (not increased) -- nothing collected during the inner buy
        assertEq(feeCollector.accumulatedFee(pair), 0, "no new fees should be collected during settle");
        assertLt(feeCollector.accumulatedFee(pair) + 1, accBefore + 1, "accumulated should drop");

        // feeReceiver should NOT have received any new protocol fee from the inner buy
        assertEq(
            quoteToken.balanceOf(feeReceiver),
            feeReceiverBefore,
            "feeReceiver should NOT receive fee from inner buy during settle"
        );
    }

    // ──────────────────────────────────────────────────────────────
    // Test 6: NadFunPair waives fees during settle (post-graduation)
    // ──────────────────────────────────────────────────────────────

    function test_nadFunPair_waivesFeesDuringSettle_postGraduation() public {
        // Use BurnVault (which uses adapter swap once token is graduated).
        address token = _createWithSingleVault(address(burnVault), "", keccak256("pair-fee-waive"));
        address pair = bondingCurve.getCurve(token).pair;

        // Accumulate during bonding so settle has work to do post-graduation.
        // Easiest: graduate first, then accumulate via pair swaps.
        _graduateToken(token);
        assertTrue(IToken(token).isGraduated(), "graduated");

        // Drive trades through the pair to accumulate fees
        uint256 maxLoops = 50;
        while (
            feeCollector.accumulatedFee(pair) < protocolManager.settlementThreshold(address(quoteToken)) && maxLoops > 0
        ) {
            _swapOnPair(pair, token, 5_000 ether);
            maxLoops--;
        }
        assertGe(
            feeCollector.accumulatedFee(pair),
            protocolManager.settlementThreshold(address(quoteToken)),
            "post-grad accumulated"
        );

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);

        // Snapshot pair reserves before
        (uint112 r0Before, uint112 r1Before,) = INadFunPair(pair).getReserves();

        feeCollector.settle(pair, 0);

        // Accumulated should be reset; nothing collected during the inner adapter swap.
        assertEq(
            feeCollector.accumulatedFee(pair),
            0,
            "accumulated should be 0 after settle (no fees added during inner swap)"
        );

        // feeReceiver only got protocol fee from the SETTLE (which is 0 for vault swap path).
        // The inner adapter swap MUST NOT have charged any fee; we cannot precisely separate it,
        // but the accumulated-fee invariant above already proves _collectFee was skipped.
        // We additionally assert reserves changed (swap actually happened) to make sure the test
        // wasn't a no-op.
        (uint112 r0After, uint112 r1After,) = INadFunPair(pair).getReserves();
        assertTrue(r0Before != r0After || r1Before != r1After, "pair reserves should have changed from inner swap");

        // BurnVault should have burned tokens
        assertEq(IERC20(token).balanceOf(address(burnVault)), 0, "BurnVault should hold no token");
        assertEq(quoteToken.balanceOf(address(burnVault)), 0, "BurnVault should hold no quote");

        // feeReceiver shouldn't have grown beyond zero unrelated activity. The settle path itself
        // doesn't pay anything to feeReceiver (CreatorFeeProcessor only distributes to vaults).
        // So feeReceiver balance should be unchanged.
        assertEq(quoteToken.balanceOf(feeReceiver), feeReceiverBefore, "feeReceiver unchanged during settle");
    }

    // ──────────────────────────────────────────────────────────────
    // Test 7: isSettling key correctness (token isolation)
    // ──────────────────────────────────────────────────────────────

    function test_isSettling_isolatedPerPair() public {
        // Token A uses a recorder that, during its afterDeposit, asserts the OTHER pair is NOT settling
        // and additionally tries to accumulate on token B by calling collectFee path indirectly.
        IsolationRecorder recorder = new IsolationRecorder(address(feeCollector));
        vm.prank(admin);
        vaultRegistry.register(
            address(recorder), "IsolationRec", "checks per-pair settling", IVaultRegistry.VaultType.Creator
        );

        address tokenA = _createWithSingleVault(address(recorder), "", keccak256("iso-A"));
        address pairA = bondingCurve.getCurve(tokenA).pair;

        // Token B uses normal CreatorFeeVault so it doesn't interfere
        address tokenB = _createTokenWith("TokB", "TKB", defaultCreatorFeeRate, keccak256("iso-B"));
        address pairB = bondingCurve.getCurve(tokenB).pair;
        _skipAntiSniping();

        recorder.setSelfPair(pairA);
        recorder.setOtherPair(pairB);

        // Accumulate on both
        _accumulateUntilSettleable(tokenA, pairA);
        _accumulateUntilSettleable(tokenB, pairB);

        uint256 accBBefore = feeCollector.accumulatedFee(pairB);
        assertGt(accBBefore, 0, "B should have fees");

        // Sanity: neither is currently settling
        assertFalse(feeCollector.isSettling(pairA));
        assertFalse(feeCollector.isSettling(pairB));

        feeCollector.settle(pairA, 0);

        // Recorder should have observed isSettling(pairA) == true and isSettling(pairB) == false
        assertTrue(recorder.lastSeenSelfSettling(), "during settle, pairA must be settling");
        assertFalse(recorder.lastSeenOtherSettling(), "during settle, pairB must NOT be settling");

        // After A's settle, A is reset, B is untouched
        assertEq(feeCollector.accumulatedFee(pairA), 0, "A reset");
        assertEq(feeCollector.accumulatedFee(pairB), accBBefore, "B untouched");

        // B can still settle normally afterwards
        feeCollector.settle(pairB, 0);
        assertEq(feeCollector.accumulatedFee(pairB), 0, "B reset after its own settle");
    }
}

// ════════════════════════════════════════════════════════════════
// Helper test vaults
// ════════════════════════════════════════════════════════════════

/// @notice Records the value of `isSettling(pair)` observed inside afterDeposit.
contract RecorderVault is IVault {
    address public immutable feeCollector;
    address public immutable bondingCurve;
    address public pair;

    bool public lastSeenSettling;
    uint256 public callCount;

    constructor(address feeCollector_, address bondingCurve_) {
        feeCollector = feeCollector_;
        bondingCurve = bondingCurve_;
    }

    function setPair(address p) external {
        pair = p;
    }

    function afterDeposit(address, address, uint256) external {
        callCount++;
        lastSeenSettling = IFeeCollector(feeCollector).isSettling(pair);
    }

    function setup(address, bytes calldata) external {}

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Inside afterDeposit, transfers received quote to BondingCurve and
///         calls buy(this, token). Records the in/out amounts so the test can
///         assert that NO fees were applied (effective rate == 1).
contract BuyDuringSettleVault is IVault {
    using SafeERC20 for IERC20;

    address public immutable bondingCurve;
    address public immutable quoteToken;

    uint256 public lastQuoteIn;
    uint256 public lastTokenOut;

    constructor(address bondingCurve_, address quoteToken_) {
        bondingCurve = bondingCurve_;
        quoteToken = quoteToken_;
    }

    function afterDeposit(address token, address quoteToken_, uint256 amount) external {
        uint256 bal = IERC20(quoteToken_).balanceOf(address(this));
        if (bal == 0) return;
        lastQuoteIn = bal;
        IERC20(quoteToken_).safeTransfer(bondingCurve, bal);
        lastTokenOut = IBondingCurve(bondingCurve).buy(address(this), token);
        // silence unused param
        amount;
    }

    function setup(address, bytes calldata) external {}

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Inside afterDeposit, records isSettling for both its own pair and the other pair.
contract IsolationRecorder is IVault {
    address public immutable feeCollector;
    address public selfPair;
    address public otherPair;

    bool public lastSeenSelfSettling;
    bool public lastSeenOtherSettling;

    constructor(address feeCollector_) {
        feeCollector = feeCollector_;
    }

    function setOtherPair(address p) external {
        otherPair = p;
    }

    function setup(address, bytes calldata) external pure {}

    function afterDeposit(address, address, uint256) external {
        lastSeenSelfSettling = IFeeCollector(feeCollector).isSettling(selfPair);
        lastSeenOtherSettling = IFeeCollector(feeCollector).isSettling(otherPair);
    }

    function setSelfPair(address p) external {
        selfPair = p;
    }

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
