// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {YachaRouter} from "../../../src/router/YachaRouter.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";

/// @title UpgradeYachaRouter
/// @notice Deploys a future YachaRouter implementation and upgrades an existing YachaRouter proxy.
/// @dev This script is only for proxies originally initialized as YachaRouter proxies. It does not
///      provide or imply storage compatibility with any legacy router proxy.
///
///      Required environment variables:
///        CHAIN_ID             - expected chain id
///        MULTISIG_PRIVATE_KEY  - signer whose address equals ProtocolManager.owner()
///        MULTISIG              - expected signer address
///        YACHA_ROUTER          - existing YachaRouter UUPS proxy
///        PROTOCOL_MANAGER      - ProtocolManager used as the proxy's authority
contract UpgradeYachaRouter is Script {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Snapshot {
        address implementation;
        address authority;
        address bondingCurve;
        address tokenRegistry;
        address wrappedNative;
        address v3SwapAdapter;
        address quoterV2;
    }

    struct Config {
        uint256 chainId;
        uint256 signerKey;
        address expectedSigner;
        address proxy;
        address protocolManager;
    }

    function run() external returns (address newImplementation) {
        return _run(
            Config({
                chainId: vm.envUint("CHAIN_ID"),
                signerKey: vm.envUint("MULTISIG_PRIVATE_KEY"),
                expectedSigner: vm.envAddress("MULTISIG"),
                proxy: vm.envAddress("YACHA_ROUTER"),
                protocolManager: vm.envAddress("PROTOCOL_MANAGER")
            })
        );
    }

    function runWithConfig(Config calldata config) external returns (address newImplementation) {
        return _run(config);
    }

    function _run(Config memory config) private returns (address newImplementation) {
        require(block.chainid == config.chainId, "UpgradeYachaRouter: CHAIN_ID mismatch");

        address signer = vm.addr(config.signerKey);
        require(signer == config.expectedSigner, "UpgradeYachaRouter: key does not match MULTISIG");
        require(config.proxy.code.length != 0, "UpgradeYachaRouter: YACHA_ROUTER not contract");
        require(config.protocolManager.code.length != 0, "UpgradeYachaRouter: PROTOCOL_MANAGER not contract");
        require(
            ProtocolManager(config.protocolManager).owner() == signer, "UpgradeYachaRouter: signer must equal PM.owner"
        );

        YachaRouter router = YachaRouter(payable(config.proxy));
        require(router.authority() == config.protocolManager, "UpgradeYachaRouter: proxy authority mismatch");
        (bool allowed, uint32 delay) = ProtocolManager(config.protocolManager)
            .canCall(signer, config.proxy, UUPSUpgradeable.upgradeToAndCall.selector);
        require(allowed && delay == 0, "UpgradeYachaRouter: upgrade permission missing");

        Snapshot memory beforeUpgrade = Snapshot({
            implementation: _readImplementation(config.proxy),
            authority: router.authority(),
            bondingCurve: router.bondingCurve(),
            tokenRegistry: router.tokenRegistry(),
            wrappedNative: router.wrappedNative(),
            v3SwapAdapter: router.v3SwapAdapter(),
            quoterV2: router.quoterV2()
        });

        vm.startBroadcast(config.signerKey);
        YachaRouter implementation = new YachaRouter();
        UUPSUpgradeable(config.proxy).upgradeToAndCall(address(implementation), "");
        vm.stopBroadcast();
        newImplementation = address(implementation);

        require(
            _readImplementation(config.proxy) == newImplementation, "UpgradeYachaRouter: implementation slot mismatch"
        );
        require(router.authority() == beforeUpgrade.authority, "UpgradeYachaRouter: authority changed");
        require(router.bondingCurve() == beforeUpgrade.bondingCurve, "UpgradeYachaRouter: curve changed");
        require(router.tokenRegistry() == beforeUpgrade.tokenRegistry, "UpgradeYachaRouter: registry changed");
        require(router.wrappedNative() == beforeUpgrade.wrappedNative, "UpgradeYachaRouter: WNATIVE changed");
        require(router.v3SwapAdapter() == beforeUpgrade.v3SwapAdapter, "UpgradeYachaRouter: adapter changed");
        require(router.quoterV2() == beforeUpgrade.quoterV2, "UpgradeYachaRouter: quoter changed");

        console.log("YachaRouter upgraded");
        console.log("Proxy:    ", config.proxy);
        console.log("Old impl: ", beforeUpgrade.implementation);
        console.log("New impl: ", newImplementation);
        console.log("Signer:   ", signer);
    }

    function _readImplementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
