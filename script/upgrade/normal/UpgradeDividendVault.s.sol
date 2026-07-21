// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {DividendVault} from "../../../src/vault/DividendVault.sol";

contract UpgradeDividendVault is Script {
    function run() external {
        uint256 key = vm.envUint("MULTISIG_PRIVATE_KEY");
        address vault = vm.envAddress("V2_DIVIDEND_VAULT");
        require(vault != address(0), "UpgradeDividendVault: zero vault");

        vm.startBroadcast(key);

        DividendVault newImpl = new DividendVault();
        UUPSUpgradeable(vault).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console.log("DividendVault upgraded");
        console.log("Vault:    ", vault);
        console.log("New impl: ", address(newImpl));
    }
}
