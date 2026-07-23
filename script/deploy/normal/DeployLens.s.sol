// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {IYachaRouter} from "../../../src/interfaces/IYachaRouter.sol";
import {Lens} from "../../../src/lens/Lens.sol";

/// @title DeployLens
/// @notice Deploys the immutable lifecycle-aware Lens against an existing canonical YachaRouter proxy.
/// @dev Required env: CHAIN_ID, PRIVATE_KEY, DEPLOYER, YACHA_ROUTER, BONDING_CURVE,
///      TOKEN_REGISTRY, and PROTOCOL_MANAGER.
contract DeployLens is Script {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    function run() external returns (address lensAddress) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");
        address yachaRouter = vm.envAddress("YACHA_ROUTER");
        address bondingCurve = vm.envAddress("BONDING_CURVE");
        address tokenRegistry = vm.envAddress("TOKEN_REGISTRY");
        address protocolManager = vm.envAddress("PROTOCOL_MANAGER");

        _validateInputs(
            deployerPrivateKey,
            deployerEnv,
            yachaRouter,
            bondingCurve,
            tokenRegistry,
            protocolManager,
            vm.envUint("CHAIN_ID")
        );

        vm.startBroadcast(deployerPrivateKey);
        Lens lens = _deployLens(yachaRouter);
        vm.stopBroadcast();

        lensAddress = address(lens);
        _verifyLens(lens, yachaRouter, bondingCurve, tokenRegistry, protocolManager);

        console.log("========================================");
        console.log("GIWA Lens deployment complete!");
        console.log("========================================");
        console.log(string.concat("LENS=\"", vm.toString(lensAddress), "\""));
        console.log("YACHA_ROUTER:", yachaRouter);
        console.log("BONDING_CURVE:", lens.curve());
        console.log("TOKEN_REGISTRY:", lens.tokenRegistry());
        console.log("PROTOCOL_MANAGER:", protocolManager);
        console.log("========================================");
    }

    function _validateInputs(
        uint256 deployerPrivateKey,
        address deployer,
        address yachaRouter,
        address bondingCurve,
        address tokenRegistry,
        address protocolManager,
        uint256 chainId
    ) internal view {
        require(block.chainid == chainId, "DeployLens: CHAIN_ID mismatch");
        require(vm.addr(deployerPrivateKey) == deployer, "DeployLens: PRIVATE_KEY does not match DEPLOYER env");
        require(yachaRouter.code.length > 0, "DeployLens: YACHA_ROUTER missing code");
        require(bondingCurve.code.length > 0, "DeployLens: BONDING_CURVE missing code");
        require(tokenRegistry.code.length > 0, "DeployLens: TOKEN_REGISTRY missing code");
        require(protocolManager.code.length > 0, "DeployLens: PROTOCOL_MANAGER missing code");
        require(_readImplementation(yachaRouter).code.length > 0, "DeployLens: YACHA_ROUTER is not an ERC1967 proxy");
        _requireRouterDependencies(yachaRouter, bondingCurve, tokenRegistry, protocolManager);
    }

    function _deployLens(address yachaRouter) internal returns (Lens lens) {
        lens = new Lens(yachaRouter);
    }

    function _verifyLens(
        Lens lens,
        address yachaRouter,
        address bondingCurve,
        address tokenRegistry,
        address protocolManager
    ) internal view {
        require(address(lens).code.length > 0, "DeployLens: Lens missing code");
        require(address(lens.yachaRouter()) == yachaRouter, "DeployLens: router mismatch");
        require(lens.curveRouter() == yachaRouter, "DeployLens: curve router mismatch");
        require(lens.dexRouter() == yachaRouter, "DeployLens: dex router mismatch");
        require(lens.curve() == bondingCurve, "DeployLens: Lens BONDING_CURVE mismatch");
        require(lens.tokenRegistry() == tokenRegistry, "DeployLens: Lens TOKEN_REGISTRY mismatch");
        _requireRouterDependencies(yachaRouter, bondingCurve, tokenRegistry, protocolManager);
    }

    function _requireRouterDependencies(
        address yachaRouter,
        address bondingCurve,
        address tokenRegistry,
        address protocolManager
    ) internal view {
        require(
            _readAddressSelector(yachaRouter, IYachaRouter.bondingCurve.selector) == bondingCurve,
            "DeployLens: BONDING_CURVE mismatch"
        );
        require(
            _readAddressSelector(yachaRouter, IYachaRouter.tokenRegistry.selector) == tokenRegistry,
            "DeployLens: TOKEN_REGISTRY mismatch"
        );
        require(
            _readAddressSelector(yachaRouter, IAccessManaged.authority.selector) == protocolManager,
            "DeployLens: PROTOCOL_MANAGER mismatch"
        );
        require(
            IAccessControl(bondingCurve).hasRole(ROUTER_ROLE, yachaRouter),
            "DeployLens: YACHA_ROUTER missing curve role"
        );
    }

    function _readImplementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function _readAddressSelector(address target, bytes4 selector) internal view returns (address value) {
        (bool ok, bytes memory result) = target.staticcall(abi.encodeWithSelector(selector));
        require(ok && result.length == 32, "DeployLens: router selector missing");
        value = abi.decode(result, (address));
    }
}
