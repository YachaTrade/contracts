// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for Graduation.

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {ILPManager} from "../../src/interfaces/ILPManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

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

    /// @notice Graduation allocates both permanent positions in the snapshotted canonical V3 pool.
    function test_graduation_allocatesCanonicalV3Liquidity() public {
        _mintAndTransfer(user1, 800_000 ether);
        vm.prank(user1);
        bondingCurve.buy(user1, token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Token should be graduated");

        ITokenRegistry.TokenInfo memory registryInfo = tokenRegistry.getTokenInfo(token);
        assertEq(registryInfo.pool, info.pair, "curve uses registry pool");
        assertEq(
            registryInfo.pool,
            v3Factory.getPool(token, address(quoteToken), registryInfo.feeTier),
            "factory uses registry fee snapshot"
        );
        (bytes32 quoteKey,,, uint128 quoteLiquidity, bytes32 tokenKey,,, uint128 tokenLiquidity) =
            lpManager.getPositions(token);
        assertNotEq(quoteKey, bytes32(0), "quote position exists");
        assertNotEq(tokenKey, bytes32(0), "token position exists");
        assertGt(quoteLiquidity, 0, "quote position has liquidity");
        assertGt(tokenLiquidity, 0, "token position has liquidity");
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

        ITokenRegistry.TokenInfo memory registryInfo = tokenRegistry.getTokenInfo(token);
        IUniswapV3Pool pool = IUniswapV3Pool(registryInfo.pool);
        bool quoteIsToken0 = pool.token0() == address(quoteToken);
        int24 expectedBondingTick = lpManager.calculateBondingTick(
            ILPManager.AllocateParams({
                token: token,
                quoteAmount: 0,
                tokenAmount: 0,
                virtualQuoteReserve: info.initialQuoteReserve,
                virtualTokenReserve: info.initialTokenReserve,
                graduateFee: defaultGraduateFee
            }),
            quoteIsToken0,
            pool.tickSpacing()
        );
        (, int24 quoteLower, int24 quoteUpper,,,,,) = lpManager.getPositions(token);
        assertEq(
            quoteIsToken0 ? quoteUpper : quoteLower,
            expectedBondingTick,
            "V3 bonding range should use snapshotted graduate fee"
        );
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
            dexType: ITokenRegistry.DexType.UniswapV3,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }
}
