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

/// @title DeployDividendVaultSafe
/// @notice Mainnet deploy flow when the ProtocolManager owner is a Safe (Gnosis Safe)
///         multisig that cannot directly sign forge broadcasts.
///
/// Flow:
///   1. Deployer EOA broadcasts: deploy DividendVault impl + ERC1967Proxy,
///      VaultRegistry impl, UniswapV2ExternalAdapter, and UniswapV3ExternalAdapter.
///   2. Script prints multisig calldatas (target + data) that the Safe owners
///      must submit via Safe Transaction Builder (or Safe SDK / API).
///   3. Safe executes the VaultRegistry implementation upgrade before registering
///      DividendVault, because the old implementation cannot decode VaultType.Dividend.
///   4. Safe grants MERKLE_BOT the Merkle-root permission and CONVERSION_BOT the conversion permission.
///   5. Safe wires the external adapter allowlist lanes and WMON claim unwrap token.
///
/// Required env:
///   PRIVATE_KEY                    - deployer EOA key (deploys impl + proxy + VaultRegistry impl + adapters)
///   DEPLOYER                       - expected deployer address (sanity guard)
///   MULTISIG                       - Safe multisig address (current ProtocolManager owner)
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
///   source .env.mainnet && forge script script/DeployDividendVaultSafe.s.sol:DeployDividendVaultSafe \
///       --rpc-url $RPC_URL --broadcast
///
/// After it succeeds, follow the printed Safe transactions section to finish wiring.
contract DeployDividendVaultSafe is Script {
    struct Config {
        address multisig;
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

    struct SafeCalls {
        bytes upgradeVaultRegistryCall;
        bytes registerCall;
        bytes grantMerkleBotCall;
        bytes grantExecuteConversionCall;
        bytes setAdaptersCall;
        bytes setWmonCall;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");
        require(vm.addr(deployerKey) == deployerEnv, "Deploy: PRIVATE_KEY does not match DEPLOYER env");

        Config memory config = _readConfig();
        _validateConfig(config);

        Deployed memory deployed = _deploy(deployerKey, config);
        SafeCalls memory calls = _buildSafeCalls(config, deployed);

        _logDeployment(config, deployed);
        _logSafeCalls(config, deployed, calls);
    }

    function _readConfig() internal view returns (Config memory config) {
        config.multisig = vm.envAddress("MULTISIG");
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

    function _validateConfig(Config memory config) internal pure {
        require(config.multisig != address(0), "Deploy: MULTISIG zero");
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
        UniswapV2ExternalAdapter uniswapV2ExternalAdapter = new UniswapV2ExternalAdapter();
        UniswapV3ExternalAdapter uniswapV3ExternalAdapter = new UniswapV3ExternalAdapter();
        VaultRegistry vaultRegistryImpl = new VaultRegistry();

        vm.stopBroadcast();

        deployed.dividendVaultImpl = address(dividendVaultImpl);
        deployed.dividendVault = address(dividendVaultProxy);
        deployed.vaultRegistryImpl = address(vaultRegistryImpl);
        deployed.uniswapV2ExternalAdapter = address(uniswapV2ExternalAdapter);
        deployed.uniswapV3ExternalAdapter = address(uniswapV3ExternalAdapter);
    }

    function _buildSafeCalls(Config memory config, Deployed memory deployed)
        internal
        pure
        returns (SafeCalls memory calls)
    {
        calls.upgradeVaultRegistryCall =
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (deployed.vaultRegistryImpl, ""));
        calls.registerCall = abi.encodeCall(
            IVaultRegistry.register,
            (deployed.dividendVault, "DividendVault", "Multi-token dividends", IVaultRegistry.VaultType.Dividend)
        );
        calls.grantMerkleBotCall = abi.encodeCall(
            IProtocolManager.setOperatorPermission,
            (config.merkleBot, deployed.dividendVault, DividendVault.setMerkleRoot.selector, true)
        );
        calls.grantExecuteConversionCall = abi.encodeCall(
            IProtocolManager.setOperatorPermission,
            (config.conversionBot, deployed.dividendVault, DividendVault.executeConversion.selector, true)
        );
        calls.setAdaptersCall = abi.encodeCall(
            DividendVault.setAdapters,
            (config.nadSwapAdapter, deployed.uniswapV2ExternalAdapter, deployed.uniswapV3ExternalAdapter)
        );
        calls.setWmonCall = abi.encodeCall(DividendVault.setWmon, (config.wmon));
    }

    function _logDeployment(Config memory config, Deployed memory deployed) internal pure {
        console.log("========================================");
        console.log("DividendVault deployed (impl + proxy + VaultRegistry impl + external adapters)");
        console.log("========================================");
        console.log("Impl:                       ", deployed.dividendVaultImpl);
        console.log("Proxy:                      ", deployed.dividendVault);
        console.log("VaultRegistry new impl:     ", deployed.vaultRegistryImpl);
        console.log("UniswapV2ExternalAdapter:   ", deployed.uniswapV2ExternalAdapter);
        console.log("  Safe wires this as vault.uniswapV2Adapter()");
        console.log("UniswapV3ExternalAdapter:   ", deployed.uniswapV3ExternalAdapter);
        console.log("  Safe wires this as vault.uniswapV3Adapter()");
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
        console.log("Safe Multisig:              ", config.multisig);
        console.log("========================================");
        console.log("");
    }

    function _logSafeCalls(Config memory config, Deployed memory deployed, SafeCalls memory calls) internal pure {
        console.log("Submit the following 6 transactions via Safe Transaction Builder:");
        console.log("");

        _logSafeTx(
            "Tx 1: VaultRegistry.upgradeToAndCall(newImpl, \"\")", config.vaultRegistry, calls.upgradeVaultRegistryCall
        );
        _logSafeTx("Tx 2: VaultRegistry.register(dividendVault, ...)", config.vaultRegistry, calls.registerCall);
        _logSafeTx("Tx 3: grant MERKLE_BOT setMerkleRoot permission", config.protocolManager, calls.grantMerkleBotCall);
        _logSafeTx(
            "Tx 4: grant CONVERSION_BOT executeConversion permission",
            config.protocolManager,
            calls.grantExecuteConversionCall
        );
        _logSafeTx(
            "Tx 5: vault.setAdapters(NadSwapAdapter, UniswapV2ExternalAdapter, UniswapV3ExternalAdapter)",
            deployed.dividendVault,
            calls.setAdaptersCall
        );
        _logSafeTx("Tx 6: vault.setWmon(WMON)", deployed.dividendVault, calls.setWmonCall);

        console.log("========================================");
        console.log("After Safe execution, verify:");
        console.log("  VaultRegistry proxy implementation slot == new impl");
        console.log("  vaultRegistry.isRegistered(proxy) == true");
        console.log("  vaultRegistry.getVaultType(proxy) == VaultType.Dividend");
        console.log("  PM.canCall(MERKLE_BOT, proxy, setMerkleRoot.selector) == true");
        console.log("  PM.canCall(CONVERSION_BOT, proxy, executeConversion.selector) == true");
        console.log("  vault.bondingCurveV1() == V1_BONDING_CURVE");
        console.log("  vault.nadSwapAdapter() == V2_NAD_SWAP_ADAPTER");
        console.log("  vault.uniswapV2Adapter()/uniswapV3Adapter() == deployed adapters");
        console.log("  vault.wmon() == WMON");
        console.log("  tokenRegistry.getAdapter(DexType.UniswapV2) remains the existing NadSwapAdapter");
        console.log("  Conversion paths are supplied by CONVERSION_BOT at execution time");
        console.log("  New adapter kinds require a DividendVault upgrade with an added allowlist lane/branch");
        console.log("========================================");
    }

    function _logSafeTx(string memory title, address target, bytes memory data) internal pure {
        console.log(string.concat("---- ", title, " ----"));
        console.log("  to:   ", target);
        console.log("  data:");
        console.logBytes(data);
        console.log("");
    }
}
