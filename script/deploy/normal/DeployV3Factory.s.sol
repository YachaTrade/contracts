// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

/// @title DeployV3Factory
/// @notice Deploys the canonical Uniswap V3 factory used by the GIWA protocol.
/// @dev Required env: CHAIN_ID, PRIVATE_KEY, DEPLOYER, MULTISIG_PRIVATE_KEY, and MULTISIG.
contract DeployV3Factory is Script {
    function run() external returns (address factory) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 multisigPrivateKey = vm.envUint("MULTISIG_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address deployerEnv = vm.envAddress("DEPLOYER");
        address finalOwner = vm.envAddress("MULTISIG");

        require(block.chainid == vm.envUint("CHAIN_ID"), "DeployV3Factory: CHAIN_ID mismatch");
        require(deployer == deployerEnv, "DeployV3Factory: PRIVATE_KEY does not match DEPLOYER env");
        require(finalOwner != address(0), "DeployV3Factory: MULTISIG required");
        require(vm.addr(multisigPrivateKey) == finalOwner, "DeployV3Factory: MULTISIG_PRIVATE_KEY mismatch");

        vm.startBroadcast(deployerPrivateKey);
        factory = _deployFactory(finalOwner);
        vm.stopBroadcast();

        _verifyFactory(factory, finalOwner);
        console.log("========================================");
        console.log("Uniswap V3 factory deployment complete!");
        console.log("========================================");
        console.log(string.concat("V3_FACTORY=\"", vm.toString(factory), "\""));
        console.log("V3_FACTORY_OWNER:", finalOwner);
        console.log("========================================");
    }

    function _deployFactory(address finalOwner) internal returns (address factory) {
        require(finalOwner != address(0), "DeployV3Factory: final owner required");

        factory = address(new UniswapV3Factory());
        IUniswapV3Factory v3Factory = IUniswapV3Factory(factory);
        if (v3Factory.owner() != finalOwner) v3Factory.setOwner(finalOwner);
    }

    function _verifyFactory(address factory, address expectedOwner) internal view {
        require(factory.code.length > 0, "DeployV3Factory: factory missing code");

        IUniswapV3Factory v3Factory = IUniswapV3Factory(factory);
        require(v3Factory.owner() == expectedOwner, "DeployV3Factory: owner mismatch");
        require(v3Factory.feeAmountTickSpacing(500) == 10, "DeployV3Factory: 0.05% tier mismatch");
        require(v3Factory.feeAmountTickSpacing(3000) == 60, "DeployV3Factory: 0.3% tier mismatch");
        require(v3Factory.feeAmountTickSpacing(10_000) == 200, "DeployV3Factory: 1% tier mismatch");
    }
}
