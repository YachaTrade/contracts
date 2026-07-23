// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {BondingCurve} from "../../../src/core/BondingCurve.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";
import {YachaRouter} from "../../../src/router/YachaRouter.sol";

/// @notice Shared validation for the two resumable YachaRouter role-migration stages.
abstract contract YachaRouterRoleMigrationBase is Script {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Config {
        uint256 chainId;
        uint256 signerKey;
        address expectedSigner;
        address previousRouter;
        address newRouter;
        address protocolManager;
    }

    function _envConfig() internal view returns (Config memory) {
        return Config({
            chainId: vm.envUint("CHAIN_ID"),
            signerKey: vm.envUint("MULTISIG_PRIVATE_KEY"),
            expectedSigner: vm.envAddress("MULTISIG"),
            previousRouter: vm.envAddress("PREVIOUS_ROUTER"),
            newRouter: vm.envAddress("YACHA_ROUTER"),
            protocolManager: vm.envAddress("PROTOCOL_MANAGER")
        });
    }

    function _validate(Config memory config)
        internal
        view
        returns (address signer, BondingCurve curve, bytes32 routerRole)
    {
        require(block.chainid == config.chainId, "MigrateYachaRouterRole: CHAIN_ID mismatch");

        signer = vm.addr(config.signerKey);
        require(signer == config.expectedSigner, "MigrateYachaRouterRole: key does not match MULTISIG");
        require(config.previousRouter != config.newRouter, "MigrateYachaRouterRole: routers must differ");
        require(config.previousRouter.code.length != 0, "MigrateYachaRouterRole: previous router not contract");
        require(config.newRouter.code.length != 0, "MigrateYachaRouterRole: new router not contract");
        require(config.protocolManager.code.length != 0, "MigrateYachaRouterRole: PM not contract");
        require(
            ProtocolManager(config.protocolManager).owner() == signer,
            "MigrateYachaRouterRole: signer must equal PM.owner"
        );
        require(
            _readImplementation(config.previousRouter).code.length != 0,
            "MigrateYachaRouterRole: previous router is not an ERC1967 proxy"
        );
        require(
            _readImplementation(config.newRouter).code.length != 0,
            "MigrateYachaRouterRole: new router is not an ERC1967 proxy"
        );

        YachaRouter previousRouter = YachaRouter(payable(config.previousRouter));
        YachaRouter newRouter = YachaRouter(payable(config.newRouter));
        require(
            previousRouter.authority() == config.protocolManager, "MigrateYachaRouterRole: previous authority mismatch"
        );
        require(newRouter.authority() == config.protocolManager, "MigrateYachaRouterRole: new authority mismatch");
        require(newRouter.bondingCurve() == previousRouter.bondingCurve(), "MigrateYachaRouterRole: curve mismatch");
        require(
            newRouter.tokenRegistry() == previousRouter.tokenRegistry(), "MigrateYachaRouterRole: registry mismatch"
        );
        require(newRouter.wrappedNative() == previousRouter.wrappedNative(), "MigrateYachaRouterRole: WNATIVE mismatch");
        require(newRouter.v3SwapAdapter() == previousRouter.v3SwapAdapter(), "MigrateYachaRouterRole: adapter mismatch");
        require(newRouter.quoterV2() == previousRouter.quoterV2(), "MigrateYachaRouterRole: quoter mismatch");

        curve = BondingCurve(payable(newRouter.bondingCurve()));
        require(address(curve).code.length != 0, "MigrateYachaRouterRole: curve missing code");
        require(
            curve.hasRole(curve.DEFAULT_ADMIN_ROLE(), signer), "MigrateYachaRouterRole: signer missing curve admin role"
        );
        routerRole = curve.ROUTER_ROLE();

        (bool allowed, uint32 delay) = ProtocolManager(config.protocolManager)
            .canCall(signer, config.newRouter, UUPSUpgradeable.upgradeToAndCall.selector);
        require(allowed && delay == 0, "MigrateYachaRouterRole: future upgrade permission missing");
    }

    function _readImplementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}

/// @title GrantYachaRouterRole
/// @notice Resumably grants the fresh YachaRouter its curve role while leaving the previous router live.
/// @dev Run this before deploying the replacement Lens. Re-running an already prepared state is a no-op.
contract GrantYachaRouterRole is YachaRouterRoleMigrationBase {
    function run() external returns (bool changed) {
        return _run(_envConfig());
    }

    function runWithConfig(Config calldata config) external returns (bool changed) {
        return _run(config);
    }

    function _run(Config memory config) private returns (bool changed) {
        (address signer, BondingCurve curve, bytes32 routerRole) = _validate(config);
        require(
            curve.hasRole(routerRole, config.previousRouter), "GrantYachaRouterRole: previous router missing curve role"
        );

        if (!curve.hasRole(routerRole, config.newRouter)) {
            vm.startBroadcast(config.signerKey);
            curve.grantRole(routerRole, config.newRouter);
            vm.stopBroadcast();
            changed = true;
        }

        require(curve.hasRole(routerRole, config.newRouter), "GrantYachaRouterRole: new router role not granted");
        require(curve.hasRole(routerRole, config.previousRouter), "GrantYachaRouterRole: previous router role changed");

        console.log("YachaRouter curve role prepared");
        console.log("PREVIOUS_ROUTER:", config.previousRouter);
        console.log("YACHA_ROUTER:   ", config.newRouter);
        console.log("Signer:         ", signer);
        console.log("Changed:        ", changed);
    }
}

/// @title RevokePreviousRouterRole
/// @notice Resumably retires the previous router from bonding-curve operations after Lens cutover.
/// @dev Re-running a completed state is a no-op. This does not disable permissionless graduated V3
///      trading through the previous router; it only removes BondingCurve.ROUTER_ROLE.
contract RevokePreviousRouterRole is YachaRouterRoleMigrationBase {
    function run() external returns (bool changed) {
        return _run(_envConfig());
    }

    function runWithConfig(Config calldata config) external returns (bool changed) {
        return _run(config);
    }

    function _run(Config memory config) private returns (bool changed) {
        (address signer, BondingCurve curve, bytes32 routerRole) = _validate(config);
        require(curve.hasRole(routerRole, config.newRouter), "RevokePreviousRouterRole: new router missing curve role");

        if (curve.hasRole(routerRole, config.previousRouter)) {
            vm.startBroadcast(config.signerKey);
            curve.revokeRole(routerRole, config.previousRouter);
            vm.stopBroadcast();
            changed = true;
        }

        require(curve.hasRole(routerRole, config.newRouter), "RevokePreviousRouterRole: new router role changed");
        require(
            !curve.hasRole(routerRole, config.previousRouter),
            "RevokePreviousRouterRole: previous router role not revoked"
        );

        console.log("Previous router curve role revoked");
        console.log("PREVIOUS_ROUTER:", config.previousRouter);
        console.log("YACHA_ROUTER:   ", config.newRouter);
        console.log("Signer:         ", signer);
        console.log("Changed:        ", changed);
    }
}
