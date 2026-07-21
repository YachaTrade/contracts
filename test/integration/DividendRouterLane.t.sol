// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {DividendVault} from "../../src/vault/DividendVault.sol";
import {IDividendVault} from "../../src/interfaces/IDividendVault.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {MockBondingCurveV1} from "../mocks/MockBondingCurveV1.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DividendRouterLane — DividendVault conversions through the REAL NadFunRouter
/// @notice Covers what the unit suite's MockNadFunRouter cannot (docs/plans/
///         2026-06-13-dividend-router-lane-design.md §4): real exact-in fee economics on the
///         bonding curve, the graduated path through router._dexSwap → real NadFunPair (which
///         depends on TokenRegistry's DexType.UniswapV2 == NadSwapAdapter), the real full-pull-
///         then-refund at the graduation cap, and the real revert for tokens the router cannot
///         resolve — replacing the deleted executeBondingBuy admission-guard tests. The vault
///         calls the REAL router directly via executeConversion's router hop branch.
contract DividendRouterLaneTest is SetUp {
    DividendVault public vault;
    MockBondingCurveV1 public bondingCurveV1;

    address public sourceToken;
    address public operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        bondingCurveV1 = new MockBondingCurveV1();

        vault = DividendVault(
            payable(address(
                    new ERC1967Proxy(
                        address(new DividendVault()),
                        abi.encodeCall(
                            DividendVault.initialize,
                            (
                                address(protocolManager),
                                address(tokenRegistry),
                                address(this), // creatorFeeProcessor: tests drive afterDeposit directly
                                address(bondingCurve), // the REAL curve gates setup()
                                address(nadFunRouter), // V2 conversion target (executeConversion router hop)
                                address(bondingCurveV1),
                                ""
                            )
                        )
                    )
                ))
        );

        vm.startPrank(admin);
        protocolManager.setOperatorPermission(address(this), address(vault), DividendVault.setAdapters.selector, true);
        protocolManager.setOperatorPermission(
            address(this), address(vault), DividendVault.setAllowedDividendToken.selector, true
        );
        protocolManager.setOperatorPermission(operator, address(vault), DividendVault.executeConversion.selector, true);
        vm.stopPrank();

        // Wire the protocol's nadSwapAdapter (general NadFunPair lane); uni lanes unused here. The
        // router hop needs no lane wiring. These tests exercise router-hop V2 buys.
        vault.setAdapters(address(nadSwapAdapter), address(0), address(0));

        // The dividend-enabled source token — a real V2 token so getQuoteToken resolves on-chain.
        sourceToken = _createToken();
    }

    function _setupDividend(address dividendToken) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = dividendToken;
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10000;
        vm.prank(address(bondingCurve));
        vault.setup(sourceToken, abi.encode(tokens, ratios, uint256(0)));
    }

    function _deposit(uint256 amount) internal {
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(sourceToken, address(quoteToken), amount);
    }

    /// @dev Single router hop: adapter == the router (the executeConversion branch sentinel),
    ///      tokenOut == the V2 token to buy. `pair` is unused by the router branch.
    function _routerOrder(address dividendToken, uint256 quoteIn, uint256 amountOutMin)
        internal
        view
        returns (IDividendVault.ConversionOrder[] memory orders)
    {
        IDividendVault.ConversionHop[] memory path = new IDividendVault.ConversionHop[](1);
        path[0] = IDividendVault.ConversionHop({
            adapter: IDexAdapter(address(nadFunRouter)), pair: address(0), tokenOut: dividendToken
        });
        orders = new IDividendVault.ConversionOrder[](1);
        orders[0] = IDividendVault.ConversionOrder({
            sourceToken: sourceToken,
            dividendToken: dividendToken,
            path: path,
            quoteIn: quoteIn,
            amountOutMin: amountOutMin
        });
    }

    // ── bonding (pre-graduation) buy with real exact-in fee economics ────

    function test_routerLane_bondingBuy_realExactInEconomics() public {
        address dividendToken = _createTokenWith("Dividend", "DIV", defaultCreatorFeeRate, keccak256("div-bonding"));
        _skipAntiSniping(); // fresh token — drop the per-block sniping fee from the quote
        _setupDividend(dividendToken);
        _deposit(10 ether);

        uint256 expectedOut = nadFunRouter.getAmountOut(dividendToken, 10 ether, true);
        assertGt(expectedOut, 0, "live curve must quote a positive buy");

        vm.prank(operator);
        vault.executeConversion(_routerOrder(dividendToken, 10 ether, expectedOut));

        assertEq(vault.pendingSwap(sourceToken, dividendToken), 0, "full consume far from the graduation cap");
        assertEq(vault.dividendBalance(sourceToken, dividendToken), expectedOut, "credited the real curve output");
        assertEq(IERC20(dividendToken).balanceOf(address(vault)), expectedOut, "vault holds the bought tokens");
        assertEq(quoteToken.balanceOf(address(nadFunRouter)), 0, "router is non-custodial - no quote stranded");
    }

    // ── graduated buy through the SAME lane (router._dexSwap → real NadFunPair) ──

    function test_routerLane_graduatedToken_buysThroughDex() public {
        address dividendToken = _createTokenWith("Graduated", "GRAD", defaultCreatorFeeRate, keccak256("div-grad"));
        _skipAntiSniping(); // fresh token — the graduating buy must not pay the sniping penalty
        _graduateToken(dividendToken);
        assertTrue(IToken(dividendToken).isGraduated(), "precondition: dividend token graduated");
        _setupDividend(dividendToken);
        _deposit(10 ether);

        // Same hop shape as the bonding case — graduation dispatch is the router's concern.
        // This path exercises router._dexSwap, which resolves TokenRegistry's DexType.UniswapV2
        // adapter (NadSwapAdapter) and swaps on the real NadFunPair.
        uint256 expectedOut = nadFunRouter.getAmountOut(dividendToken, 10 ether, true);
        vm.prank(operator);
        vault.executeConversion(_routerOrder(dividendToken, 10 ether, expectedOut));

        uint256 received = IERC20(dividendToken).balanceOf(address(vault));
        assertGe(received, expectedOut, "DEX output meets the quoted minimum");
        assertEq(vault.dividendBalance(sourceToken, dividendToken), received, "credited the real balance delta");
        assertEq(vault.pendingSwap(sourceToken, dividendToken), 0, "DEX swaps consume the full quoteIn");
        assertEq(quoteToken.balanceOf(address(nadFunRouter)), 0, "router is non-custodial - no quote stranded");
    }

    // ── graduation-cap crossing: the real full-pull-then-refund path ─────

    function test_routerLane_graduationCapCrossing_keepsRefundPending() public {
        address dividendToken = _createTokenWith("CapCross", "CAP", defaultCreatorFeeRate, keccak256("div-cap"));
        _skipAntiSniping();
        _setupDividend(dividendToken);

        // Far more than the ~800k quote needed to graduate — the router computes the exact-in
        // up to the cap, pulls the full amountIn, and refunds the excess directly to the vault
        // (msg.sender) for the partial-fill pending accounting.
        uint256 deposit = 900_000 ether;
        _deposit(deposit);

        vm.prank(operator);
        vault.executeConversion(_routerOrder(dividendToken, deposit, 1));

        assertTrue(IToken(dividendToken).isGraduated(), "the buy itself crossed the graduation cap");
        uint256 refunded = quoteToken.balanceOf(address(vault));
        assertGt(refunded, 0, "cap-crossing buy must refund the unconsumed quote");
        assertEq(vault.pendingSwap(sourceToken, dividendToken), refunded, "refund stays pending for a later order");
        assertGt(vault.dividendBalance(sourceToken, dividendToken), 0, "consumed slice credited");
        assertEq(
            IERC20(dividendToken).balanceOf(address(vault)),
            vault.dividendBalance(sourceToken, dividendToken),
            "credited == actually held"
        );
        assertEq(quoteToken.balanceOf(address(nadFunRouter)), 0, "router is non-custodial - no quote stranded");
    }

    // ── tokens the router cannot resolve: revert + rollback (replaces the vault-level guards) ──

    function test_routerLane_unresolvableToken_revertsAndPreservesPending() public {
        // An allowlisted external ERC20 holds pending but has no V2 registration — the REAL
        // router reverts resolving its market, and the whole order rolls back atomically.
        // (The deleted executeBondingBuy unregistered/quote-mismatch guards collapse into this
        // revert family: the registry lookup fails before any funds can strand.)
        MockERC20 externalToken = new MockERC20("XAUT", "XAUT", 18);
        vault.setAllowedDividendToken(address(externalToken), true);
        _setupDividend(address(externalToken));
        _deposit(1 ether);

        vm.prank(operator);
        vm.expectRevert(); // real router: market resolution fails for an unregistered token
        vault.executeConversion(_routerOrder(address(externalToken), 1 ether, 1));

        assertEq(vault.pendingSwap(sourceToken, address(externalToken)), 1 ether, "pending intact for retry");
        assertEq(quoteToken.balanceOf(address(vault)), 1 ether, "quote rolled back to the vault");
        assertEq(vault.dividendBalance(sourceToken, address(externalToken)), 0, "nothing credited");
    }
}
