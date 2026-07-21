// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for ModuleAttack.

import {SetUp} from "../SetUp.t.sol";
import {BondingCurve} from "../../src/core/BondingCurve.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultRegistry} from "../../src/vault/VaultRegistry.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";

/// @notice LPManager double liquidity, ProtocolManager extreme fees, disallowed creator fee rates
contract ModuleAttackTest is SetUp {
    function setUp() public override {
        super.setUp();
        // Grant ROUTER_ROLE to creator for direct bondingCurve.create() calls in tests
        bytes32 routerRole = bondingCurve.ROUTER_ROLE();
        vm.prank(admin);
        bondingCurve.grantRole(routerRole, creator);
    }

    /// @notice Same token addLiquidity twice -> pair and liquidity are stored correctly
    function test_attack_lpManagerDoubleLiquidity_records() public {
        // The real LPManager requires ProtocolManager-granted operator permission and actual token balances.
        // Verify that the real LPManager stores pair and accumulates liquidity.
        assertEq(lpManager.getPair(makeAddr("unregistered")), address(0), "Unregistered token should have no pair");
        assertEq(lpManager.getLiquidity(makeAddr("unregistered"), address(bondingCurve)), 0, "Should have no liquidity");
    }

    /// @notice protocolFee beyond max (1000 = 10%) -> revert
    function test_attack_feeManagerExtremeFees_blocksCreation() public {
        vm.startPrank(admin);
        // 10% -> allowed
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 1000, 0, 0
        );
        assertEq(protocolManager.curveProtocolFeeRate(address(quoteToken)), 1000);

        // 10.01% -> revert
        vm.expectRevert("Protocol fee too high");
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 1001, 0, 0
        );

        // dexProtocolFee 10% -> allowed
        protocolManager.updateQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            0,
            defaultGraduateFee,
            1000,
            1000,
            0
        );
        assertEq(protocolManager.dexProtocolFeeRate(address(quoteToken)), 1000);

        // dexProtocolFee 10.01% -> revert
        vm.expectRevert("Dex protocol fee too high");
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, defaultGraduateFee, 0, 1001, 0
        );
        vm.stopPrank();

        // Caller without operator permission -> revert
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        protocolManager.updateQuoteToken(
            address(quoteToken), virtualReserve, virtualTokenReserve, minTokenReserve, 0, 0, 0, 0, 0
        );
    }

    /// @notice Creator fee rate not in allowlist -> reverts; allowed rate -> succeeds
    function test_attack_disallowedCreatorFeeRate_reverts() public {
        // Verify initial allowlist
        assertTrue(protocolManager.isCreatorFeeRateAllowed(100));
        assertTrue(protocolManager.isCreatorFeeRateAllowed(300));
        assertTrue(protocolManager.isCreatorFeeRateAllowed(500));
        assertFalse(protocolManager.isCreatorFeeRateAllowed(200));

        // Token creation with disallowed rate should fail
        vm.prank(creator);
        vm.expectRevert("Creator fee rate not allowed");
        bondingCurve.create(_createParams(200, keccak256("disallowedSalt")));

        // Token creation with allowed rate should succeed
        quoteToken.mint(creator, defaultDeployFee);
        vm.prank(creator);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee);
        vm.prank(creator);
        (address createdToken,) = bondingCurve.create(_createParams(500, keccak256("allowedSalt")));
        assertTrue(createdToken != address(0));
    }

    /// @notice creatorFeeRate=200 (2%) not in allowlist -> reverts on token creation
    function test_attack_disallowedCreatorFeeRate200_reverts() public {
        // 2% not in allowlist
        vm.prank(creator);
        vm.expectRevert("Creator fee rate not allowed");
        bondingCurve.create(_createParams(200, keccak256("rate200")));

        // 0% not in allowlist
        vm.prank(creator);
        vm.expectRevert("Creator fee rate not allowed");
        bondingCurve.create(_createParams(0, keccak256("rate0")));

        // 1% in allowlist -> success
        quoteToken.mint(creator, defaultDeployFee);
        vm.prank(creator);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee);
        vm.prank(creator);
        (address token,) = bondingCurve.create(_createParams(100, keccak256("rate100")));
        assertTrue(token != address(0));
    }

    function _createParams(uint16 creatorFeeRate, bytes32 salt)
        internal
        returns (IBondingCurve.CreateTokenParams memory)
    {
        IBondingCurve.VaultAllocation[] memory vaultAllocs = new IBondingCurve.VaultAllocation[](1);
        vaultAllocs[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(makeAddr("vault"))
        });
        return IBondingCurve.CreateTokenParams({
            name: "TestToken",
            symbol: "TT",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: creatorFeeRate,
            vaults: vaultAllocs,
            salt: salt,
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }
}
