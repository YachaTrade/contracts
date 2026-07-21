// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IWrappedNative} from "../../../src/interfaces/IWrappedNative.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title WrapMon
/// @notice Wraps native MON to WMON using the claim bot's signer.
///
/// Required env:
///   CLAIM_BOT_PRIVATE_KEY - signer key for the claim bot EOA
///   CLAIM_BOT             - expected bot address (sanity guard vs CLAIM_BOT_PRIVATE_KEY)
///   WMON                  - wrapped native (WMON) address
///   WRAP_AMOUNT           - amount in wei to wrap (e.g. 1000000000000000000 for 1 MON)
///
/// Run:
///   source .env.testnet && WRAP_AMOUNT=$(cast to-wei 1) forge script script/WrapMon.s.sol:WrapMon \
///       --rpc-url $RPC_URL --broadcast
contract WrapMon is Script {
    function run() external {
        uint256 key = vm.envUint("CLAIM_BOT_PRIVATE_KEY");
        address botEnv = vm.envAddress("CLAIM_BOT");
        address wmon = vm.envAddress("WMON");
        uint256 amount = vm.envUint("WRAP_AMOUNT");

        address signer = vm.addr(key);
        require(signer == botEnv, "Wrap: CLAIM_BOT_PRIVATE_KEY does not match CLAIM_BOT env");
        require(amount > 0, "Wrap: WRAP_AMOUNT must be > 0");
        require(signer.balance >= amount, "Wrap: signer native balance < WRAP_AMOUNT");

        uint256 wmonBefore = IERC20(wmon).balanceOf(signer);

        vm.startBroadcast(key);
        IWrappedNative(wmon).deposit{value: amount}();
        vm.stopBroadcast();

        uint256 wmonAfter = IERC20(wmon).balanceOf(signer);
        require(wmonAfter - wmonBefore == amount, "Wrap: WMON delta mismatch");

        console.log("========================================");
        console.log("Wrapped MON -> WMON");
        console.log("========================================");
        console.log("Bot:           ", signer);
        console.log("WMON:          ", wmon);
        console.log("Amount (wei):  ", amount);
        console.log("WMON before:   ", wmonBefore);
        console.log("WMON after:    ", wmonAfter);
        console.log("========================================");
    }
}
