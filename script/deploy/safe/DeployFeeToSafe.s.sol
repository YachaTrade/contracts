// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FeeTo} from "../../../src/core/FeeTo.sol";
import {IFeeTo} from "../../../src/interfaces/IFeeTo.sol";
import {IProtocolManager} from "../../../src/interfaces/IProtocolManager.sol";
import {INadFunFactory} from "../../../src/dex/interfaces/INadFunFactory.sol";

/// @title DeployFeeToSafe
/// @notice Mainnet deploy flow when the ProtocolManager owner is a Safe (Gnosis Safe)
///         multisig that cannot directly sign forge broadcasts.
///
/// Flow:
///   1. Deployer EOA broadcasts: deploy FeeTo impl + ERC1967Proxy.
///   2. Script prints three multisig calldatas (target + data) that the Safe owners
///      must submit via Safe Transaction Builder (or Safe SDK / API).
///
/// Required env:
///   PRIVATE_KEY          - deployer EOA key (deploys impl + proxy)
///   DEPLOYER             - expected deployer address (sanity guard)
///   MULTISIG             - Safe multisig address (current ProtocolManager owner)
///   V2_PROTOCOL_MANAGER  - ProtocolManager UUPS proxy address
///   V2_NAD_FUN_FACTORY   - NadFunFactory address
///   V2_NAD_FUN_ROUTER    - NadFunRouter UUPS proxy address
///   CLAIM_BOT            - EOA to receive claim + burn operator permissions
///
/// Run:
///   source .env.mainnet && forge script script/DeployFeeToSafe.s.sol:DeployFeeToSafe \
///       --rpc-url $RPC_URL --broadcast
///
/// After it succeeds, follow the printed Safe transactions section to finish wiring.
contract DeployFeeToSafe is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");
        address multisig = vm.envAddress("MULTISIG");
        address protocolManager = vm.envAddress("V2_PROTOCOL_MANAGER");
        address factory = vm.envAddress("V2_NAD_FUN_FACTORY");
        address router = vm.envAddress("V2_NAD_FUN_ROUTER");
        address bot = vm.envAddress("CLAIM_BOT");

        require(vm.addr(deployerKey) == deployerEnv, "Deploy: PRIVATE_KEY does not match DEPLOYER env");
        require(bot != address(0), "Deploy: CLAIM_BOT zero");

        // -- 1. Deploy impl + proxy (deployer EOA) -------------------
        vm.startBroadcast(deployerKey);
        FeeTo impl = new FeeTo();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(FeeTo.initialize, (protocolManager, router)));
        vm.stopBroadcast();

        address feeTo = address(proxy);

        // -- 2. Print calldatas for the Safe to submit ---------------
        bytes memory setFeeToCall = abi.encodeCall(IProtocolManager.setFactoryFeeTo, (factory, feeTo));
        bytes memory grantClaimCall =
            abi.encodeCall(IProtocolManager.setOperatorPermission, (bot, feeTo, IFeeTo.claim.selector, true));
        bytes memory grantBurnCall =
            abi.encodeCall(IProtocolManager.setOperatorPermission, (bot, feeTo, IFeeTo.burn.selector, true));

        console.log("========================================");
        console.log("FeeTo deployed (impl + proxy only)");
        console.log("========================================");
        console.log("Impl:             ", address(impl));
        console.log("Proxy:            ", feeTo);
        console.log("ProtocolManager:  ", protocolManager);
        console.log("Factory:          ", factory);
        console.log("Router:           ", router);
        console.log("Bot (claim+burn): ", bot);
        console.log("Safe Multisig:    ", multisig);
        console.log("========================================");
        console.log("");
        console.log("Submit the following 3 transactions via Safe Transaction Builder");
        console.log("(target = ProtocolManager for all three):");
        console.log("");

        console.log("---- Tx 1: setFactoryFeeTo(factory, feeTo) ----");
        console.log("  to:   ", protocolManager);
        console.log("  data:");
        console.logBytes(setFeeToCall);
        console.log("");

        console.log("---- Tx 2: grant CLAIM_BOT claim permission ----");
        console.log("  to:   ", protocolManager);
        console.log("  data:");
        console.logBytes(grantClaimCall);
        console.log("");

        console.log("---- Tx 3: grant CLAIM_BOT burn permission ----");
        console.log("  to:   ", protocolManager);
        console.log("  data:");
        console.logBytes(grantBurnCall);
        console.log("");
        console.log("========================================");
        console.log("After Safe execution, verify:");
        console.log("  factory.feeTo() == proxy");
        console.log("  PM.canCall(bot, proxy, claim.selector) == true");
        console.log("  PM.canCall(bot, proxy, burn.selector)  == true");
        console.log("========================================");
    }
}
