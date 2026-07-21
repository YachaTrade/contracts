// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for VaultAttack.

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";
import {ICreatorFeeProcessor} from "../../src/interfaces/ICreatorFeeProcessor.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Malicious vault that tries to reenter BondingCurve
contract ReentrantVault is IVault {
    address public target;
    bool public attacked;

    constructor(address target_) {
        target = target_;
    }

    function afterDeposit(address, address, uint256) external {
        if (!attacked) {
            attacked = true;
            (bool success,) = target.call(abi.encodeWithSignature("buy(address,address)", address(this), address(0)));
            // We expect this to fail silently (try/catch in CreatorFeeProcessor)
            success; // suppress unused warning
        }
    }

    function setup(address, bytes calldata) external {}

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Vault that reverts to test silent failure
contract RevertingVault is IVault {
    function afterDeposit(address, address, uint256) external pure {
        revert("I always revert");
    }

    function setup(address, bytes calldata) external {}

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Vault that silently accepts deposits (no-op)
contract NoopVault is IVault {
    function afterDeposit(address, address, uint256) external {}

    function setup(address, bytes calldata) external {}

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract VaultAttackTest is SetUp {
    address public attacker;
    address public teamWallet;

    CreatorFeeVault public creatorFeeVaultImpl;

    function setUp() public override {
        super.setUp();

        attacker = makeAddr("attacker");
        teamWallet = makeAddr("teamWallet");

        // Deploy a separate CreatorFeeVault via UUPS proxy for attack tests (SetUp's creatorFeeVault is already registered)
        creatorFeeVaultImpl = CreatorFeeVault(
            payable(address(
                    new ERC1967Proxy(
                        address(new CreatorFeeVault()),
                        abi.encodeCall(
                            CreatorFeeVault.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(creatorFeeProcessor),
                                address(tokenRegistry),
                                address(wmon),
                                ""
                            )
                        )
                    )
                ))
        );

        vm.startPrank(admin);
        vaultRegistry.register(
            address(creatorFeeVaultImpl), "AttackCreatorFeeVault", "Attack test vault", IVaultRegistry.VaultType.Creator
        );
        // Grant ROUTER_ROLE to creator for direct bondingCurve.create() calls in tests
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), creator);
        vm.stopPrank();

        quoteToken.mint(creator, 1000 ether);
        quoteToken.mint(attacker, 1000 ether);
    }

    function test_attack_deactivatedVault_cannotBeSelected() public {
        vm.prank(admin);
        vaultRegistry.setActive(address(creatorFeeVaultImpl), false);

        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVaultImpl), bps: 10000, setupData: abi.encode(teamWallet)
        });

        IBondingCurve.CreateTokenParams memory params = IBondingCurve.CreateTokenParams({
            name: "DeactToken",
            symbol: "DT",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: keccak256("deact-attack"),
            dexType: ITokenRegistry.DexType.UniswapV3,
            creator: address(this),
            buyQuoteAmount: 0
        });

        // Transfer deployFee before create (balance detection)
        vm.prank(creator);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee);
        vm.prank(creator);
        vm.expectRevert("Vault not active");
        bondingCurve.create(params);
    }

    function test_attack_vaultCloneSaltCollision() public {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVaultImpl), bps: 10000, setupData: abi.encode(teamWallet)
        });

        IBondingCurve.CreateTokenParams memory params1 = IBondingCurve.CreateTokenParams({
            name: "Token1",
            symbol: "T1",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: keccak256("collision-salt"),
            dexType: ITokenRegistry.DexType.UniswapV3,
            creator: address(this),
            buyQuoteAmount: 0
        });

        vm.prank(creator);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee);
        vm.prank(creator);
        bondingCurve.create(params1);

        // Same salt reverts (CREATE2 collision)
        IBondingCurve.CreateTokenParams memory params2 = IBondingCurve.CreateTokenParams({
            name: "Token2",
            symbol: "T2",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: keccak256("collision-salt"),
            dexType: ITokenRegistry.DexType.UniswapV3,
            creator: address(this),
            buyQuoteAmount: 0
        });

        vm.prank(creator);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee);
        vm.prank(creator);
        vm.expectRevert();
        bondingCurve.create(params2);
    }

    function test_attack_revertingVault_blocksDistribution() public {
        NoopVault goodVault = new NoopVault();

        // Deploy a processor and authorize this test for its setup and processing selectors.
        CreatorFeeProcessor processor = new CreatorFeeProcessor(address(protocolManager));
        vm.startPrank(admin);
        protocolManager.setOperatorPermission(
            address(this), address(processor), ICreatorFeeProcessor.setup.selector, true
        );
        protocolManager.setOperatorPermission(
            address(this), address(processor), ICreatorFeeProcessor.processCreatorFee.selector, true
        );
        vm.stopPrank();

        ICreatorFeeProcessor.VaultSlot[] memory slots = new ICreatorFeeProcessor.VaultSlot[](2);
        slots[0] = ICreatorFeeProcessor.VaultSlot({vault: address(new RevertingVault()), bps: 5000});
        slots[1] = ICreatorFeeProcessor.VaultSlot({vault: address(goodVault), bps: 5000});

        // Create a dedicated MockERC20 as creatorFeeToken for this test
        MockERC20 creatorFeeTokenMock = new MockERC20("TAX", "TAX", 18);
        processor.setup(address(creatorFeeTokenMock), slots);

        // Mint quoteToken to this contract, approve processor, call processCreatorFee
        uint256 amount = 100 ether;
        quoteToken.mint(address(this), amount);
        quoteToken.approve(address(processor), amount);
        vm.expectRevert("I always revert");
        processor.processCreatorFee(address(creatorFeeTokenMock), address(quoteToken), amount);

        assertEq(quoteToken.balanceOf(address(goodVault)), 0, "goodVault should not receive quote after revert");
        assertEq(quoteToken.balanceOf(address(this)), amount, "sender quote should roll back");
        assertEq(quoteToken.balanceOf(address(processor)), 0, "processor should retain no quote");
    }

    function test_attack_nonexistentVaultType_reverts() public {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: makeAddr("nonexistent"), bps: 10000, setupData: abi.encode(teamWallet)
        });

        IBondingCurve.CreateTokenParams memory params = IBondingCurve.CreateTokenParams({
            name: "BadType",
            symbol: "BT",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: 500,
            vaults: vaults,
            salt: keccak256("bad-type"),
            dexType: ITokenRegistry.DexType.UniswapV3,
            creator: address(this),
            buyQuoteAmount: 0
        });

        vm.prank(creator);
        quoteToken.transfer(address(bondingCurve), defaultDeployFee);
        vm.prank(creator);
        vm.expectRevert();
        bondingCurve.create(params);
    }

    function test_attack_nonAdmin_cannotDeactivate() public {
        vm.prank(attacker);
        vm.expectRevert();
        vaultRegistry.setActive(address(creatorFeeVaultImpl), false);
    }
}
