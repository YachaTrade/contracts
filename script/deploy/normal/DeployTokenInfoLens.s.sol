// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TokenInfoLens} from "../../../src/integration/TokenInfoLens.sol";
import {GIWA_WETH} from "./Deploy.s.sol";

/// @title DeployTokenInfoLens
/// @notice Deploys the TokenInfoLens view contract wired to existing V1/V2 TokenRegistry
///         addresses and canonical GIWA WETH. Requires env vars: `PRIVATE_KEY`,
///         `V1_TOKEN_REGISTRY`, and `TOKEN_REGISTRY`.
/// @dev `PRIVATE_KEY`를 env에서 직접 읽어 `vm.startBroadcast(pk)`로 사용한다 — CLI
///      `--private-key` 인자를 통한 ps/proc 노출을 피하기 위함.
contract DeployTokenInfoLens is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address v1 = vm.envAddress("V1_TOKEN_REGISTRY");
        address v2 = vm.envAddress("TOKEN_REGISTRY");
        address weth = GIWA_WETH;
        require(weth.code.length > 0, "DeployTokenInfoLens: canonical WETH missing code");

        vm.startBroadcast(pk);
        TokenInfoLens lens = new TokenInfoLens(v1, v2, weth);
        vm.stopBroadcast();

        console.log("TokenInfoLens deployed at:", address(lens));
        console.log("  v1Registry:", v1);
        console.log("  v2Registry:", v2);
        console.log("  weth:      ", weth);
    }
}
