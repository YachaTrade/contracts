// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";

/// @title SetSnipingConfig — push the per-block sniping penalty table to a deployed ProtocolManager
/// @notice Standalone update script. Use after Deploy.s.sol to retune the curve without redeploying.
///
/// Required env:
///   PRIVATE_KEY        — deployer / admin key (must be ProtocolManager owner)
///   PROTOCOL_MANAGER   — proxy address
///
/// Curve (block.number - createdAtBlock as the index):
///   block 0: 80%
///   block 1: 40%
///   block 2: 20%
///   block 3: 15%
///   block 4: 10%
///   block 5: 10%
///   block 6:  5%
///   block 7+: 0%   (table length boundary)
contract SetSnipingConfig is Script {
    function _snipingPenaltyTable() internal pure returns (uint256[] memory table) {
        table = new uint256[](7);
        table[0] = 8000; // 80%
        table[1] = 4000; // 40%
        table[2] = 2000; // 20%
        table[3] = 1500; // 15%
        table[4] = 1000; // 10%
        table[5] = 1000; // 10%
        table[6] = 500; //  5%
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address protocolManager = vm.envAddress("PROTOCOL_MANAGER");

        uint256[] memory table = _snipingPenaltyTable();

        vm.startBroadcast(deployerPrivateKey);
        ProtocolManager pm = ProtocolManager(protocolManager);
        pm.setSnipingPenaltyTable(table);
        vm.stopBroadcast();

        // Verify
        require(pm.snipingPenaltyTableLength() == table.length, "Verify: table length mismatch");
        for (uint256 i = 0; i < table.length; i++) {
            require(pm.snipingPenaltyAt(i) == table[i], "Verify: table entry mismatch");
        }

        console.log("========================================");
        console.log("Sniping penalty table set!");
        console.log("ProtocolManager:", protocolManager);
        console.log("Length:         ", table.length);
        for (uint256 i = 0; i < table.length; i++) {
            console.log("  block", i, "=>", table[i]);
        }
        console.log("Past last index => 0");
        console.log("========================================");
    }
}
