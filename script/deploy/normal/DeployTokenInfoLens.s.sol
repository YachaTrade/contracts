// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TokenInfoLens} from "../../../src/integration/TokenInfoLens.sol";

/// @title DeployTokenInfoLens
/// @notice Deploys the TokenInfoLens view contract wired to existing V1/V2 TokenRegistry
///         addresses and the V1 registry's legacy wrapped-native quote. Requires env vars:
///         `PRIVATE_KEY`, `V1_TOKEN_REGISTRY`, `TOKEN_REGISTRY`, and `V1_WRAPPED_NATIVE`.
/// @dev `PRIVATE_KEY`를 env에서 직접 읽어 `vm.startBroadcast(pk)`로 사용한다 — CLI
///      `--private-key` 인자를 통한 ps/proc 노출을 피하기 위함.
contract DeployTokenInfoLens is Script {
    function run() external returns (TokenInfoLens lens) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address v1 = vm.envAddress("V1_TOKEN_REGISTRY");
        address v2 = vm.envAddress("TOKEN_REGISTRY");
        address v1WrappedNative = vm.envAddress("V1_WRAPPED_NATIVE");
        require(v1WrappedNative.code.length > 0, "DeployTokenInfoLens: V1 wrapped native missing code");

        vm.startBroadcast(pk);
        lens = new TokenInfoLens(v1, v2, v1WrappedNative);
        vm.stopBroadcast();

        console.log("TokenInfoLens deployed at:", address(lens));
        console.log("  v1Registry:", v1);
        console.log("  v2Registry:", v2);
        console.log("  v1WrappedNative:", v1WrappedNative);
    }
}
