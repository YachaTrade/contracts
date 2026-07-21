// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NadFunRouter02} from "../../../src/router/NadFunRouter02.sol";

/// @title DeployRouter02 — fresh deployment of the standalone NadFunRouter02 periphery.
/// @notice NadFunRouter02 (UniswapV2Router02-compatible liquidity + fee-aware swap) is a NEW,
///         self-contained contract over the EXISTING factory/pairs. It does NOT upgrade or touch
///         any deployed contract and needs NO multisig action — initialize only wires the factory
///         and WMON and points authority at the existing ProtocolManager. Any funded EOA can run it.
///
/// @dev Environment variables:
///        PRIVATE_KEY          — funded EOA that broadcasts the deployment
///        V2_PROTOCOL_MANAGER  — existing ProtocolManager (becomes AccessManaged authority)
///        V2_NAD_FUN_FACTORY   — existing NadFunFactory
///        WMON                 — wrapped native (returned by WETH())
///
///      Run (simulate first, then add --broadcast):
///        source .env && forge script script/DeployRouter02.s.sol:DeployRouter02 --rpc-url $RPC_URL
///        source .env && forge script script/DeployRouter02.s.sol:DeployRouter02 --rpc-url $RPC_URL --broadcast
contract DeployRouter02 is Script {
    function run() external returns (address proxy) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address protocolManager = vm.envAddress("V2_PROTOCOL_MANAGER");
        address factory = vm.envAddress("V2_NAD_FUN_FACTORY");
        address wmon = vm.envAddress("WMON");

        require(protocolManager != address(0), "DeployRouter02: PROTOCOL_MANAGER required");
        require(factory != address(0), "DeployRouter02: FACTORY required");
        require(wmon != address(0), "DeployRouter02: WMON required");

        vm.startBroadcast(deployerKey);

        NadFunRouter02 impl = new NadFunRouter02();
        proxy = address(
            new ERC1967Proxy(address(impl), abi.encodeCall(NadFunRouter02.initialize, (protocolManager, factory, wmon)))
        );

        vm.stopBroadcast();

        // Post-deploy sanity: confirm the new ABI is live and correctly wired.
        require(NadFunRouter02(payable(proxy)).factory() == factory, "DeployRouter02: factory not wired");
        require(NadFunRouter02(payable(proxy)).WETH() == wmon, "DeployRouter02: WETH not wired");

        console.log("========================================");
        console.log("NadFunRouter02 deployed");
        console.log("========================================");
        console.log("Implementation: ", address(impl));
        console.log("Proxy:          ", proxy);
        console.log("ProtocolManager:", protocolManager);
        console.log("Factory:        ", factory);
        console.log("WMON:           ", wmon);
        console.log("========================================");
    }
}
