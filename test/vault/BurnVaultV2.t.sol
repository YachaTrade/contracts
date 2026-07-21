// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for BurnVaultV2.

import {Test} from "forge-std/Test.sol";
import {BurnVault} from "../../src/vault/BurnVault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {NadSwapAdapter} from "../../src/adapters/NadSwapAdapter.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BurnVaultV2Test is Test {
    BurnVault public vault;
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
        creatorFeeToken = new MockERC20("BASE", "BASE", 18);

        // Deploy ProtocolManager via UUPS proxy
        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), makeAddr("feeReceiver")))
                )
            )
        );

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

        // Deploy BurnVault via UUPS proxy with address(this) as creatorFeeProcessor for direct calls
        vault = BurnVault(
            address(
                new ERC1967Proxy(
                    address(new BurnVault()),
                    abi.encodeCall(
                        BurnVault.initialize,
                        (
                            address(protocolManager),
                            address(tokenRegistry),
                            address(this),
                            bondingCurve,
                            address(this),
                            ""
                        )
                    )
                )
            )
        );
    }

    function test_afterDeposit_buysAndBurns() public {
        uint256 amount = 1 ether;

        // Fund vault with quoteToken
        quoteToken.mint(address(vault), amount);

        // Source of truth: pair.getAmountOut (vanilla pair, no NadFun fee)
        uint256 expectedOut = INadFunPair(pair).getAmountOut(address(quoteToken), amount);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        // creatorFeeToken should be at 0xdead
        assertEq(creatorFeeToken.balanceOf(BURN_ADDRESS), expectedOut, "Burn amount should match expected output");
        assertEq(quoteToken.balanceOf(address(vault)), 0, "Vault should have no quoteToken left");
        assertEq(creatorFeeToken.balanceOf(address(vault)), 0, "Vault should have no creatorFeeToken left");
    }

    function test_afterDeposit_emitsBurn() public {
        uint256 amount = 1 ether;
        quoteToken.mint(address(vault), amount);

        // Source of truth: pair.getAmountOut (vanilla pair)
        uint256 expectedOut = INadFunPair(pair).getAmountOut(address(quoteToken), amount);

        vm.expectEmit(true, false, false, true);
        emit BurnVault.Burn(address(creatorFeeToken), pair, amount, expectedOut);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);
    }

    function test_afterDeposit_zeroAmount_noOp() public {
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 0);
        assertEq(creatorFeeToken.balanceOf(BURN_ADDRESS), 0, "No burn should happen for zero amount");
    }

    function test_afterDeposit_onlyCreatorFeeProcessor() public {
        address attacker = makeAddr("attacker");
        quoteToken.mint(address(vault), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(BurnVault.NotAuthorized.selector);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);
    }

    function test_afterDeposit_withPairFee_correctBurnAmount() public {
        // Set 5% total fee rate on the base token (500 BPS)
        vm.prank(bondingCurve);
        feeCollector.setup(pair, address(creatorFeeToken), address(quoteToken), 300, 200, 200);

        uint256 amount = 10 ether;
        quoteToken.mint(address(vault), amount);

        // Source of truth: pair.getAmountOut (with NadFun pair-level fee configured)
        uint256 expectedOut = INadFunPair(pair).getAmountOut(address(quoteToken), amount);

        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), amount);

        assertEq(creatorFeeToken.balanceOf(BURN_ADDRESS), expectedOut, "Burn should account for pair-level fee");
        assertEq(quoteToken.balanceOf(address(vault)), 0, "Vault should be empty");
    }

    function test_afterDeposit_noLiquidity_keepsPendingForRetry() public {
        // Create a new token with empty pair
        MockERC20 noLiqToken = new MockERC20("NOLIQ", "NL", 18);
        address emptyPair = factory.createPair(address(quoteToken), address(noLiqToken));
        vm.prank(bondingCurve);
        tokenRegistry.register(address(noLiqToken), emptyPair, address(quoteToken), ITokenRegistry.DexType.UniswapV2);
        vm.mockCall(address(noLiqToken), abi.encodeWithSignature("isGraduated()"), abi.encode(true));

        quoteToken.mint(address(vault), 1 ether);

        vault.afterDeposit(address(noLiqToken), address(quoteToken), 1 ether);

        assertEq(vault.pendingQuote(address(noLiqToken)), 1 ether, "failed buyback should remain pending");
        assertEq(quoteToken.balanceOf(address(vault)), 1 ether, "quote should stay in vault");
        assertEq(IERC20(emptyPair).totalSupply(), 0, "empty pair should stay untouched");

        noLiqToken.mint(address(this), INITIAL_TOKEN_LIQ);
        quoteToken.mint(address(this), INITIAL_QUOTE_LIQ);
        IERC20(address(noLiqToken)).transfer(emptyPair, INITIAL_TOKEN_LIQ);
        IERC20(address(quoteToken)).transfer(emptyPair, INITIAL_QUOTE_LIQ);
        INadFunPair(emptyPair).mint(address(this));

        uint256 retryAmount = 0.5 ether;
        uint256 expectedOut = INadFunPair(emptyPair).getAmountOut(address(quoteToken), 1 ether + retryAmount);
        quoteToken.mint(address(vault), retryAmount);
        vault.afterDeposit(address(noLiqToken), address(quoteToken), retryAmount);

        assertEq(vault.pendingQuote(address(noLiqToken)), 0, "pending quote should be consumed on retry");
        assertEq(noLiqToken.balanceOf(BURN_ADDRESS), expectedOut, "retry should burn pending plus new amount");
    }

    function test_afterDeposit_multipleTokensSameSingleton() public {
        // Create second token + pair
        MockERC20 creatorFeeToken2 = new MockERC20("BASE2", "BASE2", 18);
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

        // Burn token1
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(address(creatorFeeToken), address(quoteToken), 1 ether);
        uint256 burned1 = creatorFeeToken.balanceOf(BURN_ADDRESS);
        assertGt(burned1, 0, "creatorFeeToken1 should be burned");

        // Burn token2 using SAME vault
        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(address(creatorFeeToken2), address(quoteToken), 2 ether);
        uint256 burned2 = creatorFeeToken2.balanceOf(BURN_ADDRESS);
        assertGt(burned2, 0, "creatorFeeToken2 should be burned independently");

        // Token1 burn unchanged
        assertEq(creatorFeeToken.balanceOf(BURN_ADDRESS), burned1, "creatorFeeToken1 burn should be unchanged");
    }

    function test_setup_noop() public {
        vault.setup(address(creatorFeeToken), bytes(""));
    }

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(type(IVault).interfaceId), "Should support IVault");
    }

    function test_initialize_zeroTokenRegistry() public {
        BurnVault impl = new BurnVault();
        vm.expectRevert("Zero tokenRegistry");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                BurnVault.initialize,
                (address(protocolManager), address(0), address(this), bondingCurve, address(this), "")
            )
        );
    }

    function test_initialize_zeroCreatorFeeProcessor() public {
        BurnVault impl = new BurnVault();
        vm.expectRevert("Zero creatorFeeProcessor");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                BurnVault.initialize,
                (address(protocolManager), address(tokenRegistry), address(0), bondingCurve, address(this), "")
            )
        );
    }

    /// @dev Seed initial liquidity to NadFunPair
    function _seedLiquidity(uint256 tokenAmount, uint256 quote) internal {
        creatorFeeToken.mint(address(this), tokenAmount);
        quoteToken.mint(address(this), quote);

        IERC20(address(creatorFeeToken)).transfer(pair, tokenAmount);
        IERC20(address(quoteToken)).transfer(pair, quote);

        INadFunPair(pair).mint(address(this));
    }
}
