// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Tests for YachaRouter's restricted receive(). Only the wrapped-native contract
///         may transfer ETH directly to the yachaRouter (withdraw callback). Every other path
///         (EOA transfer, third-party contract call) must revert to avoid stuck ETH.

import {SetUp} from "../SetUp.t.sol";
import {YachaRouter} from "../../src/router/YachaRouter.sol";
import {IYachaRouter} from "../../src/interfaces/IYachaRouter.sol";
import {MockWrappedNative} from "../mocks/MockWrappedNative.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Used to test that a non-wrapped-native contract cannot send ETH to the yachaRouter.
contract EtherForwarder {
    function forward(address payable target) external payable returns (bool success, bytes memory data) {
        (success, data) = target.call{value: msg.value}("");
    }
}

contract YachaRouterReceiveTest is SetUp {
    MockWrappedNative wnativeLocal;

    address token;

    function setUp() public override {
        super.setUp();

        // Build a yachaRouter whose wrappedNative points at a local MockWrappedNative we control,
        // so we can assert that MockWrappedNative is the ONLY accepted ETH source.
        wnativeLocal = new MockWrappedNative();

        YachaRouter impl = new YachaRouter();
        yachaRouter = YachaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            YachaRouter.initialize,
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
        bondingCurve.grantRole(routerRole, address(yachaRouter));

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
        (bool success, bytes memory data) = address(yachaRouter).call{value: 0.1 ether}("");

        assertFalse(success, "yachaRouter must reject direct EOA transfer");
        assertEq(bytes4(data), IYachaRouter.UnexpectedNative.selector, "should revert with UnexpectedNative");
        assertEq(address(yachaRouter).balance, 0, "yachaRouter balance stays zero");
    }

    function test_receive_reverts_whenRandomContractSends() public {
        EtherForwarder fwd = new EtherForwarder();
        vm.deal(address(this), 1 ether);

        (bool success, bytes memory data) = fwd.forward{value: 0.1 ether}(payable(address(yachaRouter)));

        assertFalse(success, "yachaRouter must reject third-party contract transfer");
        assertEq(bytes4(data), IYachaRouter.UnexpectedNative.selector, "should revert with UnexpectedNative");
        assertEq(address(yachaRouter).balance, 0, "yachaRouter balance stays zero");
    }

    // ── Accepted path ──────────────────────────────────────────────

    function test_receive_accepts_whenWrappedNativeWithdrawsBack() public {
        // Mint WNATIVE to the yachaRouter, then have the yachaRouter itself call wnative.withdraw, which
        // triggers the ETH callback into receive() with msg.sender == _wrappedNative.
        wnativeLocal.mint(address(yachaRouter), 1 ether);

        uint256 balanceBefore = address(yachaRouter).balance;

        // Make the yachaRouter perform the withdraw by impersonating it as msg.sender.
        vm.prank(address(yachaRouter));
        wnativeLocal.withdraw(1 ether);

        assertEq(
            address(yachaRouter).balance, balanceBefore + 1 ether, "yachaRouter received ETH from WNATIVE withdraw"
        );
    }
}
