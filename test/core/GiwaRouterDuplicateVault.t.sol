// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BondingCurve} from "../../src/core/BondingCurve.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {Token} from "../../src/token/Token.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";
import {VaultRegistry} from "../../src/vault/VaultRegistry.sol";
import {MockWrappedNative} from "../mocks/MockWrappedNative.sol";

contract DuplicateVaultPool {}

contract DuplicateVaultPoolDeployer {
    address private immutable POOL = address(new DuplicateVaultPool());

    function createPool(address, address) external view returns (address) {
        return POOL;
    }
}

contract DuplicateVaultSwapAdapterStub {
    address public immutable factory;
    address public immutable tokenRegistry;

    constructor(address factory_, address tokenRegistry_) {
        factory = factory_;
        tokenRegistry = tokenRegistry_;
    }
}

contract DuplicateVaultQuoterStub {
    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }
}

contract GiwaRouterDuplicateVaultTest is Test {
    uint256 private constant VIRTUAL_RESERVE = 70_000 ether;
    uint256 private constant VIRTUAL_TOKEN_RESERVE = 1_060_569_000 ether;
    uint256 private constant MIN_TOKEN_RESERVE = 251_660_440_677_966_101_694_915_255;

    GiwaRouter private router;
    MockWrappedNative private wnative;
    CreatorFeeVault private creatorFeeVault;

    function setUp() public {
        ProtocolManager protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), makeAddr("feeReceiver")))
                )
            )
        );

        wnative = new MockWrappedNative();
        protocolManager.addQuoteToken(
            address(wnative), VIRTUAL_RESERVE, VIRTUAL_TOKEN_RESERVE, MIN_TOKEN_RESERVE, 0, 1_000 ether, 100, 35
        );
        protocolManager.setV3QuoteConfig(address(wnative), 3_000, 5_000);

        TokenRegistry tokenRegistry = TokenRegistry(
            address(
                new ERC1967Proxy(
                    address(new TokenRegistry()), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager)))
                )
            )
        );
        BondingCurve bondingCurve = BondingCurve(
            address(
                new ERC1967Proxy(
                    address(new BondingCurve()),
                    abi.encodeCall(
                        BondingCurve.initialize, (address(this), address(new Token()), address(protocolManager))
                    )
                )
            )
        );
        VaultRegistry vaultRegistry = VaultRegistry(
            address(
                new ERC1967Proxy(
                    address(new VaultRegistry()), abi.encodeCall(VaultRegistry.initialize, (address(protocolManager)))
                )
            )
        );
        CreatorFeeProcessor creatorFeeProcessor = new CreatorFeeProcessor(address(protocolManager));
        creatorFeeVault = CreatorFeeVault(
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
                                address(wnative),
                                "creator-fee-vault"
                            )
                        )
                    )
                ))
        );

        address factory = address(new DuplicateVaultPool());
        address swapAdapter = address(new DuplicateVaultSwapAdapterStub(factory, address(tokenRegistry)));
        address quoter = address(new DuplicateVaultQuoterStub(factory));
        router = GiwaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(new GiwaRouter()),
                        abi.encodeCall(
                            GiwaRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wnative),
                                swapAdapter,
                                quoter
                            )
                        )
                    )
                ))
        );

        bondingCurve.setModule(bondingCurve.MODULE_TOKEN_REGISTRY(), address(tokenRegistry));
        bondingCurve.setModule(bondingCurve.MODULE_VAULT_REGISTRY(), address(vaultRegistry));
        bondingCurve.setModule(bondingCurve.MODULE_CREATOR_FEE_PROCESSOR(), address(creatorFeeProcessor));
        bondingCurve.setModule(bondingCurve.MODULE_V3_POOL_DEPLOYER(), address(new DuplicateVaultPoolDeployer()));
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(router));

        protocolManager.setOperatorPermission(
            address(bondingCurve), address(tokenRegistry), TokenRegistry.registerV3.selector, true
        );
        protocolManager.setOperatorPermission(
            address(bondingCurve), address(creatorFeeProcessor), CreatorFeeProcessor.setup.selector, true
        );
        vaultRegistry.register(
            address(creatorFeeVault), "CreatorFeeVault", "Creator fee recipient", IVaultRegistry.VaultType.Creator
        );
    }

    function test_create_revertsOnDuplicateCreatorFeeVaultAllocation() public {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](2);
        bytes memory setupData = abi.encode(address(this));
        vaults[0] = IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 5_000, setupData: setupData});
        vaults[1] = IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 5_000, setupData: setupData});

        vm.expectRevert(IBondingCurve.DuplicateVault.selector);
        router.create(
            IGiwaRouter.CreateParams({
                name: "Duplicate Vault",
                symbol: "DUP",
                tokenURI: "",
                quoteToken: address(wnative),
                vaults: vaults,
                salt: keccak256("duplicate-creator-fee-vault"),
                dexType: ITokenRegistry.DexType.UniswapV3,
                buyQuoteAmount: 0,
                deadline: block.timestamp
            })
        );
    }
}
