// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeployYachaRouter} from "../../script/deploy/normal/DeployYachaRouter.s.sol";
import {
    GrantYachaRouterRole,
    RevokePreviousRouterRole,
    YachaRouterRoleMigrationBase
} from "../../script/deploy/normal/MigrateYachaRouterRole.s.sol";
import {YachaRouter} from "../../src/router/YachaRouter.sol";
import {SetUp} from "../SetUp.t.sol";

contract MigrationDependencyStub {}

contract MigrateYachaRouterRoleTest is SetUp {
    uint256 private constant OWNER_KEY = 0xA11CE;

    address private owner;
    address private previousRouter;
    address private newRouter;
    GrantYachaRouterRole private grantScript;
    RevokePreviousRouterRole private revokeScript;

    function setUp() public override {
        super.setUp();

        owner = vm.addr(OWNER_KEY);
        previousRouter = address(yachaRouter);
        vm.startPrank(admin);
        protocolManager.transferOwnership(owner);
        bondingCurve.grantRole(bondingCurve.DEFAULT_ADMIN_ROLE(), owner);
        vm.stopPrank();

        DeployYachaRouter deployScript = new DeployYachaRouter();
        (newRouter,) = deployScript.runWithConfig(
            DeployYachaRouter.Config({
                chainId: block.chainid,
                signerKey: OWNER_KEY,
                expectedSigner: owner,
                previousRouter: previousRouter,
                protocolManager: address(protocolManager)
            })
        );
        grantScript = new GrantYachaRouterRole();
        revokeScript = new RevokePreviousRouterRole();
    }

    function test_grant_addsNewRoleAndKeepsPreviousRole() public {
        bool changed = grantScript.runWithConfig(_config());

        assertTrue(changed);
        assertTrue(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), newRouter));
        assertTrue(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), previousRouter));
    }

    function test_grant_isIdempotentForPreparedState() public {
        assertTrue(grantScript.runWithConfig(_config()));
        assertFalse(grantScript.runWithConfig(_config()));

        assertTrue(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), newRouter));
        assertTrue(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), previousRouter));
    }

    function test_revoke_rejectsBeforeNewRoleIsLive() public {
        vm.expectRevert("RevokePreviousRouterRole: new router missing curve role");
        revokeScript.runWithConfig(_config());
    }

    function test_revoke_removesPreviousRoleAndKeepsNewRole() public {
        grantScript.runWithConfig(_config());

        bool changed = revokeScript.runWithConfig(_config());

        assertTrue(changed);
        assertTrue(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), newRouter));
        assertFalse(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), previousRouter));
    }

    function test_revoke_isIdempotentForCompletedState() public {
        grantScript.runWithConfig(_config());
        assertTrue(revokeScript.runWithConfig(_config()));
        assertFalse(revokeScript.runWithConfig(_config()));

        assertTrue(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), newRouter));
        assertFalse(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), previousRouter));
    }

    function test_grant_rejectsMismatchedRouterDependencies() public {
        YachaRouterRoleMigrationBase.Config memory config = _config();
        MigrationDependencyStub differentWrappedNative = new MigrationDependencyStub();
        config.newRouter = address(
            new ERC1967Proxy(
                address(new YachaRouter()),
                abi.encodeCall(
                    YachaRouter.initialize,
                    (
                        address(protocolManager),
                        address(bondingCurve),
                        address(tokenRegistry),
                        address(differentWrappedNative),
                        address(v3SwapAdapter),
                        address(quoterV2)
                    )
                )
            )
        );

        vm.expectRevert("MigrateYachaRouterRole: WNATIVE mismatch");
        grantScript.runWithConfig(config);
    }

    function _config() private view returns (YachaRouterRoleMigrationBase.Config memory) {
        return YachaRouterRoleMigrationBase.Config({
            chainId: block.chainid,
            signerKey: OWNER_KEY,
            expectedSigner: owner,
            previousRouter: previousRouter,
            newRouter: newRouter,
            protocolManager: address(protocolManager)
        });
    }
}
