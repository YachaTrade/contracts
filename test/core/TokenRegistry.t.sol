// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";

/// @notice Unit tests for TokenRegistry zero-address guards on `register`.
contract TokenRegistryTest is Test {
    TokenRegistry public registry;
    ProtocolManager public protocolManager;

    address constant TOKEN = address(0x1111);
    address constant PAIR = address(0x2222);
    address constant QUOTE = address(0x3333);
    address constant REGISTRAR = address(0xabcd);

    function setUp() public {
        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), address(0xfee)))
                )
            )
        );

        registry = TokenRegistry(
            address(
                new ERC1967Proxy(
                    address(new TokenRegistry()), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager)))
                )
            )
        );

        // Allow REGISTRAR to call register().
        protocolManager.setOperatorPermission(REGISTRAR, address(registry), TokenRegistry.register.selector, true);
    }

    function test_register_reverts_onZeroToken() public {
        vm.prank(REGISTRAR);
        vm.expectRevert(TokenRegistry.ZeroAddress.selector);
        registry.register(address(0), PAIR, QUOTE, ITokenRegistry.DexType.UniswapV2);
    }

    function test_register_reverts_onZeroPair() public {
        vm.prank(REGISTRAR);
        vm.expectRevert(TokenRegistry.ZeroAddress.selector);
        registry.register(TOKEN, address(0), QUOTE, ITokenRegistry.DexType.UniswapV2);
    }

    function test_register_reverts_onZeroQuoteToken() public {
        vm.prank(REGISTRAR);
        vm.expectRevert(TokenRegistry.ZeroAddress.selector);
        registry.register(TOKEN, PAIR, address(0), ITokenRegistry.DexType.UniswapV2);
    }

    function test_register_succeeds_onAllNonZero() public {
        vm.prank(REGISTRAR);
        registry.register(TOKEN, PAIR, QUOTE, ITokenRegistry.DexType.UniswapV2);

        assertTrue(registry.isRegistered(TOKEN));
        assertEq(registry.getPair(TOKEN), PAIR);
        assertEq(registry.getQuoteToken(TOKEN), QUOTE);
    }

    function test_register_reverts_onReRegister() public {
        vm.prank(REGISTRAR);
        registry.register(TOKEN, PAIR, QUOTE, ITokenRegistry.DexType.UniswapV2);

        vm.prank(REGISTRAR);
        vm.expectRevert(TokenRegistry.AlreadyRegistered.selector);
        registry.register(TOKEN, PAIR, QUOTE, ITokenRegistry.DexType.UniswapV2);
    }
}
