// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {GiwaRouter} from "../../../src/router/GiwaRouter.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";

/// @title UpgradeGiwaRouter
/// @notice Deploys a future GiwaRouter implementation and upgrades an existing GiwaRouter proxy.
/// @dev This script is only for proxies originally initialized as GiwaRouter proxies. It does not
///      provide or imply storage compatibility with any legacy router proxy.
///
///      Required environment variables:
///        MULTISIG_PRIVATE_KEY  - signer whose address equals ProtocolManager.owner()
///        GIWA_ROUTER           - existing GiwaRouter UUPS proxy
///        GIWA_PROTOCOL_MANAGER - ProtocolManager used as the proxy's authority
contract UpgradeGiwaRouter is Script {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        uint256 signerKey = vm.envUint("MULTISIG_PRIVATE_KEY");
        address proxy = vm.envAddress("GIWA_ROUTER");
        address protocolManager = vm.envAddress("GIWA_PROTOCOL_MANAGER");
        address signer = vm.addr(signerKey);

        require(proxy.code.length != 0, "Upgrade: GIWA_ROUTER not contract");
        require(protocolManager.code.length != 0, "Upgrade: GIWA_PROTOCOL_MANAGER not contract");
        require(signer == ProtocolManager(protocolManager).owner(), "Upgrade: signer must equal PM.owner");

        GiwaRouter router = GiwaRouter(payable(proxy));
        require(router.authority() == protocolManager, "Upgrade: proxy authority mismatch");

        address oldImpl = _readImpl(proxy);
        address bondingCurve = _readAddressSelector(proxy, GiwaRouter.bondingCurve.selector);
        address tokenRegistry = _readAddressSelector(proxy, GiwaRouter.tokenRegistry.selector);
        address wrappedNative = _readAddressSelector(proxy, GiwaRouter.wrappedNative.selector);
        address v3SwapAdapter = _readAddressSelector(proxy, GiwaRouter.v3SwapAdapter.selector);
        address quoterV2 = _readAddressSelector(proxy, GiwaRouter.quoterV2.selector);

        vm.startBroadcast(signerKey);
        GiwaRouter newImpl = new GiwaRouter();
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        require(_readImpl(proxy) == address(newImpl), "Upgrade: implementation slot mismatch");
        require(router.authority() == protocolManager, "Upgrade: authority changed");
        require(_readAddressSelector(proxy, GiwaRouter.bondingCurve.selector) == bondingCurve, "Upgrade: curve changed");
        require(
            _readAddressSelector(proxy, GiwaRouter.tokenRegistry.selector) == tokenRegistry, "Upgrade: registry changed"
        );
        require(
            _readAddressSelector(proxy, GiwaRouter.wrappedNative.selector) == wrappedNative, "Upgrade: WETH changed"
        );
        require(
            _readAddressSelector(proxy, GiwaRouter.v3SwapAdapter.selector) == v3SwapAdapter, "Upgrade: adapter changed"
        );
        require(_readAddressSelector(proxy, GiwaRouter.quoterV2.selector) == quoterV2, "Upgrade: quoter changed");

        console.log("GiwaRouter upgraded");
        console.log("Proxy:    ", proxy);
        console.log("Old impl: ", oldImpl);
        console.log("New impl: ", address(newImpl));
        console.log("Signer:   ", signer);
    }

    function _readImpl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function _readAddressSelector(address proxy, bytes4 selector) internal view returns (address value) {
        (bool ok, bytes memory result) = proxy.staticcall(abi.encodeWithSelector(selector));
        require(ok && result.length == 32, "Upgrade: selector dispatch missing");
        value = abi.decode(result, (address));
    }
}
