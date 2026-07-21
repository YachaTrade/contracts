// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {Token} from "../../src/token/Token.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenTest is SetUp {
    address public token;
    uint256 public holderPrivateKey = 0xA11CE;
    address public holder;

    function setUp() public override {
        super.setUp();
        token = _createToken();

        holderPrivateKey = 0xA11CE;
        holder = vm.addr(holderPrivateKey);

        // Skip past anti-sniping
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        // Buy tokens via router so holder has a balance
        uint256 buyAmount = 1 ether;
        quoteToken.mint(holder, buyAmount);
        vm.startPrank(holder);
        quoteToken.approve(address(giwaRouter), buyAmount);
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 0, token: token, to: holder, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_permit_approvesSpender() public {
        address spender = makeAddr("spender");
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(token).nonces(holder);

        bytes32 permitHash = _getPermitHash(token, holder, spender, amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPrivateKey, permitHash);

        IERC20Permit(token).permit(holder, spender, amount, deadline, v, r, s);

        assertEq(IERC20(token).allowance(holder, spender), amount, "Allowance should match permit amount");
    }

    function test_permit_incrementsNonce() public {
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp + 1 hours;

        uint256 nonceBefore = IERC20Permit(token).nonces(holder);

        bytes32 permitHash = _getPermitHash(token, holder, spender, 1 ether, nonceBefore, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPrivateKey, permitHash);
        IERC20Permit(token).permit(holder, spender, 1 ether, deadline, v, r, s);

        assertEq(IERC20Permit(token).nonces(holder), nonceBefore + 1, "Nonce should increment");
    }

    function test_permit_transferFromAfterPermit() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        uint256 amount = 50 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(token).nonces(holder);

        bytes32 permitHash = _getPermitHash(token, holder, spender, amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPrivateKey, permitHash);
        IERC20Permit(token).permit(holder, spender, amount, deadline, v, r, s);

        uint256 holderBefore = IERC20(token).balanceOf(holder);

        vm.prank(spender);
        IERC20(token).transferFrom(holder, recipient, amount);

        assertEq(IERC20(token).balanceOf(recipient), amount, "Recipient should receive tokens");
        assertEq(IERC20(token).balanceOf(holder), holderBefore - amount, "Holder balance should decrease");
    }

    function test_permit_revert_expiredDeadline() public {
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp - 1;
        uint256 nonce = IERC20Permit(token).nonces(holder);

        bytes32 permitHash = _getPermitHash(token, holder, spender, 1 ether, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPrivateKey, permitHash);

        vm.expectRevert();
        IERC20Permit(token).permit(holder, spender, 1 ether, deadline, v, r, s);
    }

    function test_permit_revert_invalidSignature() public {
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(token).nonces(holder);

        bytes32 permitHash = _getPermitHash(token, holder, spender, 1 ether, nonce, deadline);
        uint256 wrongKey = 0xDEAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, permitHash);

        vm.expectRevert();
        IERC20Permit(token).permit(holder, spender, 1 ether, deadline, v, r, s);
    }

    function test_permit_revert_replayNonce() public {
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(token).nonces(holder);

        bytes32 permitHash = _getPermitHash(token, holder, spender, 1 ether, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPrivateKey, permitHash);

        IERC20Permit(token).permit(holder, spender, 1 ether, deadline, v, r, s);

        // Replay same signature
        vm.expectRevert();
        IERC20Permit(token).permit(holder, spender, 1 ether, deadline, v, r, s);
    }

    function test_DOMAIN_SEPARATOR() public view {
        // Should not revert, should return non-zero
        bytes32 separator = IERC20Permit(token).DOMAIN_SEPARATOR();
        assertTrue(separator != bytes32(0), "DOMAIN_SEPARATOR should be non-zero");
    }

    function test_implementationCannotBeInitialized() public {
        Token impl = new Token();

        vm.expectRevert();
        impl.initialize("Template", "TPL", "", address(this), address(0xBEEF));
    }

    // ── Helpers ─────────────────────────────────────────────────────

    function _getPermitHash(
        address token_,
        address owner_,
        address spender_,
        uint256 value_,
        uint256 nonce_,
        uint256 deadline_
    ) internal view returns (bytes32) {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, value_, nonce_, deadline_));

        bytes32 domainSeparator = IERC20Permit(token_).DOMAIN_SEPARATOR();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
