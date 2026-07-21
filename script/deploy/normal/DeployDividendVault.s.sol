// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {UniswapV2ExternalAdapter} from "../../../src/adapters/UniswapV2ExternalAdapter.sol";
import {UniswapV3ExternalAdapter} from "../../../src/adapters/UniswapV3ExternalAdapter.sol";
import {DividendVault} from "../../../src/vault/DividendVault.sol";
import {VaultRegistry} from "../../../src/vault/VaultRegistry.sol";
import {IProtocolManager} from "../../../src/interfaces/IProtocolManager.sol";
import {IVaultRegistry} from "../../../src/interfaces/IVaultRegistry.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";

/// @title DeployDividendVault
/// @notice Testnet direct-broadcast flow for deploying DividendVault when the ProtocolManager owner is an EOA.
///         Deployer EOA broadcasts deployments, then the ProtocolManager owner EOA broadcasts all admin wiring.
///
/// Required env:
///   PRIVATE_KEY                    - deployer EOA key (deploys impl + proxy + VaultRegistry impl + adapters)
///   DEPLOYER                       - expected deployer address (sanity guard vs PRIVATE_KEY)
///   MULTISIG_PRIVATE_KEY           - current ProtocolManager owner key (broadcasts admin wiring)
///   V2_PROTOCOL_MANAGER            - ProtocolManager UUPS proxy address
///   V2_TOKEN_REGISTRY              - TokenRegistry UUPS proxy address
///   V2_CREATOR_FEE_PROCESSOR       - CreatorFeeProcessor singleton address
///   V2_BONDING_CURVE               - BondingCurve UUPS proxy address
///   V2_NAD_FUN_ROUTER              - NadFunRouter UUPS proxy address used by DividendVault router hops
///   V2_NAD_SWAP_ADAPTER            - existing NadSwap singleton reused as the general-pool lane
///   V1_BONDING_CURVE               - V1 BondingCurve address for DividendVault admission checks
///   V2_VAULT_REGISTRY              - VaultRegistry UUPS proxy address
///   WMON                           - wrapped native token address
///   MERKLE_BOT                     - EOA for the Merkle root (setMerkleRoot) permission
///   CONVERSION_BOT                 - EOA for the conversion (executeConversion) permission
///   DIVIDEND_VAULT_METADATA_URI    - metadata URI stored in DividendVault
///
/// Run:
///   source .env.testnet && forge script script/DeployDividendVault.s.sol:DeployDividendVault --rpc-url $RPC_URL --broadcast
contract DeployDividendVault is Script {
    struct Config {
        address protocolManager;
        address tokenRegistry;
        address creatorFeeProcessor;
        address bondingCurve;
        address router;
        address nadSwapAdapter;
        address bondingCurveV1;
        address vaultRegistry;
        address wmon;
        address merkleBot;
        address conversionBot;
        string metadataURI;
    }

    struct Deployed {
        address dividendVaultImpl;
        address dividendVault;
        address vaultRegistryImpl;
        address uniswapV2ExternalAdapter;
        address uniswapV3ExternalAdapter;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 multisigKey = vm.envUint("MULTISIG_PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");

        address deployer = vm.addr(deployerKey);
        address multisig = vm.addr(multisigKey);
        require(deployer == deployerEnv, "Deploy: PRIVATE_KEY does not match DEPLOYER env");

        Config memory config = _readConfig();
        _validateConfig(config, deployerEnv);
        require(
            ProtocolManager(config.protocolManager).owner() == multisig,
            "Deploy: MULTISIG_PRIVATE_KEY signer must be current ProtocolManager owner"
        );

        Deployed memory deployed = _deploy(deployerKey, config);
        _wire(multisigKey, config, deployed);
        _verify(config, deployed);
        _logDeployment(config, deployed, multisig);
    }

    function _readConfig() internal view returns (Config memory config) {
        config.protocolManager = vm.envAddress("V2_PROTOCOL_MANAGER");
        config.tokenRegistry = vm.envAddress("V2_TOKEN_REGISTRY");
        config.creatorFeeProcessor = vm.envAddress("V2_CREATOR_FEE_PROCESSOR");
        config.bondingCurve = vm.envAddress("V2_BONDING_CURVE");
        config.router = vm.envAddress("V2_NAD_FUN_ROUTER");
        config.nadSwapAdapter = vm.envAddress("V2_NAD_SWAP_ADAPTER");
        config.bondingCurveV1 = vm.envAddress("V1_BONDING_CURVE");
        config.vaultRegistry = vm.envAddress("V2_VAULT_REGISTRY");
        config.wmon = vm.envAddress("WMON");
        config.merkleBot = vm.envAddress("MERKLE_BOT");
        config.conversionBot = vm.envAddress("CONVERSION_BOT");
        config.metadataURI = vm.envString("DIVIDEND_VAULT_METADATA_URI");
    }

    function _validateConfig(Config memory config, address deployerEnv) internal pure {
        require(deployerEnv != address(0), "Deploy: DEPLOYER zero");
        require(config.protocolManager != address(0), "Deploy: V2_PROTOCOL_MANAGER zero");
        require(config.tokenRegistry != address(0), "Deploy: V2_TOKEN_REGISTRY zero");
        require(config.creatorFeeProcessor != address(0), "Deploy: V2_CREATOR_FEE_PROCESSOR zero");
        require(config.bondingCurve != address(0), "Deploy: V2_BONDING_CURVE zero");
        require(config.router != address(0), "Deploy: V2_NAD_FUN_ROUTER zero");
        require(config.nadSwapAdapter != address(0), "Deploy: V2_NAD_SWAP_ADAPTER zero");
        require(config.bondingCurveV1 != address(0), "Deploy: V1_BONDING_CURVE zero");
        require(config.vaultRegistry != address(0), "Deploy: V2_VAULT_REGISTRY zero");
        require(config.wmon != address(0), "Deploy: WMON zero");
        require(config.merkleBot != address(0), "Deploy: MERKLE_BOT zero");
        require(config.conversionBot != address(0), "Deploy: CONVERSION_BOT zero");
        require(config.merkleBot != config.conversionBot, "Deploy: MERKLE_BOT and CONVERSION_BOT must differ");
    }

    function _deploy(uint256 deployerKey, Config memory config) internal returns (Deployed memory deployed) {
        vm.startBroadcast(deployerKey);

        DividendVault dividendVaultImpl = new DividendVault();
        ERC1967Proxy dividendVaultProxy = new ERC1967Proxy(
            address(dividendVaultImpl),
            abi.encodeCall(
                DividendVault.initialize,
                (
                    config.protocolManager,
                    config.tokenRegistry,
                    config.creatorFeeProcessor,
                    config.bondingCurve,
                    config.router,
                    config.bondingCurveV1,
                    config.metadataURI
                )
            )
        );
        VaultRegistry vaultRegistryImpl = new VaultRegistry();
        UniswapV2ExternalAdapter uniswapV2ExternalAdapter = new UniswapV2ExternalAdapter();
        UniswapV3ExternalAdapter uniswapV3ExternalAdapter = new UniswapV3ExternalAdapter();

        vm.stopBroadcast();

        deployed.dividendVaultImpl = address(dividendVaultImpl);
        deployed.dividendVault = address(dividendVaultProxy);
        deployed.vaultRegistryImpl = address(vaultRegistryImpl);
        deployed.uniswapV2ExternalAdapter = address(uniswapV2ExternalAdapter);
        deployed.uniswapV3ExternalAdapter = address(uniswapV3ExternalAdapter);
    }

    function _wire(uint256 multisigKey, Config memory config, Deployed memory deployed) internal {
        vm.startBroadcast(multisigKey);

        UUPSUpgradeable(config.vaultRegistry).upgradeToAndCall(deployed.vaultRegistryImpl, "");
        IVaultRegistry(config.vaultRegistry)
            .register(
                deployed.dividendVault, "DividendVault", "Multi-token dividends", IVaultRegistry.VaultType.Dividend
            );
        IProtocolManager(config.protocolManager)
            .setOperatorPermission(config.merkleBot, deployed.dividendVault, DividendVault.setMerkleRoot.selector, true);
        IProtocolManager(config.protocolManager)
            .setOperatorPermission(
                config.conversionBot, deployed.dividendVault, DividendVault.executeConversion.selector, true
            );
        DividendVault(payable(deployed.dividendVault))
            .setAdapters(config.nadSwapAdapter, deployed.uniswapV2ExternalAdapter, deployed.uniswapV3ExternalAdapter);
        DividendVault(payable(deployed.dividendVault)).setWmon(config.wmon);

        vm.stopBroadcast();
    }

    function _verify(Config memory config, Deployed memory deployed) internal view {
        require(
            IVaultRegistry(config.vaultRegistry).isRegistered(deployed.dividendVault), "Verify: vault not registered"
        );
        require(
            IVaultRegistry(config.vaultRegistry).getVaultType(deployed.dividendVault)
                == IVaultRegistry.VaultType.Dividend,
            "Verify: vault type mismatch"
        );

        (bool merkleAllowed,) = ProtocolManager(config.protocolManager)
            .canCall(config.merkleBot, deployed.dividendVault, DividendVault.setMerkleRoot.selector);
        require(merkleAllowed, "Verify: MERKLE_BOT missing setMerkleRoot permission");

        (bool conversionAllowed,) = ProtocolManager(config.protocolManager)
            .canCall(config.conversionBot, deployed.dividendVault, DividendVault.executeConversion.selector);
        require(conversionAllowed, "Verify: CONVERSION_BOT missing executeConversion permission");

        DividendVault dividendVault = DividendVault(payable(deployed.dividendVault));
        require(dividendVault.router() == config.router, "Verify: router mismatch");
        require(address(dividendVault.bondingCurveV1()) == config.bondingCurveV1, "Verify: bondingCurveV1 mismatch");
        require(address(dividendVault.nadSwapAdapter()) == config.nadSwapAdapter, "Verify: nadSwapAdapter mismatch");
        require(
            address(dividendVault.uniswapV2Adapter()) == deployed.uniswapV2ExternalAdapter,
            "Verify: uniswapV2Adapter mismatch"
        );
        require(
            address(dividendVault.uniswapV3Adapter()) == deployed.uniswapV3ExternalAdapter,
            "Verify: uniswapV3Adapter mismatch"
        );
        require(dividendVault.wmon() == config.wmon, "Verify: WMON mismatch");
    }

    function _logDeployment(Config memory config, Deployed memory deployed, address multisig) internal pure {
        console.log("========================================");
        console.log("DividendVault deployed (direct EOA broadcast)");
        console.log("========================================");
        console.log("Impl:                       ", deployed.dividendVaultImpl);
        console.log("Proxy:                      ", deployed.dividendVault);
        console.log("VaultRegistry new impl:     ", deployed.vaultRegistryImpl);
        console.log("UniswapV2ExternalAdapter:   ", deployed.uniswapV2ExternalAdapter);
        console.log("UniswapV3ExternalAdapter:   ", deployed.uniswapV3ExternalAdapter);
        console.log("ProtocolManager:            ", config.protocolManager);
        console.log("TokenRegistry:              ", config.tokenRegistry);
        console.log("CreatorFeeProcessor:        ", config.creatorFeeProcessor);
        console.log("BondingCurve:               ", config.bondingCurve);
        console.log("Router:                     ", config.router);
        console.log("NadSwapAdapter:             ", config.nadSwapAdapter);
        console.log("BondingCurveV1:             ", config.bondingCurveV1);
        console.log("VaultRegistry:              ", config.vaultRegistry);
        console.log("WMON:                       ", config.wmon);
        console.log("Merkle bot (setMerkleRoot): ", config.merkleBot);
        console.log("Conversion bot (executeConversion):", config.conversionBot);
        console.log("ProtocolManager owner EOA:  ", multisig);
        console.log("========================================");
    }
}
