// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IWrappedNative} from "../../../src/interfaces/IWrappedNative.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GIWA_WETH} from "./Deploy.s.sol";

/// @title WrapMon
/// @notice Wraps native MON to the protocol deployment's WETH using the claim bot's signer.
///
/// Required env:
///   CLAIM_BOT_PRIVATE_KEY - signer key for the claim bot EOA
///   CLAIM_BOT             - expected bot address (sanity guard vs CLAIM_BOT_PRIVATE_KEY)
///   WRAP_AMOUNT           - amount in wei to wrap (e.g. 1000000000000000000 for 1 MON)
///
/// Run:
///   source .env.testnet && WRAP_AMOUNT=$(cast to-wei 1) \
///       forge script script/deploy/normal/WrapMon.s.sol:WrapMon \
///       --rpc-url $RPC_URL --broadcast
contract WrapMon is Script {
    function run() external {
        uint256 key = vm.envUint("CLAIM_BOT_PRIVATE_KEY");
        address botEnv = vm.envAddress("CLAIM_BOT");
        address weth = GIWA_WETH;
        uint256 amount = vm.envUint("WRAP_AMOUNT");

        address signer = vm.addr(key);
        require(weth.code.length > 0, "Wrap: canonical WETH missing code");
        require(signer == botEnv, "Wrap: CLAIM_BOT_PRIVATE_KEY does not match CLAIM_BOT env");
        require(amount > 0, "Wrap: WRAP_AMOUNT must be > 0");
        require(signer.balance >= amount, "Wrap: signer native balance < WRAP_AMOUNT");

        uint256 wethBefore = IERC20(weth).balanceOf(signer);

        vm.startBroadcast(key);
        IWrappedNative(weth).deposit{value: amount}();
        vm.stopBroadcast();

        uint256 wethAfter = IERC20(weth).balanceOf(signer);
        require(wethAfter - wethBefore == amount, "Wrap: WETH delta mismatch");

        console.log("========================================");
        console.log("Wrapped MON -> WETH");
        console.log("========================================");
        console.log("Bot:           ", signer);
        console.log("WETH:          ", weth);
        console.log("Amount (wei):  ", amount);
        console.log("WETH before:   ", wethBefore);
        console.log("WETH after:    ", wethAfter);
        console.log("========================================");
    }
}
