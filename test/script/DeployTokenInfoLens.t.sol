// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployTokenInfoLens} from "../../script/deploy/normal/DeployTokenInfoLens.s.sol";
import {TokenInfoLens} from "../../src/integration/TokenInfoLens.sol";
import {MockTokenRegistryV1} from "../mocks/MockTokenRegistryV1.sol";
import {MockWrappedNative} from "../mocks/MockWrappedNative.sol";

contract DeployTokenInfoLensTest is Test {
    function test_runUsesDistinctLegacyV1WrappedNative() public {
        uint256 privateKey = 0xA11CE;
        address deployer = vm.addr(privateKey);
        vm.deal(deployer, 100 ether);

        MockTokenRegistryV1 v1Registry = new MockTokenRegistryV1();
        MockTokenRegistryV1 v2RegistryPlaceholder = new MockTokenRegistryV1();
        MockWrappedNative v1WrappedNative = new MockWrappedNative();

        vm.setEnv("PRIVATE_KEY", vm.toString(privateKey));
        vm.setEnv("V1_TOKEN_REGISTRY", vm.toString(address(v1Registry)));
        vm.setEnv("TOKEN_REGISTRY", vm.toString(address(v2RegistryPlaceholder)));
        vm.setEnv("V1_WRAPPED_NATIVE", vm.toString(address(v1WrappedNative)));

        TokenInfoLens lens = new DeployTokenInfoLens().run();

        assertEq(address(lens.v1Registry()), address(v1Registry));
        assertEq(address(lens.v2Registry()), address(v2RegistryPlaceholder));
        assertEq(lens.v1WrappedNative(), address(v1WrappedNative));
        assertTrue(lens.v1WrappedNative() != address(0x4200000000000000000000000000000000000006));
    }
}
