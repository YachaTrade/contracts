// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for Graduation.

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";

/// @dev Minimal V2 pair interface for reserve checks
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice Verifies auto-graduation fires when virtualTokenReserve reaches minTokenReserve.
contract GraduationTest is SetUp {
    address vault;
    address token;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");

        vm.startPrank(admin);
        // Grant ROUTER_ROLE to test contract for direct bondingCurve.create() calls
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));
        vm.stopPrank();

        // Transfer deployFee to bondingCurve before create (balance detection)
        quoteToken.mint(address(this), defaultDeployFee);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee);
        // Create a token with graduation params
        (token,) = bondingCurve.create(_graduationParams());

        // Skip anti-sniping period
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    /// @notice Buying enough quote crosses graduation threshold -> graduation fires.
    /// @dev 700,000 ether is enough to buy down to minTokenReserve including fees
    function test_graduation_triggersOnThreshold() public {
        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Token should be graduated");
        assertLe(info.virtualTokenReserve, minTokenReserve, "Token reserve should reach min reserve");

        assertTrue(IToken(token).isGraduated(), "Token should be graduated");
    }

    /// @notice After graduation, buying via bonding curve reverts with AlreadyGraduated.
    function test_graduation_cantBuyAfter() public {
        // Graduate first
        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Precondition: token graduated");

        // Attempt another buy
        _mintAndTransfer(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(IBondingCurve.AlreadyGraduated.selector);
        bondingCurve.buy(user1, token);
    }

    /// @notice After graduation, selling via bonding curve reverts with AlreadyGraduated.
    function test_graduation_cantSellAfter() public {
        // Graduate first
        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        uint256 tokensOut = bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Precondition: token graduated");

        // Try to sell directly on BondingCurve after graduation — should revert
        vm.startPrank(user1);
        IERC20(token).transfer(address(bondingCurve), tokensOut);

        vm.expectRevert(IBondingCurve.AlreadyGraduated.selector);
        bondingCurve.sell(user1, token);
        vm.stopPrank();
    }

    /// @notice After graduation, bonding-curve quote helpers revert with AlreadyGraduated.
    function test_graduation_cantQuoteAfter() public {
        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Precondition: token graduated");

        vm.expectRevert(IBondingCurve.AlreadyGraduated.selector);
        bondingCurve.getAmountOut(token, 1 ether, true);

        vm.expectRevert(IBondingCurve.AlreadyGraduated.selector);
        bondingCurve.getAmountOut(token, 1 ether, false);

        vm.expectRevert(IBondingCurve.AlreadyGraduated.selector);
        bondingCurve.getAmountIn(token, 1 ether, true);

        vm.expectRevert(IBondingCurve.AlreadyGraduated.selector);
        bondingCurve.getAmountIn(token, 1 ether, false);
    }

    /// @notice DEX listing price should match bonding curve price at graduation.
    /// @dev After graduation, verifies the real V2 pair has liquidity with correct price ratio.
    function test_graduation_priceMatchesCurve() public {
        // Graduate
        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Token should be graduated");

        // Find the NadFunPair and verify reserves
        address pairAddr = nadFunFactory.getPair(token, address(quoteToken));
        assertNotEq(pairAddr, address(0), "V2 pair should exist after graduation");

        (uint256 tokenReserve, uint256 quoteReserve) = _getPairReserves(pairAddr, token);
        assertGt(tokenReserve, 0, "Token reserve should be non-zero");
        assertGt(quoteReserve, 0, "Quote reserve should be non-zero");

        // quoteBalance = real quote collected, then graduate fee deducted
        uint256 quoteAfterFee = (info.virtualQuoteReserve - info.initialQuoteReserve) - info.graduateFee;
        uint256 expectedListingTokens = quoteAfterFee * info.virtualTokenReserve / info.virtualQuoteReserve;

        assertEq(tokenReserve, expectedListingTokens, "Listing token amount should match graduation math");
        assertEq(quoteReserve, quoteAfterFee, "Listing quote amount should match graduation math");

        // DEX price should match curve price (same ratio)
        assertApproxEqAbs(
            tokenReserve * info.virtualQuoteReserve,
            quoteReserve * info.virtualTokenReserve,
            info.virtualQuoteReserve,
            "DEX listing price should match curve price"
        );
    }

    function test_graduation_usesCreationGraduateFeeSnapshot() public {
        IBondingCurve.Curve memory beforeInfo = bondingCurve.getCurve(token);
        assertEq(beforeInfo.graduateFee, defaultGraduateFee, "Precondition: graduate fee should be snapshotted");

        uint256 updatedGraduateFee = defaultGraduateFee * 2;
        vm.prank(admin);
        protocolManager.updateQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            updatedGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee,
            settlementThreshold
        );

        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Token should still graduate after config fee increase");
        assertEq(info.graduateFee, defaultGraduateFee, "Existing curve should keep creation-time graduate fee");

        address pairAddr = nadFunFactory.getPair(token, address(quoteToken));
        (, uint256 quoteReserve) = _getPairReserves(pairAddr, token);
        uint256 quoteAfterFee = (info.virtualQuoteReserve - info.initialQuoteReserve) - defaultGraduateFee;
        assertEq(quoteReserve, quoteAfterFee, "Graduation should use snapshotted graduate fee");
    }

    function test_updateQuoteToken_revertsWhenGraduateFeeExceedsGraduationQuote() public {
        vm.prank(admin);
        vm.expectRevert("Graduate fee too high");
        protocolManager.updateQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            1_000_000 ether,
            defaultCurveProtocolFee,
            defaultDexProtocolFee,
            settlementThreshold
        );
    }

    /// @dev Helper to get pair reserves in (tokenReserve, quoteReserve) order
    function _getPairReserves(address pairAddr, address tokenAddr)
        internal
        view
        returns (uint256 tokenReserve, uint256 quoteReserve)
    {
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddr);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (pair.token0() == tokenAddr) {
            return (uint256(r0), uint256(r1));
        } else {
            return (uint256(r1), uint256(r0));
        }
    }

    /// @notice Excess tokens should be sent to feeReceiver during graduation.
    function test_graduation_sendsExcessTokensToFeeReceiver() public {
        uint256 feeReceiverBalBefore = IERC20(token).balanceOf(protocolManager.feeReceiver());

        // Graduate
        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        // quoteAfterFee = realQuote - graduateFee
        uint256 quoteAfterFee = (info.virtualQuoteReserve - info.initialQuoteReserve) - info.graduateFee;
        uint256 listingTokens = quoteAfterFee * info.virtualTokenReserve / info.virtualQuoteReserve;

        // actualBalance at graduation = TOTAL_SUPPLY - (initialTokenReserve - minTokenReserve)
        // remaining = actualBalance - listingTokens
        uint256 tokensSoldVirtual = info.initialTokenReserve - info.virtualTokenReserve;
        uint256 actualBalanceAtGraduation = 1_000_000_000 ether - tokensSoldVirtual;
        uint256 expectedRemaining = actualBalanceAtGraduation - listingTokens;
        assertGe(
            IERC20(token).balanceOf(protocolManager.feeReceiver()) - feeReceiverBalBefore,
            expectedRemaining,
            "FeeReceiver should receive remaining tokens"
        );

        assertEq(IERC20(token).totalSupply(), 1_000_000_000 ether, "Total supply should remain unchanged");

        // BondingCurve should hold 0 tokens (all sent to LP or feeReceiver)
        assertEq(
            IERC20(token).balanceOf(address(bondingCurve)), 0, "BondingCurve should have 0 tokens after graduation"
        );
    }

    /// @notice Attacker donates quote tokens to the pre-created pair before graduation.
    ///         The donation must be swept to feeReceiver so the pool opens on a clean reserve
    ///         state and the launch price is not skewed.
    function test_graduation_sweepsDonatedQuoteToFeeReceiver() public {
        address pair = nadFunFactory.getPair(token, address(quoteToken));
        assertNotEq(pair, address(0), "Precondition: pair exists pre-graduation");

        // Attacker donates quote directly to the pair before graduation.
        uint256 donation = 1_234 ether;
        address attacker = makeAddr("attacker");
        quoteToken.mint(attacker, donation);
        vm.prank(attacker);
        quoteToken.transfer(pair, donation);

        assertEq(quoteToken.balanceOf(pair), donation, "Precondition: pair holds donation");

        uint256 feeReceiverBefore = quoteToken.balanceOf(protocolManager.feeReceiver());

        // Trigger graduation
        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Token should be graduated");

        // Pair's quote reserve should equal graduation-computed amount, with no donation residue
        (, uint256 quoteReserve) = _getPairReserves(pair, token);
        uint256 quoteAfterFee = (info.virtualQuoteReserve - info.initialQuoteReserve) - info.graduateFee;
        assertEq(quoteReserve, quoteAfterFee, "Pair quote reserve must match graduation math (donation not counted)");

        // feeReceiver picks up the donation as part of its post-graduation balance delta.
        // (feeReceiver also receives graduateFee and excess tokens, but the donation should be
        // *at least* included in its quote balance increase.)
        uint256 feeReceiverDelta = quoteToken.balanceOf(protocolManager.feeReceiver()) - feeReceiverBefore;
        assertGe(feeReceiverDelta, donation, "FeeReceiver should recover the donation");
    }

    /// @notice Attacker tries to defeat the pre-addLiquidity skim by donating quote and calling
    ///         `pair.sync()`, so reserves absorb the donation and `skim()` would be a no-op.
    ///         `sync()` must revert pre-launch (totalSupply == 0), preserving the skim defense.
    function test_graduation_sync_revertsPreLaunch() public {
        address pair = nadFunFactory.getPair(token, address(quoteToken));

        uint256 donation = 100 ether;
        address attacker = makeAddr("attacker");
        quoteToken.mint(attacker, donation);
        vm.startPrank(attacker);
        quoteToken.transfer(pair, donation);
        vm.expectRevert("NadFunPair: NOT_LAUNCHED");
        INadFunPair(pair).sync();
        vm.stopPrank();

        // Graduation should still sweep the donation cleanly via skim.
        uint256 feeReceiverBefore = quoteToken.balanceOf(protocolManager.feeReceiver());
        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Token should be graduated");
        (, uint256 quoteReserve) = _getPairReserves(pair, token);
        uint256 quoteAfterFee = (info.virtualQuoteReserve - info.initialQuoteReserve) - info.graduateFee;
        assertEq(quoteReserve, quoteAfterFee, "Pair quote reserve must match graduation math");
        assertGe(
            quoteToken.balanceOf(protocolManager.feeReceiver()) - feeReceiverBefore,
            donation,
            "FeeReceiver should recover the donation"
        );
    }

    function _graduationParams() internal view returns (IBondingCurve.CreateTokenParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});

        params = IBondingCurve.CreateTokenParams({
            name: "GradToken",
            symbol: "GRAD",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: keccak256("graduation"),
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }
}
