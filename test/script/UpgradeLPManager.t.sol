// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {UpgradeLPManager} from "../../script/upgrade/normal/UpgradeLPManager.s.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {IV3LiquidityActor} from "../../src/interfaces/IV3LiquidityActor.sol";
import {IV3SwapAdapter} from "../../src/interfaces/IV3SwapAdapter.sol";

contract UpgradeLPManagerRegistryStub {}

contract UpgradeLPManagerFactoryStub {}

contract UpgradeLPManagerAdapterStub {
    address public immutable factory;
    address public immutable tokenRegistry;

    constructor(address factory_, address tokenRegistry_) {
        factory = factory_;
        tokenRegistry = tokenRegistry_;
    }
}

contract UpgradeLPManagerActorStub {
    address public immutable owner;
    address public immutable factory;
    bool public immutable compatible;

    constructor(address owner_, address factory_, bool compatible_) {
        owner = owner_;
        factory = factory_;
        compatible = compatible_;
    }

    function viewFees(address pool) external view returns (uint256, uint256) {
        if (compatible) revert IV3LiquidityActor.PositionNotFound(pool);
        return (0, 0);
    }
}

contract UpgradeLPManagerTest is Test {
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant OWNER_KEY = 0xA11CE;
    address private constant FEE_RECEIVER = address(0xFEE);

    address private owner;
    ProtocolManager private protocolManager;
    LPManager private manager;
    UpgradeLPManager private upgrade;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()), abi.encodeCall(ProtocolManager.initialize, (owner, FEE_RECEIVER))
                )
            )
        );
        manager = _deployManager(true);
        upgrade = new UpgradeLPManager();
    }

    function test_run_upgradesImplementationAndPreservesDependencies() public {
        address oldImplementation = _implementation(address(manager));
        address authorityBefore = manager.authority();
        address factoryBefore = manager.v3Factory();
        address actorBefore = manager.v3LiquidityActor();
        address processorBefore = manager.creatorFeeProcessor();
        address adapterBefore = manager.v3SwapAdapter();

        address newImplementation = upgrade.runWithConfig(_config(OWNER_KEY, owner, manager));

        assertNotEq(newImplementation, oldImplementation);
        assertEq(_implementation(address(manager)), newImplementation);
        assertEq(manager.authority(), authorityBefore);
        assertEq(manager.v3Factory(), factoryBefore);
        assertEq(manager.v3LiquidityActor(), actorBefore);
        assertEq(manager.creatorFeeProcessor(), processorBefore);
        assertEq(manager.v3SwapAdapter(), adapterBefore);
        vm.expectRevert(LPManager.InvalidPool.selector);
        manager.callStaticGetAccumulatedFees(address(0));
    }

    function test_run_rejectsSignerThatIsNotProtocolOwner() public {
        uint256 wrongKey = 0xB0B;

        vm.expectRevert("UpgradeLPManager: signer must equal PM.owner");
        upgrade.runWithConfig(_config(wrongKey, vm.addr(wrongKey), manager));
    }

    function test_run_rejectsActorWithoutExpectedViewSelector() public {
        manager = _deployManager(false);

        vm.expectRevert("UpgradeLPManager: actor viewFees mismatch");
        upgrade.runWithConfig(_config(OWNER_KEY, owner, manager));
    }

    function test_run_rejectsActorWithWrongOwner() public {
        manager = _deployManagerWithBindings(address(0xBAD), address(0), address(0), true);

        vm.expectRevert("UpgradeLPManager: actor owner mismatch");
        upgrade.runWithConfig(_config(OWNER_KEY, owner, manager));
    }

    function test_run_rejectsActorWithWrongFactory() public {
        manager = _deployManagerWithBindings(address(0), address(0xBAD), address(0), true);

        vm.expectRevert("UpgradeLPManager: actor factory mismatch");
        upgrade.runWithConfig(_config(OWNER_KEY, owner, manager));
    }

    function test_run_rejectsAdapterWithWrongFactory() public {
        manager = _deployManagerWithBindings(address(0), address(0), address(0xBAD), true);

        vm.expectRevert("UpgradeLPManager: adapter factory mismatch");
        upgrade.runWithConfig(_config(OWNER_KEY, owner, manager));
    }

    function _deployManager(bool compatibleActor) private returns (LPManager deployed) {
        return _deployManagerWithBindings(address(0), address(0), address(0), compatibleActor);
    }

    function _deployManagerWithBindings(
        address actorOwnerOverride,
        address actorFactoryOverride,
        address adapterFactoryOverride,
        bool compatibleActor
    ) private returns (LPManager deployed) {
        UpgradeLPManagerRegistryStub registry = new UpgradeLPManagerRegistryStub();
        UpgradeLPManagerFactoryStub factory = new UpgradeLPManagerFactoryStub();
        CreatorFeeProcessor processor = new CreatorFeeProcessor(address(protocolManager));
        address adapterFactory = adapterFactoryOverride == address(0) ? address(factory) : adapterFactoryOverride;
        UpgradeLPManagerAdapterStub adapter = new UpgradeLPManagerAdapterStub(adapterFactory, address(registry));

        deployed = LPManager(
            address(
                new ERC1967Proxy(
                    address(new LPManager()),
                    abi.encodeCall(
                        LPManager.initialize,
                        (address(protocolManager), address(registry), address(processor), address(adapter))
                    )
                )
            )
        );

        address actorOwner = actorOwnerOverride == address(0) ? address(deployed) : actorOwnerOverride;
        address actorFactory = actorFactoryOverride == address(0) ? address(factory) : actorFactoryOverride;
        UpgradeLPManagerActorStub actor = new UpgradeLPManagerActorStub(actorOwner, actorFactory, compatibleActor);

        if (actorOwnerOverride != address(0)) {
            vm.mockCall(address(actor), abi.encodeCall(IV3LiquidityActor.owner, ()), abi.encode(address(deployed)));
        }
        if (actorFactoryOverride != address(0)) {
            vm.mockCall(address(actor), abi.encodeCall(IV3LiquidityActor.factory, ()), abi.encode(address(factory)));
        }
        if (adapterFactoryOverride != address(0)) {
            vm.mockCall(address(adapter), abi.encodeCall(IV3SwapAdapter.factory, ()), abi.encode(address(factory)));
        }

        vm.prank(owner);
        deployed.setV3LiquidityActor(address(actor), address(factory));
        vm.clearMockedCalls();
    }

    function _config(uint256 signerKey, address multisig, LPManager proxy)
        private
        view
        returns (UpgradeLPManager.Config memory)
    {
        return UpgradeLPManager.Config({
            chainId: block.chainid,
            signerKey: signerKey,
            expectedSigner: multisig,
            proxy: address(proxy),
            protocolManager: address(protocolManager)
        });
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
