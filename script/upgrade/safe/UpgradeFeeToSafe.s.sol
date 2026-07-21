// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {FeeTo} from "../../../src/core/FeeTo.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";

/// @title UpgradeFeeToSafe
/// @notice Mainnet FeeTo upgrade flow when ProtocolManager.owner() is a Safe (Gnosis
///         Safe) multisig that cannot directly sign forge broadcasts.
///
/// FeeTo._authorizeUpgrade is `restricted` (AccessManaged, authority = ProtocolManager),
/// so only PM.owner() (the Safe) may call `upgradeToAndCall` on the proxy via the
/// AccessManager owner bypass. This script therefore does NOT broadcast the privileged
/// call — it only deploys the new implementation (permissionless) from a deployer EOA
/// and prints the Safe calldata for the upgrade.
///
/// Storage safety: this upgrade is layout-compatible. The deprecated `router` slot is
/// retained (no state vars added/removed/reordered) — only swap logic changed. The
/// post-execution checklist confirms `router()` is unchanged as a slot-preservation proof.
///
/// Required env:
///   PRIVATE_KEY          - deployer EOA key (deploys the new impl; read via env, never CLI)
///   DEPLOYER             - expected deployer address (sanity guard)
///   MULTISIG             - Safe multisig address (must equal ProtocolManager.owner())
///   V2_PROTOCOL_MANAGER  - ProtocolManager UUPS proxy address
///   V2_FEE_TO            - FeeTo UUPS proxy address to upgrade
///
/// Run:
///   source .env.mainnet && forge script script/UpgradeFeeToSafe.s.sol:UpgradeFeeToSafe \
///       --rpc-url $RPC_URL --broadcast
///
/// After it succeeds, submit the printed transaction via Safe Transaction Builder
/// (target = FeeTo proxy).
contract UpgradeFeeToSafe is Script {
    // ERC1967 implementation storage slot.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");
        address multisig = vm.envAddress("MULTISIG");
        address protocolManager = vm.envAddress("V2_PROTOCOL_MANAGER");
        address proxy = vm.envAddress("V2_FEE_TO");

        require(vm.addr(deployerKey) == deployerEnv, "Upgrade: PRIVATE_KEY does not match DEPLOYER env");

        // Authority sanity: the Safe submitting the upgrade must be PM.owner() — the owner
        // bypass is what authorizes the `restricted` upgradeToAndCall on the proxy.
        address pmOwner = ProtocolManager(protocolManager).owner();
        require(pmOwner == multisig, "Upgrade: MULTISIG must equal PM.owner");

        address oldImpl = _readImpl(proxy);

        // -- 1. Deploy new impl (deployer EOA, permissionless) -------
        vm.startBroadcast(deployerKey);
        FeeTo newImpl = new FeeTo();
        vm.stopBroadcast();

        // -- 2. Print Safe calldata for the privileged upgrade -------
        bytes memory upgradeCall = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImpl), ""));

        console.log("========================================");
        console.log("FeeTo new implementation deployed");
        console.log("========================================");
        console.log("Proxy:            ", proxy);
        console.log("Old impl:         ", oldImpl);
        console.log("New impl:         ", address(newImpl));
        console.log("ProtocolManager:  ", protocolManager);
        console.log("Safe Multisig:    ", multisig);
        console.log("========================================");
        console.log("");
        console.log("Submit the following transaction via Safe Transaction Builder");
        console.log("(target = FeeTo proxy):");
        console.log("");
        console.log("---- upgradeToAndCall(newImpl, \"\") ----");
        console.log("  to:   ", proxy);
        console.log("  value: 0");
        console.log("  data:");
        console.logBytes(upgradeCall);
        console.log("");
        console.log("========================================");
        console.log("After Safe execution, verify:");
        console.log("  FeeTo impl slot == new impl printed above");
        console.log("  feeTo.router() unchanged (storage slot preserved)");
        console.log("  feeTo.claim(...) still callable by CLAIM_BOT");
        console.log("========================================");
    }

    function _readImpl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
