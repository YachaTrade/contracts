// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Deploy} from "../../script/deploy/normal/Deploy.s.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {WrappedEther} from "../../src/token/WrappedEther.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract DeployHarness is Deploy {
    function deployWethAndProtocolManager(address admin, address feeReceiver, address lvmon)
        external
        returns (address weth, address protocolManager)
    {
        ProtocolDeploymentConfig memory config;
        config.quoteToken = QuoteTokenConfig({
            virtualReserve: 70_000 ether,
            virtualTokenReserve: 1_060_569_000 ether,
            minTokenReserve: 251_660_440_677_966_101_694_915_255,
            deployFee: 10 ether,
            graduateFee: 1_000 ether,
            curveProtocolFeeRate: 100,
            settlementThreshold: 1_000 ether,
            v3FeeTier: 3000,
            lpFeeProtocolShareBps: 5000
        });
        config.lvmonDexProtocolFeeRate = 777;
        config.snipingPenaltyTable = new uint256[](2);
        config.snipingPenaltyTable[0] = 100;
        config.creatorFeeRates = new uint16[](1);
        config.creatorFeeRates[0] = 100;

        return _deployWethAndProtocolManager(admin, feeReceiver, lvmon, config);
    }

    function readUint24(string memory key) external view returns (uint24) {
        return _readUint24(key);
    }
}

contract ProtocolWethQuoteTest is Test {
    address private constant FEE_RECEIVER = address(0xFEE);

    function test_wethIsActiveV3QuoteWithNoDexTradeFee() public {
        WrappedEther weth = new WrappedEther();
        ProtocolManager protocolManager = _deployProtocolManager(address(this), FEE_RECEIVER);
        protocolManager.addQuoteToken(
            address(weth),
            70_000 ether,
            1_060_569_000 ether,
            251_660_440_677_966_101_694_915_255,
            10 ether,
            1_000 ether,
            100,
            0,
            1_000 ether
        );
        protocolManager.setV3QuoteConfig(address(weth), 3000, 5000);

        IProtocolManager.QuoteConfig memory config = protocolManager.getConfig(address(weth));
        assertTrue(config.active);
        assertEq(config.dexProtocolFeeRate, 0);
        assertEq(config.v3FeeTier, 3000);
        assertEq(config.lpFeeProtocolShareBps, 5000);
    }

    function test_deployHelperCreatesAndReusesWethInsteadOfWmonEnv() public {
        MockERC20 lvmon = new MockERC20("LV MON", "LV_MON", 18);
        DeployHarness harness = new DeployHarness();
        (address weth, address protocolManagerAddress) =
            harness.deployWethAndProtocolManager(address(harness), FEE_RECEIVER, address(lvmon));

        ProtocolManager protocolManager = ProtocolManager(protocolManagerAddress);
        IProtocolManager.QuoteConfig memory wethConfig = protocolManager.getConfig(weth);
        IProtocolManager.QuoteConfig memory lvmonConfig = protocolManager.getConfig(address(lvmon));

        assertTrue(weth.code.length > 0);
        assertTrue(wethConfig.active);
        assertEq(wethConfig.dexProtocolFeeRate, 0);
        assertEq(wethConfig.v3FeeTier, 3000);
        assertEq(wethConfig.lpFeeProtocolShareBps, 5000);
        assertTrue(weth != address(lvmon));

        assertTrue(lvmonConfig.active);
        assertEq(lvmonConfig.dexProtocolFeeRate, 777);
        assertEq(lvmonConfig.v3FeeTier, 0);
        assertEq(lvmonConfig.lpFeeProtocolShareBps, 0);
    }

    function test_readUint24RejectsOverflow() public {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("OVERFLOWING_UINT24", vm.toString(uint256(type(uint24).max) + 1));

        DeployHarness harness = new DeployHarness();
        vm.expectRevert("Deploy: uint24 env overflow");
        harness.readUint24("OVERFLOWING_UINT24");
    }

    function _deployProtocolManager(address admin, address feeReceiver) private returns (ProtocolManager) {
        ProtocolManager implementation = new ProtocolManager();
        return ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(ProtocolManager.initialize, (admin, feeReceiver))
                )
            )
        );
    }
}
