// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Treasury} from "../../../src/core/Treasury.sol";
import {IProtocolManager} from "../../../src/interfaces/IProtocolManager.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";

/// @title DeployTreasurySafe
/// @notice Deploys a fresh Treasury (impl + UUPS proxy) on mainnet (deployer EOA) and
///         prints the multisig calldata required to point ProtocolManager.feeReceiver()
///         at the new Treasury proxy. Treasury is AccessManaged with ProtocolManager
///         as authority -- PM.owner() is auto-permitted.
///
/// Required env:
///   PRIVATE_KEY          - deployer EOA key
///   DEPLOYER             - expected deployer address (sanity guard)
///   V2_PROTOCOL_MANAGER  - ProtocolManager UUPS proxy (used as Treasury authority)
///   WMON                 - wrapped native (WMON) address
///
/// Run:
///   source .env.mainnet && forge script script/DeployTreasurySafe.s.sol:DeployTreasurySafe \
///       --rpc-url $RPC_URL --broadcast --legacy --gas-estimate-multiplier 300
contract DeployTreasurySafe is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");
        address protocolManager = vm.envAddress("V2_PROTOCOL_MANAGER");
        address wmon = vm.envAddress("WMON");

        require(vm.addr(deployerKey) == deployerEnv, "Deploy: PRIVATE_KEY does not match DEPLOYER env");

        // -- 1. Deploy impl + proxy (deployer EOA) -------------------
        vm.startBroadcast(deployerKey);
        Treasury impl = new Treasury();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(Treasury.initialize, (protocolManager, wmon)));
        vm.stopBroadcast();

        address treasury = address(proxy);

        // -- 2. Print calldata for the Safe to submit -----------------
        bytes memory setFeeReceiverCall = abi.encodeCall(IProtocolManager.setFeeReceiver, (treasury));

        console.log("========================================");
        console.log("Treasury deployed");
        console.log("========================================");
        console.log("Impl:            ", address(impl));
        console.log("Proxy:           ", treasury);
        console.log("WMON:            ", wmon);
        console.log("Authority:       ", protocolManager);
        console.log("PM.owner:        ", ProtocolManager(protocolManager).owner());
        console.log("========================================");
        console.log("");
        console.log("Submit the following transaction via Safe Transaction Builder:");
        console.log("");
        console.log("---- Tx: setFeeReceiver(treasury) ----");
        console.log("  to:   ", protocolManager);
        console.log("  data:");
        console.logBytes(setFeeReceiverCall);
        console.log("");
        console.log("========================================");
        console.log("After Safe execution, verify:");
        console.log("  PM.feeReceiver() == treasury");
        console.log("========================================");
    }
}
