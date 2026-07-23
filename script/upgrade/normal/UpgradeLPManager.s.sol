// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {LPManager} from "../../../src/core/LPManager.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";
import {IV3LiquidityActor} from "../../../src/interfaces/IV3LiquidityActor.sol";
import {IV3SwapAdapter} from "../../../src/interfaces/IV3SwapAdapter.sol";

/// @title UpgradeLPManager
/// @notice Deploys a new LPManager implementation and upgrades the configured UUPS proxy.
/// @dev Required env: CHAIN_ID, MULTISIG_PRIVATE_KEY, MULTISIG, LP_MANAGER, PROTOCOL_MANAGER.
contract UpgradeLPManager is Script {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Snapshot {
        address implementation;
        address authority;
        address v3Factory;
        address v3LiquidityActor;
        address creatorFeeProcessor;
        address v3SwapAdapter;
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
                proxy: vm.envAddress("LP_MANAGER"),
                protocolManager: vm.envAddress("PROTOCOL_MANAGER")
            })
        );
    }

    /// @dev Testable entry point that bypasses process-global environment variables.
    function runWithConfig(Config calldata config) external returns (address newImplementation) {
        return _run(config);
    }

    function _run(Config memory config) private returns (address newImplementation) {
        require(block.chainid == config.chainId, "UpgradeLPManager: CHAIN_ID mismatch");

        address signer = vm.addr(config.signerKey);

        require(signer == config.expectedSigner, "UpgradeLPManager: key does not match MULTISIG");
        require(config.proxy.code.length != 0, "UpgradeLPManager: LP_MANAGER not contract");
        require(config.protocolManager.code.length != 0, "UpgradeLPManager: PROTOCOL_MANAGER not contract");
        require(
            ProtocolManager(config.protocolManager).owner() == signer, "UpgradeLPManager: signer must equal PM.owner"
        );

        LPManager manager = LPManager(config.proxy);
        require(manager.authority() == config.protocolManager, "UpgradeLPManager: proxy authority mismatch");
        (bool allowed, uint32 delay) = ProtocolManager(config.protocolManager)
            .canCall(signer, config.proxy, UUPSUpgradeable.upgradeToAndCall.selector);
        require(allowed && delay == 0, "UpgradeLPManager: upgrade permission missing");

        Snapshot memory beforeUpgrade = Snapshot({
            implementation: _readImplementation(config.proxy),
            authority: manager.authority(),
            v3Factory: manager.v3Factory(),
            v3LiquidityActor: manager.v3LiquidityActor(),
            creatorFeeProcessor: manager.creatorFeeProcessor(),
            v3SwapAdapter: manager.v3SwapAdapter()
        });
        require(beforeUpgrade.v3LiquidityActor.code.length != 0, "UpgradeLPManager: actor not contract");
        require(beforeUpgrade.v3SwapAdapter.code.length != 0, "UpgradeLPManager: adapter not contract");
        require(
            IV3LiquidityActor(beforeUpgrade.v3LiquidityActor).owner() == config.proxy,
            "UpgradeLPManager: actor owner mismatch"
        );
        require(
            IV3LiquidityActor(beforeUpgrade.v3LiquidityActor).factory() == beforeUpgrade.v3Factory,
            "UpgradeLPManager: actor factory mismatch"
        );
        require(
            IV3SwapAdapter(beforeUpgrade.v3SwapAdapter).factory() == beforeUpgrade.v3Factory,
            "UpgradeLPManager: adapter factory mismatch"
        );
        _requireActorViewFees(beforeUpgrade.v3LiquidityActor);

        vm.startBroadcast(config.signerKey);
        LPManager implementation = new LPManager();
        UUPSUpgradeable(config.proxy).upgradeToAndCall(address(implementation), "");
        vm.stopBroadcast();
        newImplementation = address(implementation);

        require(
            _readImplementation(config.proxy) == newImplementation, "UpgradeLPManager: implementation slot mismatch"
        );
        require(manager.authority() == beforeUpgrade.authority, "UpgradeLPManager: authority changed");
        require(manager.v3Factory() == beforeUpgrade.v3Factory, "UpgradeLPManager: factory changed");
        require(manager.v3LiquidityActor() == beforeUpgrade.v3LiquidityActor, "UpgradeLPManager: actor changed");
        require(
            manager.creatorFeeProcessor() == beforeUpgrade.creatorFeeProcessor, "UpgradeLPManager: processor changed"
        );
        require(manager.v3SwapAdapter() == beforeUpgrade.v3SwapAdapter, "UpgradeLPManager: swap adapter changed");
        _requireNewSelector(config.proxy);

        console.log("LPManager upgraded");
        console.log("Proxy:    ", config.proxy);
        console.log("Old impl: ", beforeUpgrade.implementation);
        console.log("New impl: ", newImplementation);
        console.log("Signer:   ", signer);
    }

    function _requireActorViewFees(address actor) private view {
        (bool ok, bytes memory reason) = actor.staticcall(abi.encodeCall(IV3LiquidityActor.viewFees, (address(0))));
        require(
            !ok && _selector(reason) == IV3LiquidityActor.PositionNotFound.selector,
            "UpgradeLPManager: actor viewFees mismatch"
        );
    }

    function _requireNewSelector(address proxy) private view {
        (bool ok, bytes memory reason) =
            proxy.staticcall(abi.encodeCall(LPManager.callStaticGetAccumulatedFees, (address(0))));
        require(
            !ok && _selector(reason) == LPManager.InvalidPool.selector, "UpgradeLPManager: fee view selector mismatch"
        );
    }

    function _readImplementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(reason, 0x20))
        }
    }
}
