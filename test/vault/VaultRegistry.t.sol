// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for VaultRegistry.

import {SetUp} from "../SetUp.t.sol";
import {VaultRegistry} from "../../src/vault/VaultRegistry.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract RegistryTestVault is IVault {
    function afterDeposit(address, address, uint256) external {}

    function setup(address, bytes calldata) external {}

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract VaultRegistryTest is SetUp {
    VaultRegistry public registry;
    address public alice = makeAddr("alice");
    address public vaultAddr;

    function setUp() public override {
        super.setUp();

        // Deploy a fresh VaultRegistry for isolated unit testing
        VaultRegistry impl = new VaultRegistry();
        bytes memory initData = abi.encodeCall(VaultRegistry.initialize, (address(protocolManager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = VaultRegistry(address(proxy));

        vaultAddr = address(new RegistryTestVault());
    }

    // --- Registration ---

    function test_register_success() public {
        vm.prank(admin);
        registry.register(vaultAddr, "CreatorFeeVault", "Direct transfer", IVaultRegistry.VaultType.Creator);

        assertTrue(registry.isRegistered(vaultAddr));
        assertTrue(registry.isActive(vaultAddr));

        IVaultRegistry.VaultInfo memory info = registry.getVaultInfo(vaultAddr);
        assertEq(info.name, "CreatorFeeVault");
        assertEq(info.description, "Direct transfer");
        assertEq(info.creator, admin);
        assertTrue(info.active);
        assertEq(uint8(info.vaultType), uint8(IVaultRegistry.VaultType.Creator));
    }

    function test_register_multipleVaults() public {
        address vault2 = address(new RegistryTestVault());
        vm.startPrank(admin);
        registry.register(vaultAddr, "Vault1", "Desc1", IVaultRegistry.VaultType.Creator);
        registry.register(vault2, "Vault2", "Desc2", IVaultRegistry.VaultType.Custom);
        vm.stopPrank();

        assertTrue(registry.isRegistered(vaultAddr));
        assertTrue(registry.isRegistered(vault2));
        assertTrue(registry.isActive(vault2));
    }

    function test_register_revert_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IVaultRegistry.InvalidImplementation.selector);
        registry.register(address(0), "Name", "Desc", IVaultRegistry.VaultType.Custom);
    }

    function test_register_revert_invalidInterface() public {
        address notAVault = makeAddr("notAVault");
        vm.prank(admin);
        vm.expectRevert(IVaultRegistry.InvalidImplementation.selector);
        registry.register(notAVault, "Bad", "Not a vault", IVaultRegistry.VaultType.Custom);
    }

    function test_register_revert_emptyName() public {
        vm.prank(admin);
        vm.expectRevert(IVaultRegistry.InvalidMetadata.selector);
        registry.register(vaultAddr, "", "Desc", IVaultRegistry.VaultType.Custom);
    }

    function test_register_revert_alreadyRegistered() public {
        vm.startPrank(admin);
        registry.register(vaultAddr, "Vault1", "Desc1", IVaultRegistry.VaultType.Creator);
        vm.expectRevert(IVaultRegistry.AlreadyRegistered.selector);
        registry.register(vaultAddr, "Vault1Again", "Desc2", IVaultRegistry.VaultType.Creator);
        vm.stopPrank();
    }

    function test_register_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.register(vaultAddr, "Vault", "Desc", IVaultRegistry.VaultType.Creator);
    }

    // --- Deactivation ---

    function test_setActive_deactivate() public {
        vm.prank(admin);
        registry.register(vaultAddr, "Vault", "Desc", IVaultRegistry.VaultType.Creator);

        vm.prank(admin);
        registry.setActive(vaultAddr, false);
        assertFalse(registry.isActive(vaultAddr));
    }

    function test_setActive_reactivate() public {
        vm.startPrank(admin);
        registry.register(vaultAddr, "Vault", "Desc", IVaultRegistry.VaultType.Creator);
        registry.setActive(vaultAddr, false);
        registry.setActive(vaultAddr, true);
        vm.stopPrank();
        assertTrue(registry.isActive(vaultAddr));
    }

    function test_setActive_revert_notOwner() public {
        vm.prank(admin);
        registry.register(vaultAddr, "Vault", "Desc", IVaultRegistry.VaultType.Creator);
        vm.prank(alice);
        vm.expectRevert();
        registry.setActive(vaultAddr, false);
    }

    function test_setActive_revert_notFound() public {
        vm.prank(admin);
        vm.expectRevert(IVaultRegistry.VaultNotFound.selector);
        registry.setActive(makeAddr("unregistered"), false);
    }

    // --- VaultType ---

    function test_getVaultType() public {
        address customVault = address(new RegistryTestVault());

        vm.startPrank(admin);
        registry.register(vaultAddr, "CreatorFeeVault", "Transfer", IVaultRegistry.VaultType.Creator);
        registry.register(customVault, "CustomVault", "Custom", IVaultRegistry.VaultType.Custom);
        vm.stopPrank();

        assertEq(uint8(registry.getVaultType(vaultAddr)), uint8(IVaultRegistry.VaultType.Creator));
        assertEq(uint8(registry.getVaultType(customVault)), uint8(IVaultRegistry.VaultType.Custom));
    }

    function test_getVaultType_revert_notFound() public {
        vm.expectRevert(IVaultRegistry.VaultNotFound.selector);
        registry.getVaultType(makeAddr("unregistered"));
    }

    // --- Views ---

    function test_getVaultInfo_revert_notFound() public {
        vm.expectRevert(IVaultRegistry.VaultNotFound.selector);
        registry.getVaultInfo(makeAddr("unregistered"));
    }

    function test_isRegistered_false_forUnknown() public {
        assertFalse(registry.isRegistered(makeAddr("unknown")));
    }
}
