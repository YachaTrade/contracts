// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DividendVault} from "../../../src/vault/DividendVault.sol";

/// @title UpgradeDividendVaultSafe
/// @notice Mainnet DividendVault UUPS upgrade flow when the ProtocolManager owner is
///         a Safe (Gnosis Safe) multisig that cannot directly sign forge broadcasts.
///
/// The deployer EOA broadcasts only the new DividendVault implementation deployment.
/// The privileged `upgradeToAndCall` is printed as calldata for Safe owners to submit
/// via Safe Transaction Builder (or Safe SDK / API).
///
/// Required env:
///   PRIVATE_KEY        - deployer EOA key (deploys the new impl)
///   DEPLOYER           - expected deployer address (sanity guard)
///   V2_DIVIDEND_VAULT  - DividendVault UUPS proxy to upgrade
///   MULTISIG           - Safe multisig address (current ProtocolManager owner)
///
/// Run:
///   source .env.mainnet && forge script script/upgrade/safe/UpgradeDividendVaultSafe.s.sol:UpgradeDividendVaultSafe \
///       --rpc-url $RPC_URL --broadcast
///
/// After it succeeds, submit the printed transaction via Safe Transaction Builder
/// (target = DividendVault proxy).
contract UpgradeDividendVaultSafe is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");
        address vault = vm.envAddress("V2_DIVIDEND_VAULT");
        address multisig = vm.envAddress("MULTISIG");

        require(vault != address(0), "UpgradeDividendVaultSafe: V2_DIVIDEND_VAULT zero");
        require(multisig != address(0), "UpgradeDividendVaultSafe: MULTISIG zero");
        require(
            vm.addr(deployerKey) == deployerEnv, "UpgradeDividendVaultSafe: PRIVATE_KEY does not match DEPLOYER env"
        );

        vm.startBroadcast(deployerKey);
        DividendVault newImpl = new DividendVault();
        vm.stopBroadcast();

        bytes memory upgradeCall = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImpl), bytes("")));

        console.log("========================================");
        console.log("DividendVault new implementation deployed");
        console.log("========================================");
        console.log("Vault:         ", vault);
        console.log("Safe Multisig: ", multisig);
        console.log("New impl:      ", address(newImpl));
        console.log("========================================");
        console.log("");
        console.log("Submit the following transaction via Safe Transaction Builder:");
        console.log("");

        _logSafeTx('Tx 1: DividendVault.upgradeToAndCall(newImpl, "")', vault, upgradeCall);

        console.log("========================================");
        console.log("After Safe execution, verify: ERC1967 impl slot of vault == newImpl");
        console.log("========================================");
    }

    function _logSafeTx(string memory title, address target, bytes memory data) internal pure {
        console.log(string.concat("---- ", title, " ----"));
        console.log("  to:   ", target);
        console.log("  data:");
        console.logBytes(data);
        console.log("");
    }
}
