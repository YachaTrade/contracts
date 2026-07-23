// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IWrappedNative} from "../../../src/interfaces/IWrappedNative.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GIWA_WNATIVE} from "./Deploy.s.sol";

/// @title WrapNative
/// @notice Wraps native currency to the protocol deployment's WNATIVE using the claim bot's signer.
///
/// Required env:
///   CLAIM_BOT_PRIVATE_KEY - signer key for the claim bot EOA
///   CLAIM_BOT             - expected bot address (sanity guard vs CLAIM_BOT_PRIVATE_KEY)
///   WRAP_AMOUNT           - amount in wei to wrap (e.g. 1000000000000000000 for 1 native unit)
///
/// Run:
///   source .env.testnet && WRAP_AMOUNT=$(cast to-wei 1) \
///       forge script script/deploy/normal/WrapNative.s.sol:WrapNative \
///       --rpc-url $RPC_URL --broadcast
contract WrapNative is Script {
    function run() external {
        uint256 key = vm.envUint("CLAIM_BOT_PRIVATE_KEY");
        address botEnv = vm.envAddress("CLAIM_BOT");
        address wnative = GIWA_WNATIVE;
        uint256 amount = vm.envUint("WRAP_AMOUNT");

        address signer = vm.addr(key);
        require(wnative.code.length > 0, "Wrap: canonical WNATIVE missing code");
        require(signer == botEnv, "Wrap: CLAIM_BOT_PRIVATE_KEY does not match CLAIM_BOT env");
        require(amount > 0, "Wrap: WRAP_AMOUNT must be > 0");
        require(signer.balance >= amount, "Wrap: signer native balance < WRAP_AMOUNT");

        uint256 wnativeBefore = IERC20(wnative).balanceOf(signer);

        vm.startBroadcast(key);
        IWrappedNative(wnative).deposit{value: amount}();
        vm.stopBroadcast();

        uint256 wnativeAfter = IERC20(wnative).balanceOf(signer);
        require(wnativeAfter - wnativeBefore == amount, "Wrap: WNATIVE delta mismatch");

        console.log("========================================");
        console.log("Wrapped native currency -> WNATIVE");
        console.log("========================================");
        console.log("Bot:           ", signer);
        console.log("WNATIVE:       ", wnative);
        console.log("Amount (wei):  ", amount);
        console.log("Before:        ", wnativeBefore);
        console.log("After:         ", wnativeAfter);
        console.log("========================================");
    }
}
