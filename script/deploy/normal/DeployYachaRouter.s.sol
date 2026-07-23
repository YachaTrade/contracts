// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IPeripheryImmutableState} from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";

import {BondingCurve} from "../../../src/core/BondingCurve.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";
import {IV3SwapAdapter} from "../../../src/interfaces/IV3SwapAdapter.sol";
import {YachaRouter} from "../../../src/router/YachaRouter.sol";

/// @title DeployYachaRouter
/// @notice Deploys a fresh, staged YachaRouter UUPS proxy without changing live routing authority.
/// @dev Reads every router dependency from the previous verified proxy so the replacement cannot
///      accidentally drift from the live protocol graph. Role changes are intentionally performed
///      later by resumable migration scripts, with Lens deployment between grant and revoke.
///
///      Required environment variables:
///        CHAIN_ID               - expected chain id
///        MULTISIG_PRIVATE_KEY    - signer whose address equals ProtocolManager.owner()
///        MULTISIG                - expected signer address
///        PREVIOUS_ROUTER         - router proxy currently holding BondingCurve.ROUTER_ROLE
///        PROTOCOL_MANAGER        - ProtocolManager used as the router authority
contract DeployYachaRouter is Script {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Config {
        uint256 chainId;
        uint256 signerKey;
        address expectedSigner;
        address previousRouter;
        address protocolManager;
    }

    struct Dependencies {
        address bondingCurve;
        address tokenRegistry;
        address wrappedNative;
        address v3SwapAdapter;
        address quoterV2;
    }

    function run() external returns (address newRouter, address implementation) {
        return _run(
            Config({
                chainId: vm.envUint("CHAIN_ID"),
                signerKey: vm.envUint("MULTISIG_PRIVATE_KEY"),
                expectedSigner: vm.envAddress("MULTISIG"),
                previousRouter: vm.envAddress("PREVIOUS_ROUTER"),
                protocolManager: vm.envAddress("PROTOCOL_MANAGER")
            })
        );
    }

    /// @dev Testable entry point that bypasses process-global environment variables.
    function runWithConfig(Config calldata config) external returns (address newRouter, address implementation) {
        return _run(config);
    }

    function _run(Config memory config) private returns (address newRouter, address implementation) {
        require(block.chainid == config.chainId, "DeployYachaRouter: CHAIN_ID mismatch");

        address signer = vm.addr(config.signerKey);
        require(signer == config.expectedSigner, "DeployYachaRouter: key does not match MULTISIG");
        require(config.previousRouter.code.length != 0, "DeployYachaRouter: PREVIOUS_ROUTER not contract");
        require(config.protocolManager.code.length != 0, "DeployYachaRouter: PROTOCOL_MANAGER not contract");
        require(
            ProtocolManager(config.protocolManager).owner() == signer, "DeployYachaRouter: signer must equal PM.owner"
        );
        require(
            _readImplementation(config.previousRouter).code.length != 0,
            "DeployYachaRouter: PREVIOUS_ROUTER is not an ERC1967 proxy"
        );

        YachaRouter previousRouter = YachaRouter(payable(config.previousRouter));
        require(
            previousRouter.authority() == config.protocolManager,
            "DeployYachaRouter: previous router authority mismatch"
        );

        Dependencies memory dependencies = Dependencies({
            bondingCurve: previousRouter.bondingCurve(),
            tokenRegistry: previousRouter.tokenRegistry(),
            wrappedNative: previousRouter.wrappedNative(),
            v3SwapAdapter: previousRouter.v3SwapAdapter(),
            quoterV2: previousRouter.quoterV2()
        });
        _validateDependencies(config, signer, dependencies);

        vm.startBroadcast(config.signerKey);
        implementation = address(new YachaRouter());
        newRouter = address(
            new ERC1967Proxy(
                implementation,
                abi.encodeCall(
                    YachaRouter.initialize,
                    (
                        config.protocolManager,
                        dependencies.bondingCurve,
                        dependencies.tokenRegistry,
                        dependencies.wrappedNative,
                        dependencies.v3SwapAdapter,
                        dependencies.quoterV2
                    )
                )
            )
        );

        vm.stopBroadcast();

        _verify(config, signer, dependencies, newRouter, implementation);

        console.log("YachaRouter deployed; curve role migration pending");
        console.log("Previous router:", config.previousRouter);
        console.log("YACHA_ROUTER:   ", newRouter);
        console.log("Implementation: ", implementation);
        console.log("Signer:         ", signer);
    }

    function _validateDependencies(Config memory config, address signer, Dependencies memory dependencies)
        private
        view
    {
        require(dependencies.bondingCurve.code.length != 0, "DeployYachaRouter: bonding curve missing code");
        require(dependencies.tokenRegistry.code.length != 0, "DeployYachaRouter: token registry missing code");
        require(dependencies.wrappedNative.code.length != 0, "DeployYachaRouter: WNATIVE missing code");
        require(dependencies.v3SwapAdapter.code.length != 0, "DeployYachaRouter: adapter missing code");
        require(dependencies.quoterV2.code.length != 0, "DeployYachaRouter: quoter missing code");

        BondingCurve curve = BondingCurve(payable(dependencies.bondingCurve));
        bytes32 adminRole = curve.DEFAULT_ADMIN_ROLE();
        bytes32 routerRole = curve.ROUTER_ROLE();
        require(curve.hasRole(adminRole, signer), "DeployYachaRouter: signer missing curve admin role");
        require(
            curve.hasRole(routerRole, config.previousRouter), "DeployYachaRouter: previous router missing curve role"
        );

        IV3SwapAdapter adapter = IV3SwapAdapter(dependencies.v3SwapAdapter);
        address factory = adapter.factory();
        require(factory.code.length != 0, "DeployYachaRouter: factory missing code");
        require(adapter.tokenRegistry() == dependencies.tokenRegistry, "DeployYachaRouter: adapter registry mismatch");
        IPeripheryImmutableState quoter = IPeripheryImmutableState(dependencies.quoterV2);
        require(quoter.factory() == factory, "DeployYachaRouter: quoter factory mismatch");
        require(quoter.WETH9() == dependencies.wrappedNative, "DeployYachaRouter: quoter WNATIVE mismatch");
    }

    function _verify(
        Config memory config,
        address signer,
        Dependencies memory dependencies,
        address newRouter,
        address implementation
    ) private view {
        require(newRouter.code.length != 0, "DeployYachaRouter: proxy deployment failed");
        require(implementation.code.length != 0, "DeployYachaRouter: implementation deployment failed");
        require(_readImplementation(newRouter) == implementation, "DeployYachaRouter: implementation slot mismatch");

        YachaRouter router = YachaRouter(payable(newRouter));
        require(router.authority() == config.protocolManager, "DeployYachaRouter: authority mismatch");
        require(router.bondingCurve() == dependencies.bondingCurve, "DeployYachaRouter: curve mismatch");
        require(router.tokenRegistry() == dependencies.tokenRegistry, "DeployYachaRouter: registry mismatch");
        require(router.wrappedNative() == dependencies.wrappedNative, "DeployYachaRouter: WNATIVE mismatch");
        require(router.v3SwapAdapter() == dependencies.v3SwapAdapter, "DeployYachaRouter: adapter mismatch");
        require(router.quoterV2() == dependencies.quoterV2, "DeployYachaRouter: quoter mismatch");

        BondingCurve curve = BondingCurve(payable(dependencies.bondingCurve));
        bytes32 routerRole = curve.ROUTER_ROLE();
        require(!curve.hasRole(routerRole, newRouter), "DeployYachaRouter: staged router unexpectedly has curve role");
        require(curve.hasRole(routerRole, config.previousRouter), "DeployYachaRouter: previous router lost curve role");

        (bool allowed, uint32 delay) = ProtocolManager(config.protocolManager)
            .canCall(signer, newRouter, UUPSUpgradeable.upgradeToAndCall.selector);
        require(allowed && delay == 0, "DeployYachaRouter: future upgrade permission missing");
    }

    function _readImplementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
