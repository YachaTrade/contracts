// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for CreatorFeeVault.

import {SetUp} from "../SetUp.t.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";

/// @dev Helper that reverts on native receive — used to exercise NativeTransferFailed.
contract RevertingReceiver {
    receive() external payable {
        revert("RevertingReceiver");
    }
}

contract CreatorFeeVaultTest is SetUp {
    CreatorFeeVault public vault;
    address public recipient = makeAddr("recipient");
    address public bondingCurveAddr = makeAddr("bondingCurve");
    address public creatorFeeToken;

    function setUp() public override {
        super.setUp();

        // Deploy test-specific CreatorFeeVault via UUPS proxy
        // bondingCurveAddr for setup() auth, address(this) as creatorFeeProcessor for afterDeposit() auth
        vault = CreatorFeeVault(
            payable(address(
                    new ERC1967Proxy(
                        address(new CreatorFeeVault()),
                        abi.encodeCall(
                            CreatorFeeVault.initialize,
                            (
                                address(protocolManager),
                                bondingCurveAddr,
                                address(this),
                                address(tokenRegistry),
                                address(wmon),
                                ""
                            )
                        )
                    )
                ))
        );

        // Create a token and register it in tokenRegistry so claim() can look up quoteToken
        creatorFeeToken = _createToken();

        // Setup per-token creator
        vm.prank(bondingCurveAddr);
        vault.setup(creatorFeeToken, abi.encode(recipient));
    }

    function test_setup() public view {
        assertEq(vault.getCreator(creatorFeeToken), recipient);
    }

    function test_setup_revert_notAuthorized() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(CreatorFeeVault.NotAuthorized.selector);
        vault.setup(makeAddr("newToken"), abi.encode(recipient));
    }

    function test_setup_revert_zeroCreator() public {
        address newToken = _createTokenWith("NewToken", "NT", 500, keccak256("new-token-zero-creator"));
        vm.prank(bondingCurveAddr);
        vm.expectRevert(CreatorFeeVault.ZeroCreator.selector);
        vault.setup(newToken, abi.encode(address(0)));
    }

    function test_setup_revert_alreadyConfigured() public {
        vm.prank(bondingCurveAddr);
        vm.expectRevert(CreatorFeeVault.AlreadyConfigured.selector);
        vault.setup(creatorFeeToken, abi.encode(makeAddr("newRecipient")));
    }

    function test_afterDeposit_accumulatesBalance() public {
        uint256 amount = 100 ether;
        quoteToken.mint(address(vault), amount);

        vault.afterDeposit(creatorFeeToken, address(quoteToken), amount);

        assertEq(vault.getBalance(creatorFeeToken), amount, "Balance should be accumulated");
        assertEq(quoteToken.balanceOf(address(vault)), amount, "Vault should hold quoteToken");
        assertEq(quoteToken.balanceOf(recipient), 0, "Recipient should not receive directly");
    }

    function test_afterDeposit_accumulatesMultipleDeposits() public {
        quoteToken.mint(address(vault), 100 ether);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), 100 ether);

        quoteToken.mint(address(vault), 50 ether);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), 50 ether);

        assertEq(vault.getBalance(creatorFeeToken), 150 ether, "Balance should accumulate");
    }

    function test_afterDeposit_emitsDeposit() public {
        uint256 amount = 50 ether;
        quoteToken.mint(address(vault), amount);

        vm.expectEmit(true, false, false, true);
        emit CreatorFeeVault.Deposit(creatorFeeToken, amount, amount);

        vault.afterDeposit(creatorFeeToken, address(quoteToken), amount);
    }

    function test_afterDeposit_zeroAmount() public {
        vault.afterDeposit(creatorFeeToken, address(quoteToken), 0);
        assertEq(vault.getBalance(creatorFeeToken), 0, "No balance for zero amount");
    }

    function test_afterDeposit_unconfiguredToken_skips() public {
        address unknownToken = makeAddr("unknownToken");
        uint256 amount = 100 ether;
        quoteToken.mint(address(vault), amount);

        vault.afterDeposit(unknownToken, address(quoteToken), amount);

        // quoteToken stays in vault (not accumulated to any balance)
        assertEq(vault.getBalance(unknownToken), 0, "No balance for unconfigured token");
        assertEq(quoteToken.balanceOf(address(vault)), amount, "Vault still holds quoteToken");
    }

    function test_afterDeposit_onlyCreatorFeeProcessor() public {
        address attacker = makeAddr("attacker");
        quoteToken.mint(address(vault), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(CreatorFeeVault.NotAuthorized.selector);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), 1 ether);
    }

    function test_claim_transfersToCreator() public {
        uint256 amount = 100 ether;
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), amount);

        vm.prank(recipient);
        vault.claim(creatorFeeToken);

        assertEq(quoteToken.balanceOf(recipient), amount, "Creator should receive full amount");
        assertEq(vault.getBalance(creatorFeeToken), 0, "Balance should be zero after claim");
        assertEq(quoteToken.balanceOf(address(vault)), 0, "Vault should be empty after claim");
    }

    function test_claim_emitsClaim() public {
        uint256 amount = 50 ether;
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), amount);

        vm.expectEmit(true, true, false, true);
        emit CreatorFeeVault.Claim(creatorFeeToken, recipient, amount);

        vm.prank(recipient);
        vault.claim(creatorFeeToken);
    }

    function test_claim_revert_notCreator() public {
        quoteToken.mint(address(vault), 100 ether);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), 100 ether);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(CreatorFeeVault.NotAuthorized.selector);
        vault.claim(creatorFeeToken);
    }

    function test_claim_revert_zeroBalance() public {
        vm.prank(recipient);
        vm.expectRevert(CreatorFeeVault.ZeroBalance.selector);
        vault.claim(creatorFeeToken);
    }

    function test_afterDeposit_multipleTokensDifferentCreators() public {
        address creatorFeeToken2 = _createTokenWith("Token2", "T2", 500, keccak256("creator-fee-vault-token2"));
        address recipient2 = makeAddr("recipient2");

        // Setup second token with different creator
        vm.prank(bondingCurveAddr);
        vault.setup(creatorFeeToken2, abi.encode(recipient2));

        // Deposit for creatorFeeToken1
        uint256 amount1 = 100 ether;
        quoteToken.mint(address(vault), amount1);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), amount1);
        assertEq(vault.getBalance(creatorFeeToken), amount1);

        // Deposit for creatorFeeToken2
        uint256 amount2 = 200 ether;
        quoteToken.mint(address(vault), amount2);
        vault.afterDeposit(creatorFeeToken2, address(quoteToken), amount2);
        assertEq(vault.getBalance(creatorFeeToken2), amount2);

        // Claim for token1
        vm.prank(recipient);
        vault.claim(creatorFeeToken);
        assertEq(quoteToken.balanceOf(recipient), amount1);

        // Claim for token2
        vm.prank(recipient2);
        vault.claim(creatorFeeToken2);
        assertEq(quoteToken.balanceOf(recipient2), amount2);
    }

    // initialize: zero address reverts
    function test_initialize_revert_zeroBondingCurve() public {
        CreatorFeeVault impl = new CreatorFeeVault();
        vm.expectRevert("Zero bondingCurve");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CreatorFeeVault.initialize,
                (address(protocolManager), address(0), address(this), address(tokenRegistry), address(wmon), "")
            )
        );
    }

    function test_initialize_revert_zeroCreatorFeeProcessor() public {
        CreatorFeeVault impl = new CreatorFeeVault();
        vm.expectRevert("Zero creatorFeeProcessor");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CreatorFeeVault.initialize,
                (address(protocolManager), bondingCurveAddr, address(0), address(tokenRegistry), address(wmon), "")
            )
        );
    }

    function test_initialize_revert_zeroTokenRegistry() public {
        CreatorFeeVault impl = new CreatorFeeVault();
        vm.expectRevert("Zero tokenRegistry");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CreatorFeeVault.initialize,
                (address(protocolManager), bondingCurveAddr, address(this), address(0), address(wmon), "")
            )
        );
    }

    // ── setCreator ──────────────────────────────────────────────────

    function test_setCreator_byOwner() public {
        address newCreator = makeAddr("newCreator");

        vm.expectEmit(true, true, true, true);
        emit CreatorFeeVault.CreatorUpdate(creatorFeeToken, recipient, newCreator);

        vm.prank(admin);
        vault.setCreator(creatorFeeToken, newCreator);

        assertEq(vault.getCreator(creatorFeeToken), newCreator);
    }

    function test_setCreator_byOperator() public {
        address operator = makeAddr("operator");
        address newCreator = makeAddr("newCreator");

        // Grant operator permission for setCreator selector
        vm.prank(admin);
        protocolManager.setOperatorPermission(operator, address(vault), CreatorFeeVault.setCreator.selector, true);

        vm.prank(operator);
        vault.setCreator(creatorFeeToken, newCreator);

        assertEq(vault.getCreator(creatorFeeToken), newCreator);
    }

    function test_setCreator_claimGoesToNewCreator() public {
        // Deposit some fees
        uint256 amount = 100 ether;
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), amount);

        // Change creator
        address newCreator = makeAddr("newCreator");
        vm.prank(admin);
        vault.setCreator(creatorFeeToken, newCreator);

        // New creator claims
        vm.prank(newCreator);
        vault.claim(creatorFeeToken);

        assertEq(quoteToken.balanceOf(newCreator), amount);
        assertEq(quoteToken.balanceOf(recipient), 0);
    }

    function test_setCreator_oldCreatorCannotClaim() public {
        uint256 amount = 100 ether;
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), amount);

        address newCreator = makeAddr("newCreator");
        vm.prank(admin);
        vault.setCreator(creatorFeeToken, newCreator);

        vm.prank(recipient);
        vm.expectRevert(CreatorFeeVault.NotAuthorized.selector);
        vault.claim(creatorFeeToken);
    }

    function test_setCreator_revert_unauthorized() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert();
        vault.setCreator(creatorFeeToken, attacker);
    }

    function test_setCreator_revert_zeroCreator() public {
        vm.prank(admin);
        vm.expectRevert(CreatorFeeVault.ZeroCreator.selector);
        vault.setCreator(creatorFeeToken, address(0));
    }

    function test_setCreator_revert_notConfigured() public {
        address unknownToken = makeAddr("unknownToken");

        vm.prank(admin);
        vm.expectRevert(CreatorFeeVault.NotConfigured.selector);
        vault.setCreator(unknownToken, makeAddr("someone"));
    }

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(type(IVault).interfaceId), "Should support IVault");
    }

    // ── WMON unwrap ─────────────────────────────────────────────────

    function test_initialize_setsWmon() public view {
        assertEq(vault.wmon(), address(wmon), "wmon should be set from initialize");
    }

    /// @notice claim() unwraps and forwards native MON when registered quote == wmon.
    function test_claim_unwrapsWhenQuoteIsWmon() public {
        uint256 amount = 100 ether;

        // Fund vault with WMON (simulates afterDeposit accumulation).
        vm.deal(address(this), amount);
        wmon.deposit{value: amount}();
        wmon.transfer(address(vault), amount);
        vault.afterDeposit(creatorFeeToken, address(wmon), amount);

        // Override the registered quote so claim() reads wmon.
        vm.mockCall(
            address(tokenRegistry),
            abi.encodeWithSelector(ITokenRegistry.getQuoteToken.selector, creatorFeeToken),
            abi.encode(address(wmon))
        );

        uint256 nativeBefore = recipient.balance;

        vm.prank(recipient);
        vault.claim(creatorFeeToken);

        assertEq(recipient.balance - nativeBefore, amount, "recipient should receive native MON");
        assertEq(wmon.balanceOf(recipient), 0, "recipient should not receive WMON");
        assertEq(wmon.balanceOf(address(vault)), 0, "vault should be drained");
        assertEq(vault.getBalance(creatorFeeToken), 0, "balance state should be cleared");
    }

    /// @notice Non-WMON quotes still ERC20-transfer (regression guard).
    function test_claim_doesNotUnwrapForNonWmonQuote() public {
        uint256 amount = 100 ether;
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(creatorFeeToken, address(quoteToken), amount);

        vm.prank(recipient);
        vault.claim(creatorFeeToken);

        assertEq(quoteToken.balanceOf(recipient), amount, "recipient should receive ERC20");
        assertEq(recipient.balance, 0, "no native MON should be sent");
    }

    /// @notice Native transfer failure (recipient reverts in receive) reverts the whole claim,
    ///         leaving balance state intact for retry via setCreator.
    function test_claim_revertsWhenNativeTransferFails() public {
        uint256 amount = 50 ether;

        vm.deal(address(this), amount);
        wmon.deposit{value: amount}();
        wmon.transfer(address(vault), amount);
        vault.afterDeposit(creatorFeeToken, address(wmon), amount);

        // Replace the creator with a contract that reverts on native receive.
        RevertingReceiver bad = new RevertingReceiver();
        vm.prank(admin);
        vault.setCreator(creatorFeeToken, address(bad));

        vm.mockCall(
            address(tokenRegistry),
            abi.encodeWithSelector(ITokenRegistry.getQuoteToken.selector, creatorFeeToken),
            abi.encode(address(wmon))
        );

        vm.prank(address(bad));
        vm.expectRevert(CreatorFeeVault.NativeTransferFailed.selector);
        vault.claim(creatorFeeToken);
    }

    /// @notice receive() rejects native sent from any address other than the configured wmon.
    function test_receive_revertsFromNonWmon() public {
        vm.deal(address(this), 1 ether);

        (bool ok, bytes memory ret) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "non-wmon native transfer must fail");
        assertEq(bytes4(ret), CreatorFeeVault.UnexpectedNative.selector, "should revert with UnexpectedNative");
    }
}
