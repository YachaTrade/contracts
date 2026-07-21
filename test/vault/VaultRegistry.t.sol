// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for VaultRegistry.

import {SetUp} from "../SetUp.t.sol";
import {VaultRegistry} from "../../src/vault/VaultRegistry.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {BurnVault} from "../../src/vault/BurnVault.sol";
import {LPVault} from "../../src/vault/LPVault.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultRegistryTest is SetUp {
    VaultRegistry public registry;
    address public alice = makeAddr("alice");
    address public burnVaultAddr;

    function setUp() public override {
        super.setUp();

        // Deploy a fresh VaultRegistry for isolated unit testing
        VaultRegistry impl = new VaultRegistry();
        bytes memory initData = abi.encodeCall(VaultRegistry.initialize, (address(protocolManager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = VaultRegistry(address(proxy));

        burnVaultAddr = address(
            new ERC1967Proxy(
                address(new BurnVault()),
                abi.encodeCall(
                    BurnVault.initialize,
                    (
                        address(protocolManager),
                        makeAddr("tokenRegistry"),
                        makeAddr("creatorFeeProcessor"),
                        makeAddr("bondingCurve"),
                        address(this),
                        ""
                    )
                )
            )
        );
    }

    // --- Registration ---

    function test_register_success() public {
        vm.prank(admin);
        registry.register(burnVaultAddr, "BurnVault", "Buyback and burn", IVaultRegistry.VaultType.Burn);

        assertTrue(registry.isRegistered(burnVaultAddr));
        assertTrue(registry.isActive(burnVaultAddr));

        IVaultRegistry.VaultInfo memory info = registry.getVaultInfo(burnVaultAddr);
        assertEq(info.name, "BurnVault");
        assertEq(info.description, "Buyback and burn");
        assertEq(info.creator, admin);
        assertTrue(info.active);
        assertEq(uint8(info.vaultType), uint8(IVaultRegistry.VaultType.Burn));
    }

    function test_register_dividendVaultType() public {
        // P5: DividendVault registers with its own appended VaultType (not Creator — that is
        // CreatorFeeVault's type). Append-only: Dividend must come after Gift.
        vm.prank(admin);
        registry.register(burnVaultAddr, "DividendVault", "Multi-token dividends", IVaultRegistry.VaultType.Dividend);

        assertEq(uint8(registry.getVaultType(burnVaultAddr)), uint8(IVaultRegistry.VaultType.Dividend));
        assertEq(
            uint8(IVaultRegistry.VaultType.Dividend),
            uint8(IVaultRegistry.VaultType.Gift) + 1,
            "Dividend appended after Gift (enum ordinals are storage commitments)"
        );
    }

    function test_register_multipleVaults() public {
        address vault2 = address(
            new ERC1967Proxy(
                address(new LPVault()),
                abi.encodeCall(
                    LPVault.initialize,
                    (address(protocolManager), makeAddr("tokenRegistry"), makeAddr("creatorFeeProcessor"), "")
                )
            )
        );
        vm.startPrank(admin);
        registry.register(burnVaultAddr, "Vault1", "Desc1", IVaultRegistry.VaultType.Burn);
        registry.register(vault2, "Vault2", "Desc2", IVaultRegistry.VaultType.LP);
        vm.stopPrank();

        assertTrue(registry.isRegistered(burnVaultAddr));
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
        registry.register(burnVaultAddr, "", "Desc", IVaultRegistry.VaultType.Custom);
    }

    function test_register_revert_alreadyRegistered() public {
        vm.startPrank(admin);
        registry.register(burnVaultAddr, "Vault1", "Desc1", IVaultRegistry.VaultType.Burn);
        vm.expectRevert(IVaultRegistry.AlreadyRegistered.selector);
        registry.register(burnVaultAddr, "Vault1Again", "Desc2", IVaultRegistry.VaultType.Burn);
        vm.stopPrank();
    }

    function test_register_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.register(burnVaultAddr, "Vault", "Desc", IVaultRegistry.VaultType.Burn);
    }

    // --- Deactivation ---

    function test_setActive_deactivate() public {
        vm.prank(admin);
        registry.register(burnVaultAddr, "Vault", "Desc", IVaultRegistry.VaultType.Burn);

        vm.prank(admin);
        registry.setActive(burnVaultAddr, false);
        assertFalse(registry.isActive(burnVaultAddr));
    }

    function test_setActive_reactivate() public {
        vm.startPrank(admin);
        registry.register(burnVaultAddr, "Vault", "Desc", IVaultRegistry.VaultType.Burn);
        registry.setActive(burnVaultAddr, false);
        registry.setActive(burnVaultAddr, true);
        vm.stopPrank();
        assertTrue(registry.isActive(burnVaultAddr));
    }

    function test_setActive_revert_notOwner() public {
        vm.prank(admin);
        registry.register(burnVaultAddr, "Vault", "Desc", IVaultRegistry.VaultType.Burn);
        vm.prank(alice);
        vm.expectRevert();
        registry.setActive(burnVaultAddr, false);
    }

    function test_setActive_revert_notFound() public {
        vm.prank(admin);
        vm.expectRevert(IVaultRegistry.VaultNotFound.selector);
        registry.setActive(makeAddr("unregistered"), false);
    }

    // --- VaultType ---

    function test_getVaultType() public {
        address lpVaultAddr = address(
            new ERC1967Proxy(
                address(new LPVault()),
                abi.encodeCall(
                    LPVault.initialize,
                    (address(protocolManager), makeAddr("tokenRegistry"), makeAddr("creatorFeeProcessor"), "")
                )
            )
        );
        address transferVault = address(
            new ERC1967Proxy(
                address(new CreatorFeeVault()),
                abi.encodeCall(
                    CreatorFeeVault.initialize,
                    (
                        address(protocolManager),
                        makeAddr("bondingCurve"),
                        makeAddr("creatorFeeProcessor"),
                        makeAddr("tokenRegistry"),
                        address(wmon),
                        ""
                    )
                )
            )
        );

        vm.startPrank(admin);
        registry.register(burnVaultAddr, "BurnVault", "Burn", IVaultRegistry.VaultType.Burn);
        registry.register(lpVaultAddr, "LPVault", "LP", IVaultRegistry.VaultType.LP);
        registry.register(transferVault, "CreatorFeeVault", "Transfer", IVaultRegistry.VaultType.Creator);
        vm.stopPrank();

        assertEq(uint8(registry.getVaultType(burnVaultAddr)), uint8(IVaultRegistry.VaultType.Burn));
        assertEq(uint8(registry.getVaultType(lpVaultAddr)), uint8(IVaultRegistry.VaultType.LP));
        assertEq(uint8(registry.getVaultType(transferVault)), uint8(IVaultRegistry.VaultType.Creator));
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
