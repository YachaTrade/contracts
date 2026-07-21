// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {NadFunRouter} from "../../../src/router/NadFunRouter.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";

/// @title UpgradeRouter — deploys a fresh NadFunRouter implementation and
///                       upgrades the existing proxy to it.
/// @dev Environment variables:
///        MULTISIG_PRIVATE_KEY — signer with upgrade authority (must equal PM.owner())
///        V2_NAD_FUN_ROUTER    — address of the deployed UUPS proxy
///        V2_PROTOCOL_MANAGER  — address of ProtocolManager (used for authority sanity check)
///
///      Run:
///        source .env && forge script script/UpgradeRouter.s.sol:UpgradeRouter \
///            --rpc-url $RPC_URL --broadcast
contract UpgradeRouter is Script {
    // ERC1967 implementation storage slot
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        uint256 signerKey = vm.envUint("MULTISIG_PRIVATE_KEY");
        address proxy = vm.envAddress("V2_NAD_FUN_ROUTER");
        address protocolManager = vm.envAddress("V2_PROTOCOL_MANAGER");

        address signer = vm.addr(signerKey);

        // Authority sanity: signer must be PM.owner() (owner bypass on AccessManaged).
        address pmOwner = ProtocolManager(protocolManager).owner();
        require(signer == pmOwner, "Upgrade: signer must equal PM.owner");

        address oldImpl = _readImpl(proxy);

        vm.startBroadcast(signerKey);

        NadFunRouter newImpl = new NadFunRouter();
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        // Verify impl slot now points to new impl.
        address postImpl = _readImpl(proxy);
        require(postImpl == address(newImpl), "Upgrade: impl slot mismatch");

        // Verify new function is callable (reverts are fine for invalid tokens;
        // we're only checking selector presence via low-level staticcall).
        _assertSelectorExists(proxy, NadFunRouter.getAmountOut.selector);
        _assertSelectorExists(proxy, NadFunRouter.getAmountIn.selector);

        console.log("========================================");
        console.log("NadFunRouter upgraded");
        console.log("========================================");
        console.log("Proxy:       ", proxy);
        console.log("Old impl:    ", oldImpl);
        console.log("New impl:    ", address(newImpl));
        console.log("Signer:      ", signer);
        console.log("========================================");
    }

    function _readImpl(address proxy) internal view returns (address) {
        bytes32 value = vm.load(proxy, IMPL_SLOT);
        return address(uint160(uint256(value)));
    }

    /// @dev Low-level staticcall with empty calldata for a selector. A selector that
    ///      doesn't exist on the current impl causes a revert without data in Solidity
    ///      0.8.x. We expect the call to revert (no valid args) but with non-empty
    ///      return/revert path when the selector IS present.
    ///      In practice, the simpler check `proxy.code.length > 0` after upgrade is
    ///      enough for proxies, so this is a defense-in-depth sanity check.
    function _assertSelectorExists(address proxy, bytes4 selector) internal view {
        (bool ok, bytes memory ret) = proxy.staticcall(abi.encodeWithSelector(selector, address(0), uint256(0), false));
        // Either call succeeds (unlikely with zero args) OR reverts with some data —
        // both imply the selector was routed. A purely empty revert with ok=false and
        // ret.length == 0 can indicate missing function dispatch; treat as failure.
        require(ok || ret.length > 0, "Upgrade: selector dispatch missing");
    }
}
