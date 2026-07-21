// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Tests for NadFunRouter's restricted receive(). Only the wrapped-native contract
///         may transfer ETH directly to the router (withdraw callback). Every other path
///         (EOA transfer, third-party contract call) must revert to avoid stuck ETH.

import {SetUp} from "../SetUp.t.sol";
import {NadFunRouter} from "../../src/router/NadFunRouter.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Used to test that a non-wrapped-native contract cannot send ETH to the router.
contract EtherForwarder {
    function forward(address payable target) external payable returns (bool success, bytes memory data) {
        (success, data) = target.call{value: msg.value}("");
    }
}

contract NadFunRouterReceiveTest is SetUp {
    NadFunRouter router;
    MockWMON wmonLocal;

    address token;

    function setUp() public override {
        super.setUp();

        // Build a router whose wrappedNative points at a local MockWMON we control,
        // so we can assert that MockWMON is the ONLY accepted ETH source.
        wmonLocal = new MockWMON();

        NadFunRouter impl = new NadFunRouter();
        router = NadFunRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            NadFunRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wmonLocal),
                                address(0)
                            )
                        )
                    )
                ))
        );

        // Fund the local WMON with ETH so withdraw() can actually pay out.
        vm.deal(address(wmonLocal), 100 ether);

        token = _createToken();
        vm.warp(block.timestamp + 100 minutes);
    }

    // ── Rejection paths ────────────────────────────────────────────

    function test_receive_reverts_whenEOASendsDirectly() public {
        address eoa = makeAddr("eoa");
        vm.deal(eoa, 1 ether);

        vm.prank(eoa);
        (bool success, bytes memory data) = address(router).call{value: 0.1 ether}("");

        assertFalse(success, "router must reject direct EOA transfer");
        assertEq(bytes4(data), INadFunRouter.UnexpectedNative.selector, "should revert with UnexpectedNative");
        assertEq(address(router).balance, 0, "router balance stays zero");
    }

    function test_receive_reverts_whenRandomContractSends() public {
        EtherForwarder fwd = new EtherForwarder();
        vm.deal(address(this), 1 ether);

        (bool success, bytes memory data) = fwd.forward{value: 0.1 ether}(payable(address(router)));

        assertFalse(success, "router must reject third-party contract transfer");
        assertEq(bytes4(data), INadFunRouter.UnexpectedNative.selector, "should revert with UnexpectedNative");
        assertEq(address(router).balance, 0, "router balance stays zero");
    }

    // ── Accepted path ──────────────────────────────────────────────

    function test_receive_accepts_whenWrappedNativeWithdrawsBack() public {
        // Mint WMON to the router, then have the router itself call wmon.withdraw, which
        // triggers the ETH callback into receive() with msg.sender == _wrappedNative.
        wmonLocal.mint(address(router), 1 ether);

        uint256 balanceBefore = address(router).balance;

        // Make the router perform the withdraw by impersonating it as msg.sender.
        vm.prank(address(router));
        wmonLocal.withdraw(1 ether);

        assertEq(address(router).balance, balanceBefore + 1 ether, "router received ETH from WMON withdraw");
    }
}
