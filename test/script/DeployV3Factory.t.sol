// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {DeployV3Factory} from "../../script/deploy/normal/DeployV3Factory.s.sol";

contract DeployV3FactoryHarness is DeployV3Factory {
    function deployFactory(address finalOwner) external returns (address) {
        return _deployFactory(finalOwner);
    }
}

contract DeployV3FactoryTest is Test {
    function test_runRejectsMismatchedFinalOwnerKey() public {
        uint256 deployerPrivateKey = 0xA11CE;
        uint256 multisigPrivateKey = 0xB0B;
        DeployV3Factory script = new DeployV3Factory();

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("PRIVATE_KEY", vm.toString(deployerPrivateKey));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("MULTISIG_PRIVATE_KEY", vm.toString(multisigPrivateKey));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOYER", vm.toString(vm.addr(deployerPrivateKey)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("MULTISIG", vm.toString(makeAddr("wrongFactoryOwner")));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CHAIN_ID", vm.toString(block.chainid));

        vm.expectRevert("DeployV3Factory: MULTISIG_PRIVATE_KEY mismatch");
        script.run();
    }

    function test_deploysCanonicalFactoryForSameOwner() public {
        DeployV3FactoryHarness harness = new DeployV3FactoryHarness();

        address factory = harness.deployFactory(address(harness));

        _assertFactory(factory, address(harness));
    }

    function test_transfersCanonicalFactoryToDistinctOwner() public {
        DeployV3FactoryHarness harness = new DeployV3FactoryHarness();
        address finalOwner = makeAddr("factoryOwner");

        address factory = harness.deployFactory(finalOwner);

        _assertFactory(factory, finalOwner);
    }

    function _assertFactory(address factory, address expectedOwner) private view {
        assertGt(factory.code.length, 0);

        IUniswapV3Factory v3Factory = IUniswapV3Factory(factory);
        assertEq(v3Factory.owner(), expectedOwner);
        assertEq(v3Factory.feeAmountTickSpacing(500), 10);
        assertEq(v3Factory.feeAmountTickSpacing(3000), 60);
        assertEq(v3Factory.feeAmountTickSpacing(10_000), 200);
    }
}
