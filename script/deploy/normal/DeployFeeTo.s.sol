// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FeeTo} from "../../../src/core/FeeTo.sol";
import {IFeeTo} from "../../../src/interfaces/IFeeTo.sol";
import {IProtocolManager} from "../../../src/interfaces/IProtocolManager.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";
import {INadFunFactory} from "../../../src/dex/interfaces/INadFunFactory.sol";

/// @title DeployFeeTo
/// @notice Deploys a fresh FeeTo (impl + UUPS proxy), routes factory.feeTo() to it,
///         and grants claim operator permission to a bot EOA.
///
/// Required env:
///   PRIVATE_KEY          - deployer EOA private key (deploys impl + proxy)
///   DEPLOYER             - expected deployer address (sanity guard vs PRIVATE_KEY)
///   MULTISIG_PRIVATE_KEY - current ProtocolManager owner key (setFactoryFeeTo + setOperatorPermission)
///   V2_PROTOCOL_MANAGER  - ProtocolManager UUPS proxy address
///   V2_NAD_FUN_FACTORY   - NadFunFactory address
///   V2_NAD_FUN_ROUTER    - NadFunRouter UUPS proxy address
///   CLAIM_BOT            - EOA to be granted claim permission
///
/// Run:
///   source .env.testnet && forge script script/DeployFeeTo.s.sol:DeployFeeTo \
///       --rpc-url $RPC_URL --broadcast
contract DeployFeeTo is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 multisigKey = vm.envUint("MULTISIG_PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");
        address protocolManager = vm.envAddress("V2_PROTOCOL_MANAGER");
        address factory = vm.envAddress("V2_NAD_FUN_FACTORY");
        address router = vm.envAddress("V2_NAD_FUN_ROUTER");
        address bot = vm.envAddress("CLAIM_BOT");

        address deployer = vm.addr(deployerKey);
        address multisig = vm.addr(multisigKey);
        require(deployer == deployerEnv, "Deploy: PRIVATE_KEY does not match DEPLOYER env");
        require(
            ProtocolManager(protocolManager).owner() == multisig,
            "Deploy: MULTISIG_PRIVATE_KEY signer must be current ProtocolManager owner"
        );
        require(bot != address(0), "Deploy: CLAIM_BOT zero");

        // -- 1. Deploy impl + proxy (deployer) ------------------------
        vm.startBroadcast(deployerKey);
        FeeTo impl = new FeeTo();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(FeeTo.initialize, (protocolManager, router)));
        vm.stopBroadcast();

        address feeTo = address(proxy);

        // -- 2. Wire factory.feeTo + grant operator (multisig) --------
        vm.startBroadcast(multisigKey);
        IProtocolManager(protocolManager).setFactoryFeeTo(factory, feeTo);
        IProtocolManager(protocolManager).setOperatorPermission(bot, feeTo, IFeeTo.claim.selector, true);
        IProtocolManager(protocolManager).setOperatorPermission(bot, feeTo, IFeeTo.burn.selector, true);
        vm.stopBroadcast();

        // -- 3. Verify -----------------------------------------------
        require(INadFunFactory(factory).feeTo() == feeTo, "Verify: factory.feeTo mismatch");
        require(FeeTo(feeTo).router() == router, "Verify: router mismatch");
        require(FeeTo(feeTo).authority() == protocolManager, "Verify: authority mismatch");
        (bool claimAllowed,) = ProtocolManager(protocolManager).canCall(bot, feeTo, IFeeTo.claim.selector);
        require(claimAllowed, "Verify: bot missing claim permission");
        (bool burnAllowed,) = ProtocolManager(protocolManager).canCall(bot, feeTo, IFeeTo.burn.selector);
        require(burnAllowed, "Verify: bot missing burn permission");

        console.log("========================================");
        console.log("FeeTo deployed");
        console.log("========================================");
        console.log("Impl:             ", address(impl));
        console.log("Proxy:            ", feeTo);
        console.log("ProtocolManager:  ", protocolManager);
        console.log("Factory:          ", factory);
        console.log("Router:           ", router);
        console.log("Bot (claim):      ", bot);
        console.log("========================================");
    }
}
