// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Tests for GiwaRouter's restricted receive(). Only the wrapped-native contract
///         may transfer ETH directly to the giwaRouter (withdraw callback). Every other path
///         (EOA transfer, third-party contract call) must revert to avoid stuck ETH.

import {SetUp} from "../SetUp.t.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {MockWrappedNative} from "../mocks/MockWrappedNative.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Used to test that a non-wrapped-native contract cannot send ETH to the giwaRouter.
contract EtherForwarder {
    function forward(address payable target) external payable returns (bool success, bytes memory data) {
        (success, data) = target.call{value: msg.value}("");
    }
}

contract GiwaRouterReceiveTest is SetUp {
    MockWrappedNative wnativeLocal;

    address token;

    function setUp() public override {
        super.setUp();

        // Build a giwaRouter whose wrappedNative points at a local MockWrappedNative we control,
        // so we can assert that MockWrappedNative is the ONLY accepted ETH source.
        wnativeLocal = new MockWrappedNative();

        GiwaRouter impl = new GiwaRouter();
        giwaRouter = GiwaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            GiwaRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wnativeLocal),
                                address(v3SwapAdapter),
                                address(quoterV2)
                            )
                        )
                    )
                ))
        );
        bytes32 routerRole = bondingCurve.ROUTER_ROLE();
        vm.prank(admin);
        bondingCurve.grantRole(routerRole, address(giwaRouter));

        // Fund the local WNATIVE with ETH so withdraw() can actually pay out.
        vm.deal(address(wnativeLocal), 100 ether);

        token = _createToken();
        vm.warp(block.timestamp + 100 minutes);
    }

    // ── Rejection paths ────────────────────────────────────────────

    function test_receive_reverts_whenEOASendsDirectly() public {
        address eoa = makeAddr("eoa");
        vm.deal(eoa, 1 ether);

        vm.prank(eoa);
        (bool success, bytes memory data) = address(giwaRouter).call{value: 0.1 ether}("");

        assertFalse(success, "giwaRouter must reject direct EOA transfer");
        assertEq(bytes4(data), IGiwaRouter.UnexpectedNative.selector, "should revert with UnexpectedNative");
        assertEq(address(giwaRouter).balance, 0, "giwaRouter balance stays zero");
    }

    function test_receive_reverts_whenRandomContractSends() public {
        EtherForwarder fwd = new EtherForwarder();
        vm.deal(address(this), 1 ether);

        (bool success, bytes memory data) = fwd.forward{value: 0.1 ether}(payable(address(giwaRouter)));

        assertFalse(success, "giwaRouter must reject third-party contract transfer");
        assertEq(bytes4(data), IGiwaRouter.UnexpectedNative.selector, "should revert with UnexpectedNative");
        assertEq(address(giwaRouter).balance, 0, "giwaRouter balance stays zero");
    }

    // ── Accepted path ──────────────────────────────────────────────

    function test_receive_accepts_whenWrappedNativeWithdrawsBack() public {
        // Mint WNATIVE to the giwaRouter, then have the giwaRouter itself call wnative.withdraw, which
        // triggers the ETH callback into receive() with msg.sender == _wrappedNative.
        wnativeLocal.mint(address(giwaRouter), 1 ether);

        uint256 balanceBefore = address(giwaRouter).balance;

        // Make the giwaRouter perform the withdraw by impersonating it as msg.sender.
        vm.prank(address(giwaRouter));
        wnativeLocal.withdraw(1 ether);

        assertEq(address(giwaRouter).balance, balanceBefore + 1 ether, "giwaRouter received ETH from WNATIVE withdraw");
    }
}
