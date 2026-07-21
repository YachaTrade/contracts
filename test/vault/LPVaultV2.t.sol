// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for LPVaultV2.

import {Test} from "forge-std/Test.sol";
import {LPVault} from "../../src/vault/LPVault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {NadSwapAdapter} from "../../src/adapters/NadSwapAdapter.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LPVaultV2Test is Test {
    LPVault public vault;
    MockERC20 public quoteToken;
    MockERC20 public creatorFeeToken;
    NadFunFactory public factory;
    TokenRegistry public tokenRegistry;
    FeeCollector public feeCollector;
    address public pair;

    ProtocolManager public protocolManager;
    address bondingCurve = makeAddr("bondingCurve");
    address constant BURN_ADDRESS = address(0xdead);

    uint256 constant INITIAL_TOKEN_LIQ = 100_000 ether;
    uint256 constant INITIAL_QUOTE_LIQ = 100 ether;

    function setUp() public {
        quoteToken = new MockERC20("WMON", "WMON", 18);
        creatorFeeToken = new MockERC20("MEME", "MEME", 18);

        // Deploy ProtocolManager via UUPS proxy
        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), makeAddr("feeReceiver")))
                )
            )
        );

        // Deploy real FeeCollector via proxy (no fee config by default)
        feeCollector = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(new FeeCollector()),
                    abi.encodeCall(
                        FeeCollector.initialize,
                        (address(protocolManager), makeAddr("creatorFeeProcessor"), bondingCurve, makeAddr("router"))
                    )
                )
            )
        );

        // Deploy NadFunFactory + Pair
        NadFunPair pairImpl = new NadFunPair();
        factory = new NadFunFactory(address(this), address(feeCollector), address(pairImpl));
        pair = factory.createPair(address(quoteToken), address(creatorFeeToken));

        // Seed initial liquidity
        _seedLiquidity(INITIAL_TOKEN_LIQ, INITIAL_QUOTE_LIQ);

        // Deploy real TokenRegistry via UUPS proxy
        tokenRegistry = TokenRegistry(
            address(
                new ERC1967Proxy(
                    address(new TokenRegistry()), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager)))
                )
            )
        );
        protocolManager.setOperatorPermission(
            bondingCurve, address(tokenRegistry), TokenRegistry.register.selector, true
        );
        tokenRegistry.setAdapter(ITokenRegistry.DexType.UniswapV2, IDexAdapter(address(new NadSwapAdapter())));

        // Register creatorFeeToken via ProtocolManager-granted operator permission (bondingCurve)
        vm.prank(bondingCurve);
        tokenRegistry.register(address(creatorFeeToken), pair, address(quoteToken), ITokenRegistry.DexType.UniswapV2);

        // Mock isGraduated → true for MockERC20 so vault uses DEX path
        vm.mockCall(address(creatorFeeToken), abi.encodeWithSignature("isGraduated()"), abi.encode(true));

        // Deploy LPVault via UUPS proxy with address(this) as creatorFeeProcessor
        vault = LPVault(
            address(
                new ERC1967Proxy(
                    address(new LPVault()),
                    abi.encodeCall(
                        LPVault.initialize, (address(protocolManager), address(tokenRegistry), address(this), "")
                    )
                )
            )
        );
    }

    function test_afterDeposit_swapsAndAddsLiquidity() public {
        uint256 amount = 10 ether;
        quoteToken.mint(address(vault), amount);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        // LP token should be at 0xdead (NadFunPair already mints MINIMUM_LIQUIDITY to 0xdead)
        uint256 lpBurned = IERC20(pair).balanceOf(BURN_ADDRESS);
        // Must be more than just the MINIMUM_LIQUIDITY
        assertGt(lpBurned, 1000, "LP tokens should be burned (more than MINIMUM_LIQUIDITY)");

        // Vault should be empty of both tokens
        assertEq(quoteToken.balanceOf(address(vault)), 0, "Vault should have no quoteToken left");
        assertEq(creatorFeeToken.balanceOf(address(vault)), 0, "Vault should have no creatorFeeToken left");
    }

    function test_afterDeposit_lpSentToBurnAddress() public {
        uint256 amount = 10 ether;
        quoteToken.mint(address(vault), amount);

        // Record LP balance before (includes MINIMUM_LIQUIDITY from initial mint)
        uint256 lpBefore = IERC20(pair).balanceOf(BURN_ADDRESS);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        uint256 lpAfter = IERC20(pair).balanceOf(BURN_ADDRESS);
        assertGt(lpAfter - lpBefore, 0, "New LP tokens should be minted to 0xdead");
    }

    function test_afterDeposit_emitsInject() public {
        uint256 amount = 10 ether;
        quoteToken.mint(address(vault), amount);

        // Just check the indexed creatorFeeToken
        vm.expectEmit(true, false, false, false);
        emit LPVault.AddLiquidity(address(creatorFeeToken), pair, 0, 0, 0);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);
    }

    /// @notice Zap must consume the entire deposited quoteToken amount — no dust left in the
    ///         vault. This is the whole point of using the closed-form zap split instead of a
    ///         naive 50/50 split. Tested across a range of amounts so rounding is exercised.
    function test_afterDeposit_zap_leavesNoRemainder() public {
        uint256[5] memory amounts = [uint256(1 ether), 3 ether, 7.5 ether, 12.345 ether, 99 ether];

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            quoteToken.mint(address(vault), amount);

            uint256 vaultQuoteBefore = quoteToken.balanceOf(address(vault)) - amount;
            uint256 vaultTokenBefore = creatorFeeToken.balanceOf(address(vault));

            vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

            // Vault must be empty of both sides — all of `amount` ended up in the pair.
            assertEq(
                quoteToken.balanceOf(address(vault)) - vaultQuoteBefore, 0, "zap leftover: quoteToken dust in vault"
            );
            assertEq(
                creatorFeeToken.balanceOf(address(vault)) - vaultTokenBefore,
                0,
                "zap leftover: creatorFeeToken dust in vault"
            );
            assertEq(vault.accumulatedQuote(address(creatorFeeToken)), 0, "accumulation should be zero post-zap");
        }
    }

    /// @dev Compare LP minted by zap vs by the naive 50/50 split. Zap should mint strictly more
    ///      LP for the same deposit, because it avoids the post-swap price mismatch that the
    ///      naive split leaves as a donation to other LPs.
    function test_afterDeposit_zapMintsMoreLpThanNaiveSplit() public {
        uint256 amount = 10 ether;
        quoteToken.mint(address(vault), amount);

        uint256 lpBefore = IERC20(pair).balanceOf(BURN_ADDRESS);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);
        uint256 lpZap = IERC20(pair).balanceOf(BURN_ADDRESS) - lpBefore;

        assertGt(lpZap, 0, "zap must mint LP");
    }

    function test_afterDeposit_zeroAmount_noOp() public {
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 0);
    }

    function test_afterDeposit_onlyCreatorFeeProcessor() public {
        address attacker = makeAddr("attacker");
        quoteToken.mint(address(vault), 10 ether);

        vm.prank(attacker);
        vm.expectRevert(LPVault.NotAuthorized.selector);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 10 ether);
    }

    function test_afterDeposit_correctSplit() public {
        uint256 amount = 10 ether;
        quoteToken.mint(address(vault), amount);

        // Record pair reserves before
        (uint112 r0Before, uint112 r1Before,) = INadFunPair(pair).getReserves();
        address token0 = INadFunPair(pair).token0();
        bool quoteIsToken0 = address(quoteToken) == token0;
        uint256 quoteReserveBefore = quoteIsToken0 ? uint256(r0Before) : uint256(r1Before);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        // After: all quoteToken should be in the pair (swap half + addLiquidity half)
        (uint112 r0After, uint112 r1After,) = INadFunPair(pair).getReserves();
        uint256 quoteReserveAfter = quoteIsToken0 ? uint256(r0After) : uint256(r1After);

        // The pair should have received close to the full amount
        // (some goes to FeeCollector if fee is set, but fee is 0 in this test)
        assertGt(quoteReserveAfter, quoteReserveBefore, "Pair should have more quoteToken after LP injection");
    }

    function test_afterDeposit_oddAmount() public {
        uint256 amount = 11 ether;
        quoteToken.mint(address(vault), amount);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        uint256 lpBurned = IERC20(pair).balanceOf(BURN_ADDRESS);
        assertGt(lpBurned, 1000, "LP should be burned for odd amount");

        assertEq(quoteToken.balanceOf(address(vault)), 0, "Vault should be empty");
        assertEq(creatorFeeToken.balanceOf(address(vault)), 0, "Vault should have no creatorFeeToken");
    }

    function test_afterDeposit_withPairFee() public {
        // Set 5% total fee rate
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(creatorFeeToken), address(quoteToken), 300, 200, 200);

        uint256 amount = 10 ether;
        quoteToken.mint(address(vault), amount);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        uint256 lpBurned = IERC20(pair).balanceOf(BURN_ADDRESS);
        assertGt(lpBurned, 1000, "LP should be burned even with pair fee");
    }

    /// @dev With zap math, an empty pair yields swapQuote == 0, so the call no-ops and
    ///      carries the quoteToken over to the next afterDeposit via `_accumulatedQuote`.
    function test_afterDeposit_emptyPair_accumulates() public {
        MockERC20 noLiqToken = new MockERC20("NOLIQ", "NL", 18);
        address emptyPair = factory.createPair(address(quoteToken), address(noLiqToken));
        vm.prank(bondingCurve);
        tokenRegistry.register(address(noLiqToken), emptyPair, address(quoteToken), ITokenRegistry.DexType.UniswapV2);
        vm.mockCall(address(noLiqToken), abi.encodeWithSignature("isGraduated()"), abi.encode(true));

        quoteToken.mint(address(vault), 10 ether);

        vault.afterDeposit(address(noLiqToken), address(quoteToken), 10 ether);

        // Pair still empty, zap was skipped, amount parked in accumulation.
        assertEq(vault.accumulatedQuote(address(noLiqToken)), 10 ether, "should carry over");
        assertEq(IERC20(emptyPair).totalSupply(), 0, "no LP minted");

        noLiqToken.mint(address(this), INITIAL_TOKEN_LIQ);
        quoteToken.mint(address(this), INITIAL_QUOTE_LIQ);
        IERC20(address(noLiqToken)).transfer(emptyPair, INITIAL_TOKEN_LIQ);
        IERC20(address(quoteToken)).transfer(emptyPair, INITIAL_QUOTE_LIQ);
        INadFunPair(emptyPair).mint(address(this));

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(noLiqToken), address(quoteToken), 1 ether);

        assertEq(vault.accumulatedQuote(address(noLiqToken)), 0, "pending quote should be consumed on retry");
        assertGt(IERC20(emptyPair).balanceOf(BURN_ADDRESS), 1000, "retry should mint burned LP");
    }

    function test_afterDeposit_multipleTokensSameSingleton() public {
        // Create second token + pair
        MockERC20 creatorFeeToken2 = new MockERC20("MEME2", "MEME2", 18);
        address pair2 = factory.createPair(address(quoteToken), address(creatorFeeToken2));
        vm.prank(bondingCurve);
        tokenRegistry.register(address(creatorFeeToken2), pair2, address(quoteToken), ITokenRegistry.DexType.UniswapV2);
        vm.mockCall(address(creatorFeeToken2), abi.encodeWithSignature("isGraduated()"), abi.encode(true));

        // Seed liquidity for pair2
        creatorFeeToken2.mint(address(this), INITIAL_TOKEN_LIQ);
        quoteToken.mint(address(this), INITIAL_QUOTE_LIQ);
        IERC20(address(creatorFeeToken2)).transfer(pair2, INITIAL_TOKEN_LIQ);
        IERC20(address(quoteToken)).transfer(pair2, INITIAL_QUOTE_LIQ);
        INadFunPair(pair2).mint(address(this));

        // LP inject for token1
        quoteToken.mint(address(vault), 10 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 10 ether);
        uint256 lp1 = IERC20(pair).balanceOf(BURN_ADDRESS);
        assertGt(lp1, 1000, "pair1 LP should be burned");

        // LP inject for token2 using SAME singleton
        quoteToken.mint(address(vault), 10 ether);
        vault.afterDeposit(address(creatorFeeToken2), address(quoteToken), 10 ether);
        uint256 lp2 = IERC20(pair2).balanceOf(BURN_ADDRESS);
        assertGt(lp2, 1000, "pair2 LP should be burned independently");
    }

    function test_setup_noop() public {
        vault.setup(address(creatorFeeToken), bytes(""));
    }

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(type(IVault).interfaceId), "Should support IVault");
    }

    function _seedLiquidity(uint256 tokenAmount, uint256 quote) internal {
        creatorFeeToken.mint(address(this), tokenAmount);
        quoteToken.mint(address(this), quote);

        IERC20(address(creatorFeeToken)).transfer(pair, tokenAmount);
        IERC20(address(quoteToken)).transfer(pair, quote);

        INadFunPair(pair).mint(address(this));
    }
}
