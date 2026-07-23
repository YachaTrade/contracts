// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeployLens} from "../../script/deploy/normal/DeployLens.s.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {Lens} from "../../src/lens/Lens.sol";
import {SetUp} from "../SetUp.t.sol";

contract DeployLensDependencyStub {}

contract DeployLensHarness is DeployLens {
    function validateInputs(
        uint256 deployerPrivateKey,
        address deployer,
        address giwaRouter,
        address bondingCurve,
        address tokenRegistry,
        address protocolManager,
        uint256 chainId
    ) external view {
        _validateInputs(deployerPrivateKey, deployer, giwaRouter, bondingCurve, tokenRegistry, protocolManager, chainId);
    }

    function deployLens(address giwaRouter, address bondingCurve, address tokenRegistry, address protocolManager)
        external
        returns (address lensAddress)
    {
        Lens lens = _deployLens(giwaRouter);
        _verifyLens(lens, giwaRouter, bondingCurve, tokenRegistry, protocolManager);
        lensAddress = address(lens);
    }
}

contract DeployLensTest is SetUp {
    uint256 private constant DEPLOYER_PRIVATE_KEY = 0xA11CE;

    DeployLensHarness private harness;
    address private deployer;

    function setUp() public override {
        super.setUp();
        deployer = vm.addr(DEPLOYER_PRIVATE_KEY);
        harness = new DeployLensHarness();
    }

    function test_deployLensWiresConfiguredRouterProxy() public {
        harness.validateInputs(
            DEPLOYER_PRIVATE_KEY,
            deployer,
            address(giwaRouter),
            address(bondingCurve),
            address(tokenRegistry),
            address(protocolManager),
            block.chainid
        );

        address deployed = harness.deployLens(
            address(giwaRouter), address(bondingCurve), address(tokenRegistry), address(protocolManager)
        );

        Lens lens = Lens(deployed);
        assertGt(deployed.code.length, 0);
        assertEq(address(lens.giwaRouter()), address(giwaRouter));
        assertEq(lens.curve(), address(bondingCurve));
        assertEq(lens.curveRouter(), address(giwaRouter));
        assertEq(lens.dexRouter(), address(giwaRouter));
        assertEq(lens.tokenRegistry(), address(tokenRegistry));
    }

    function test_runDeploysFromConfiguredSignerAndWiresDependencies() public {
        vm.setEnv("PRIVATE_KEY", vm.toString(DEPLOYER_PRIVATE_KEY));
        vm.setEnv("DEPLOYER", vm.toString(deployer));
        vm.setEnv("GIWA_ROUTER", vm.toString(address(giwaRouter)));
        vm.setEnv("BONDING_CURVE", vm.toString(address(bondingCurve)));
        vm.setEnv("TOKEN_REGISTRY", vm.toString(address(tokenRegistry)));
        vm.setEnv("PROTOCOL_MANAGER", vm.toString(address(protocolManager)));
        vm.setEnv("CHAIN_ID", vm.toString(block.chainid));
        uint64 deployerNonceBefore = vm.getNonce(deployer);

        address deployed = harness.run();

        Lens lens = Lens(deployed);
        assertEq(vm.getNonce(deployer), deployerNonceBefore + 1);
        assertEq(address(lens.giwaRouter()), address(giwaRouter));
        assertEq(lens.curve(), address(bondingCurve));
        assertEq(lens.tokenRegistry(), address(tokenRegistry));
    }

    function test_validateInputsRejectsChainIdMismatch() public {
        vm.expectRevert("DeployLens: CHAIN_ID mismatch");
        harness.validateInputs(
            DEPLOYER_PRIVATE_KEY,
            deployer,
            address(giwaRouter),
            address(bondingCurve),
            address(tokenRegistry),
            address(protocolManager),
            block.chainid + 1
        );
    }

    function test_validateInputsRejectsPrivateKeyDeployerMismatch() public {
        vm.expectRevert("DeployLens: PRIVATE_KEY does not match DEPLOYER env");
        harness.validateInputs(
            DEPLOYER_PRIVATE_KEY,
            makeAddr("wrongDeployer"),
            address(giwaRouter),
            address(bondingCurve),
            address(tokenRegistry),
            address(protocolManager),
            block.chainid
        );
    }

    function test_validateInputsRejectsCodeLessRouter() public {
        vm.expectRevert("DeployLens: GIWA_ROUTER missing code");
        harness.validateInputs(
            DEPLOYER_PRIVATE_KEY,
            deployer,
            makeAddr("codeLessRouter"),
            address(bondingCurve),
            address(tokenRegistry),
            address(protocolManager),
            block.chainid
        );
    }

    function test_validateInputsRejectsRouterImplementation() public {
        GiwaRouter implementation = new GiwaRouter();

        vm.expectRevert("DeployLens: GIWA_ROUTER is not an ERC1967 proxy");
        harness.validateInputs(
            DEPLOYER_PRIVATE_KEY,
            deployer,
            address(implementation),
            address(bondingCurve),
            address(tokenRegistry),
            address(protocolManager),
            block.chainid
        );
    }

    function test_validateInputsRejectsWrongInitializedRouterProxy() public {
        DeployLensDependencyStub wrongBondingCurve = new DeployLensDependencyStub();
        GiwaRouter implementation = new GiwaRouter();
        GiwaRouter wrongRouter = GiwaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            GiwaRouter.initialize,
                            (
                                address(protocolManager),
                                address(wrongBondingCurve),
                                address(tokenRegistry),
                                address(wnative),
                                address(v3SwapAdapter),
                                address(quoterV2)
                            )
                        )
                    )
                ))
        );

        vm.expectRevert("DeployLens: BONDING_CURVE mismatch");
        harness.validateInputs(
            DEPLOYER_PRIVATE_KEY,
            deployer,
            address(wrongRouter),
            address(bondingCurve),
            address(tokenRegistry),
            address(protocolManager),
            block.chainid
        );
    }

    function test_validateInputsRejectsSameDependencyRouterWithoutCurveRole() public {
        GiwaRouter implementation = new GiwaRouter();
        GiwaRouter unauthorizedRouter = GiwaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            GiwaRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wnative),
                                address(v3SwapAdapter),
                                address(quoterV2)
                            )
                        )
                    )
                ))
        );

        vm.expectRevert("DeployLens: GIWA_ROUTER missing curve role");
        harness.validateInputs(
            DEPLOYER_PRIVATE_KEY,
            deployer,
            address(unauthorizedRouter),
            address(bondingCurve),
            address(tokenRegistry),
            address(protocolManager),
            block.chainid
        );
    }

    function test_validateInputsRejectsExpectedDependencyWithoutCode() public {
        vm.expectRevert("DeployLens: BONDING_CURVE missing code");
        harness.validateInputs(
            DEPLOYER_PRIVATE_KEY,
            deployer,
            address(giwaRouter),
            makeAddr("codeLessBondingCurve"),
            address(tokenRegistry),
            address(protocolManager),
            block.chainid
        );
    }

    function test_validateInputsRejectsDependencyMismatch() public {
        DeployLensDependencyStub otherProtocolManager = new DeployLensDependencyStub();

        vm.expectRevert("DeployLens: PROTOCOL_MANAGER mismatch");
        harness.validateInputs(
            DEPLOYER_PRIVATE_KEY,
            deployer,
            address(giwaRouter),
            address(bondingCurve),
            address(tokenRegistry),
            address(otherProtocolManager),
            block.chainid
        );
    }
}
