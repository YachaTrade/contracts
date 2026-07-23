// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeployYachaRouter} from "../../script/deploy/normal/DeployYachaRouter.s.sol";
import {YachaRouter} from "../../src/router/YachaRouter.sol";
import {SetUp} from "../SetUp.t.sol";

contract DeployYachaRouterTest is SetUp {
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant OWNER_KEY = 0xA11CE;

    address private owner;
    DeployYachaRouter private deployScript;

    function setUp() public override {
        super.setUp();

        owner = vm.addr(OWNER_KEY);
        vm.startPrank(admin);
        protocolManager.transferOwnership(owner);
        bondingCurve.grantRole(bondingCurve.DEFAULT_ADMIN_ROLE(), owner);
        vm.stopPrank();
        deployScript = new DeployYachaRouter();
    }

    function test_run_rejectsChainIdMismatch() public {
        DeployYachaRouter.Config memory config = _config();
        config.chainId = block.chainid + 1;

        vm.expectRevert("DeployYachaRouter: CHAIN_ID mismatch");
        deployScript.runWithConfig(config);
    }

    function test_run_rejectsSignerThatIsNotProtocolOwner() public {
        DeployYachaRouter.Config memory config = _config();
        config.signerKey = 0xB0B;
        config.expectedSigner = vm.addr(config.signerKey);

        vm.expectRevert("DeployYachaRouter: signer must equal PM.owner");
        deployScript.runWithConfig(config);
    }

    function test_run_rejectsSignerWithoutCurveAdminRole() public {
        bytes32 adminRole = bondingCurve.DEFAULT_ADMIN_ROLE();
        vm.prank(owner);
        bondingCurve.revokeRole(adminRole, owner);

        vm.expectRevert("DeployYachaRouter: signer missing curve admin role");
        deployScript.runWithConfig(_config());
    }

    function test_run_rejectsPreviousRouterWithoutCurveRole() public {
        bytes32 routerRole = bondingCurve.ROUTER_ROLE();
        vm.prank(owner);
        bondingCurve.revokeRole(routerRole, address(yachaRouter));

        vm.expectRevert("DeployYachaRouter: previous router missing curve role");
        deployScript.runWithConfig(_config());
    }

    function test_run_deploysFreshStagedProxyWithoutChangingCurveRoles() public {
        address previousRouter = address(yachaRouter);

        (address newRouterAddress, address implementation) = deployScript.runWithConfig(_config());
        YachaRouter newRouter = YachaRouter(payable(newRouterAddress));

        assertNotEq(newRouterAddress, previousRouter);
        assertGt(newRouterAddress.code.length, 0);
        assertGt(implementation.code.length, 0);
        assertEq(_implementation(newRouterAddress), implementation);
        assertEq(newRouter.authority(), address(protocolManager));
        assertEq(newRouter.bondingCurve(), address(bondingCurve));
        assertEq(newRouter.tokenRegistry(), address(tokenRegistry));
        assertEq(newRouter.wrappedNative(), address(wnative));
        assertEq(newRouter.v3SwapAdapter(), address(v3SwapAdapter));
        assertEq(newRouter.quoterV2(), address(quoterV2));
        assertFalse(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), newRouterAddress));
        assertTrue(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), previousRouter));

        (bool allowed, uint32 delay) =
            protocolManager.canCall(owner, newRouterAddress, UUPSUpgradeable.upgradeToAndCall.selector);
        assertTrue(allowed);
        assertEq(delay, 0);
    }

    function _config() private view returns (DeployYachaRouter.Config memory) {
        return DeployYachaRouter.Config({
            chainId: block.chainid,
            signerKey: OWNER_KEY,
            expectedSigner: owner,
            previousRouter: address(yachaRouter),
            protocolManager: address(protocolManager)
        });
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
