// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Token} from "../../../src/token/Token.sol";
import {CreatorFeeProcessor} from "../../../src/core/CreatorFeeProcessor.sol";
import {FeeCollector} from "../../../src/core/FeeCollector.sol";
import {VaultRegistry} from "../../../src/vault/VaultRegistry.sol";
import {BurnVault} from "../../../src/vault/BurnVault.sol";
import {LPVault} from "../../../src/vault/LPVault.sol";
import {CreatorFeeVault} from "../../../src/vault/CreatorFeeVault.sol";
import {GiftVault} from "../../../src/vault/GiftVault.sol";
import {TokenRegistry} from "../../../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../../../src/interfaces/ITokenRegistry.sol";
import {IProtocolManager} from "../../../src/interfaces/IProtocolManager.sol";
import {ILvMonMinter} from "../../../src/interfaces/ILvMonMinter.sol";
import {LPManager} from "../../../src/core/LPManager.sol";
import {NadFunRouter} from "../../../src/router/NadFunRouter.sol";
import {IVaultRegistry} from "../../../src/interfaces/IVaultRegistry.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";
import {BondingCurve} from "../../../src/core/BondingCurve.sol";
import {NadFunFactory} from "../../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../../src/dex/NadFunPair.sol";
import {NadSwapAdapter} from "../../../src/adapters/NadSwapAdapter.sol";
import {IDexAdapter} from "../../../src/interfaces/IDexAdapter.sol";

/// @title Deploy -- full v2 protocol deployment script
/// @notice Deploys all contracts in correct order, initializes and configures them.
/// @dev Environment variables (required):  PRIVATE_KEY, DEPLOYER, WMON, LV_MON, LVMON_MINTER, FEE_RECEIVER, MULTISIG,
///      VIRTUAL_RESERVE, VIRTUAL_TOKEN_RESERVE, MIN_TOKEN_RESERVE, DEPLOY_FEE, GRADUATE_FEE,
///      CURVE_PROTOCOL_FEE_RATE, DEX_PROTOCOL_FEE_RATE, SETTLEMENT_THRESHOLD, SNIPING_PENALTY_TABLE,
///      CREATOR_FEE_RATES, GIFT_EXPIRY_DURATION, BURN_VAULT_METADATA_URI, LP_VAULT_METADATA_URI,
///      CREATOR_FEE_VAULT_METADATA_URI, GIFT_VAULT_METADATA_URI
///      Environment variables (optional):  CREATOR_MANAGER, SETTLER, GIFT_RELAYER
///      DEPLOYER is the EOA address that PRIVATE_KEY derives to (sanity guard against env
///      mismatch). It holds admin authority only for the duration of the deploy and renounces /
///      transfers everything to MULTISIG in the final step.
contract Deploy is Script {
    struct QuoteTokenConfig {
        uint256 virtualReserve;
        uint256 virtualTokenReserve;
        uint256 minTokenReserve;
        uint256 deployFee;
        uint256 graduateFee;
        uint16 curveProtocolFeeRate;
        uint16 dexProtocolFeeRate;
        uint256 settlementThreshold;
    }

    struct Deployed {
        address tokenImpl;
        address creatorFeeProcessor;
        address feeCollector;
        address tokenRegistry;
        address lpManager;
        address protocolManager;
        address bondingCurve;
        address nadFunRouter;
        address vaultRegistry;
        address nadFunPairImpl;
        address nadFunFactory;
        address nadSwapAdapter;
        address burnVault;
        address lpVault;
        address creatorFeeVault;
        address giftVault;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");
        address wmon = vm.envAddress("WMON");
        address lvmon = vm.envAddress("LV_MON");
        address feeReceiver = vm.envAddress("FEE_RECEIVER");
        address giftRelayer = vm.envOr("GIFT_RELAYER", address(0));
        address creatorManager = vm.envOr("CREATOR_MANAGER", address(0));
        address settler = vm.envOr("SETTLER", address(0));
        address multisig = vm.envAddress("MULTISIG");

        address deployer = vm.addr(deployerPrivateKey);
        require(deployer == deployerEnv, "Deploy: PRIVATE_KEY does not match DEPLOYER env");
        require(multisig != address(0), "Deploy: MULTISIG required");
        require(multisig != deployer, "Deploy: MULTISIG must differ from deployer");

        vm.startBroadcast(deployerPrivateKey);

        Deployed memory d;

        // ── 1. Token implementation (clone template) ─────────────────
        d.tokenImpl = address(new Token());

        // ── 2. ProtocolManager (UUPS proxy) ──────────────────────────
        d.protocolManager = _deployProtocolManager(deployer, feeReceiver, wmon, lvmon);

        // ── 3. TokenRegistry (UUPS proxy) ────────────────────────────
        d.tokenRegistry = _deployTokenRegistry(d.protocolManager);

        // ── 4. LPManager (UUPS proxy) ───────────────────────────────
        d.lpManager = _deployLPManager(d.protocolManager, d.tokenRegistry);

        // ── 5. BondingCurve (UUPS proxy) ─────────────────────────────
        d.bondingCurve = _deployBondingCurve(deployer, d.tokenImpl, d.protocolManager);

        // ── 6. NadFunRouter (before FeeCollector/vaults — both reference router quotes/trades) ──
        d.nadFunRouter = _deployNadFunRouter(d.protocolManager, d.bondingCurve, d.tokenRegistry, wmon);

        // ── 7. CreatorFeeProcessor + FeeCollector (circular dependency via nonce prediction) ──
        address predictedFeeCollector = _predictFeeCollectorAddress(deployerPrivateKey);
        d.creatorFeeProcessor = _deployCreatorFeeProcessor(d.bondingCurve, predictedFeeCollector);
        d.feeCollector = _deployFeeCollector(d.protocolManager, d.creatorFeeProcessor, d.bondingCurve, d.nadFunRouter);
        require(d.feeCollector == predictedFeeCollector, "FeeCollector address prediction failed");

        // ── 8. NadFunFactory ─────────────────────────────────────────
        (d.nadFunPairImpl, d.nadFunFactory) = _deployNadFunFactory(d.protocolManager, d.feeCollector);
        ProtocolManager(d.protocolManager).setFactoryFeeTo(d.nadFunFactory, feeReceiver);

        // ── 9. NadSwapAdapter ────────────────────────────────────────
        d.nadSwapAdapter = _deployNadSwapAdapter(d.tokenRegistry);

        // ── 10. VaultRegistry ────────────────────────────────────────
        d.vaultRegistry = _deployVaultRegistry(d.protocolManager);

        // ── 11. Vaults ───────────────────────────────────────────────
        d.burnVault = _deployBurnVault(
            d.protocolManager, d.tokenRegistry, d.creatorFeeProcessor, d.bondingCurve, d.nadFunRouter, d.vaultRegistry
        );
        d.lpVault = _deployLPVault(d.protocolManager, d.tokenRegistry, d.creatorFeeProcessor, d.vaultRegistry);
        d.creatorFeeVault = _deployCreatorFeeVault(
            d.protocolManager, d.bondingCurve, d.creatorFeeProcessor, d.tokenRegistry, wmon, d.vaultRegistry
        );
        if (giftRelayer != address(0)) {
            d.giftVault = _deployGiftVault(
                d.protocolManager,
                d.creatorFeeProcessor,
                d.bondingCurve,
                d.tokenRegistry,
                d.nadFunRouter,
                wmon,
                d.vaultRegistry
            );
        }

        // ── 12. BondingCurve module registration ─────────────────────
        _registerModules(d);

        // ── 13. Operator permissions ─────────────────────────────────
        _setPermissions(d, creatorManager, settler, giftRelayer);

        // ── 14. Grant ROUTER_ROLE to NadFunRouter ────────────────────
        BondingCurve(payable(d.bondingCurve))
            .grantRole(BondingCurve(payable(d.bondingCurve)).ROUTER_ROLE(), d.nadFunRouter);

        // ── 15. Rotate admin to multisig ─────────────────────────────
        _transferAdminToMultisig(d, multisig, deployer);

        vm.stopBroadcast();

        _verify(d);
        _logDeployment(d, wmon);
    }

    // ── Internal: Admin rotation ─────────────────────────────────────

    /// @dev Grants admin/guardian roles on BondingCurve to `multisig`, transfers
    ///      ProtocolManager ownership, then renounces roles from the old admin.
    ///      ProtocolManager ownership transfer alone covers all AccessManaged targets;
    ///      BondingCurve uses AccessControl so its roles must be handled explicitly.
    function _transferAdminToMultisig(Deployed memory d, address multisig, address oldAdmin) internal {
        BondingCurve bc = BondingCurve(payable(d.bondingCurve));
        bytes32 adminRole = bc.DEFAULT_ADMIN_ROLE();
        bytes32 guardianRole = bc.GUARDIAN_ROLE();

        // Grant BondingCurve roles to multisig first (so new admin is live before old one is revoked).
        bc.grantRole(adminRole, multisig);
        bc.grantRole(guardianRole, multisig);

        // Transfer ProtocolManager ownership (rotates every AccessManaged target at once).
        ProtocolManager(d.protocolManager).transferOwnership(multisig);

        // Renounce old admin's BondingCurve roles. renounceRole requires caller == account,
        // which is true under vm.startBroadcast(deployer).
        bc.renounceRole(adminRole, oldAdmin);
        bc.renounceRole(guardianRole, oldAdmin);
    }

    // ── Internal: ProtocolManager ────────────────────────────────────

    function _deployProtocolManager(address admin, address feeReceiver, address wmon, address lvmon)
        internal
        returns (address)
    {
        address proxy = _deployProxy(
            address(new ProtocolManager()), abi.encodeCall(ProtocolManager.initialize, (admin, feeReceiver))
        );

        ProtocolManager pm = ProtocolManager(proxy);
        QuoteTokenConfig memory config = _quoteTokenConfig();
        _addQuoteToken(pm, wmon, config);
        _addQuoteToken(pm, lvmon, config);
        pm.setSnipingPenaltyTable(_snipingPenaltyTable());

        pm.setAllowedCreatorFeeRates(_creatorFeeRates());

        return proxy;
    }

    function _addQuoteToken(ProtocolManager pm, address quoteToken, QuoteTokenConfig memory config) internal {
        pm.addQuoteToken(
            quoteToken,
            config.virtualReserve,
            config.virtualTokenReserve,
            config.minTokenReserve,
            config.deployFee,
            config.graduateFee,
            config.curveProtocolFeeRate,
            config.dexProtocolFeeRate,
            config.settlementThreshold
        );
    }

    function _quoteTokenConfig() internal view returns (QuoteTokenConfig memory config) {
        config.virtualReserve = vm.envUint("VIRTUAL_RESERVE");
        config.virtualTokenReserve = vm.envUint("VIRTUAL_TOKEN_RESERVE");
        config.minTokenReserve = vm.envUint("MIN_TOKEN_RESERVE");
        config.deployFee = vm.envUint("DEPLOY_FEE");
        config.graduateFee = vm.envUint("GRADUATE_FEE");
        config.curveProtocolFeeRate = _readUint16("CURVE_PROTOCOL_FEE_RATE");
        config.dexProtocolFeeRate = _readUint16("DEX_PROTOCOL_FEE_RATE");
        config.settlementThreshold = vm.envUint("SETTLEMENT_THRESHOLD");
    }

    function _snipingPenaltyTable() internal view returns (uint256[] memory table) {
        table = vm.envUint("SNIPING_PENALTY_TABLE", ",");
        require(table.length > 0, "Deploy: empty SNIPING_PENALTY_TABLE");
    }

    function _creatorFeeRates() internal view returns (uint16[] memory rates) {
        uint256[] memory rawRates = vm.envUint("CREATOR_FEE_RATES", ",");
        require(rawRates.length > 0, "Deploy: empty CREATOR_FEE_RATES");

        rates = new uint16[](rawRates.length);
        for (uint256 i = 0; i < rawRates.length; i++) {
            require(rawRates[i] <= type(uint16).max, "Deploy: creator fee rate overflows uint16");
            // forge-lint: disable-next-line(unsafe-typecast)
            rates[i] = uint16(rawRates[i]);
        }
    }

    function _readUint16(string memory key) internal view returns (uint16 value) {
        uint256 rawValue = vm.envUint(key);
        require(rawValue <= type(uint16).max, "Deploy: uint16 env overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        value = uint16(rawValue);
    }

    // ── Internal: TokenRegistry ─────────────────────────────────────

    function _deployTokenRegistry(address protocolManager_) internal returns (address) {
        return _deployProxy(address(new TokenRegistry()), abi.encodeCall(TokenRegistry.initialize, (protocolManager_)));
    }

    // ── Internal: LPManager ─────────────────────────────────────────

    function _deployLPManager(address protocolManager_, address tokenRegistry_) internal returns (address) {
        return _deployProxy(
            address(new LPManager()), abi.encodeCall(LPManager.initialize, (protocolManager_, tokenRegistry_))
        );
    }

    // ── Internal: BondingCurve ──────────────────────────────────────

    function _deployBondingCurve(address admin, address tokenImpl_, address protocolManager_)
        internal
        returns (address)
    {
        return _deployProxy(
            address(new BondingCurve()), abi.encodeCall(BondingCurve.initialize, (admin, tokenImpl_, protocolManager_))
        );
    }

    // ── Internal: CreatorFeeProcessor ───────────────────────────────

    function _predictFeeCollectorAddress(uint256 deployerPrivateKey) internal view returns (address) {
        address deployer = vm.addr(deployerPrivateKey);
        uint64 nonce = vm.getNonce(deployer);
        // nonce+0: CreatorFeeProcessor, nonce+1: FeeCollector impl, nonce+2: FeeCollector proxy
        return vm.computeCreateAddress(deployer, nonce + 2);
    }

    function _deployCreatorFeeProcessor(address bondingCurve_, address feeCollector_) internal returns (address) {
        return address(new CreatorFeeProcessor(bondingCurve_, feeCollector_));
    }

    // ── Internal: FeeCollector ──────────────────────────────────────

    function _deployFeeCollector(
        address protocolManager_,
        address creatorFeeProcessor_,
        address bondingCurve_,
        address router_
    ) internal returns (address) {
        return _deployProxy(
            address(new FeeCollector()),
            abi.encodeCall(FeeCollector.initialize, (protocolManager_, creatorFeeProcessor_, bondingCurve_, router_))
        );
    }

    // ── Internal: NadFunFactory ─────────────────────────────────────

    function _deployNadFunFactory(address protocolManager_, address feeCollector_)
        internal
        returns (address nadFunPairImpl, address)
    {
        nadFunPairImpl = address(new NadFunPair());
        return (nadFunPairImpl, address(new NadFunFactory(protocolManager_, feeCollector_, nadFunPairImpl)));
    }

    // ── Internal: NadSwapAdapter ────────────────────────────────────

    function _deployNadSwapAdapter(address tokenRegistry_) internal returns (address) {
        address adapter = address(new NadSwapAdapter());
        TokenRegistry(tokenRegistry_).setAdapter(ITokenRegistry.DexType.UniswapV2, IDexAdapter(adapter));
        return adapter;
    }

    // ── Internal: VaultRegistry ─────────────────────────────────────

    function _deployVaultRegistry(address protocolManager_) internal returns (address) {
        return _deployProxy(address(new VaultRegistry()), abi.encodeCall(VaultRegistry.initialize, (protocolManager_)));
    }

    // ── Internal: BurnVault ─────────────────────────────────────────

    function _deployBurnVault(
        address protocolManager_,
        address tokenRegistry_,
        address creatorFeeProcessor_,
        address bondingCurve_,
        address router_,
        address vaultRegistry_
    ) internal returns (address) {
        address vault = _deployProxy(
            address(new BurnVault()),
            abi.encodeCall(
                BurnVault.initialize,
                (
                    protocolManager_,
                    tokenRegistry_,
                    creatorFeeProcessor_,
                    bondingCurve_,
                    router_,
                    vm.envString("BURN_VAULT_METADATA_URI")
                )
            )
        );
        VaultRegistry(vaultRegistry_).register(vault, "BurnVault", "Buyback and burn", IVaultRegistry.VaultType.Burn);
        return vault;
    }

    // ── Internal: LPVault ───────────────────────────────────────────

    function _deployLPVault(
        address protocolManager_,
        address tokenRegistry_,
        address creatorFeeProcessor_,
        address vaultRegistry_
    ) internal returns (address) {
        address vault = _deployProxy(
            address(new LPVault()),
            abi.encodeCall(
                LPVault.initialize,
                (protocolManager_, tokenRegistry_, creatorFeeProcessor_, vm.envString("LP_VAULT_METADATA_URI"))
            )
        );
        VaultRegistry(vaultRegistry_).register(vault, "LPVault", "LP injection", IVaultRegistry.VaultType.LP);
        return vault;
    }

    // ── Internal: CreatorFeeVault ───────────────────────────────────

    function _deployCreatorFeeVault(
        address protocolManager_,
        address bondingCurve_,
        address creatorFeeProcessor_,
        address tokenRegistry_,
        address wmon_,
        address vaultRegistry_
    ) internal returns (address) {
        address vault = _deployProxy(
            address(new CreatorFeeVault()),
            abi.encodeCall(
                CreatorFeeVault.initialize,
                (
                    protocolManager_,
                    bondingCurve_,
                    creatorFeeProcessor_,
                    tokenRegistry_,
                    wmon_,
                    vm.envString("CREATOR_FEE_VAULT_METADATA_URI")
                )
            )
        );
        VaultRegistry(vaultRegistry_)
            .register(vault, "CreatorFeeVault", "Direct transfer", IVaultRegistry.VaultType.Creator);
        return vault;
    }

    // ── Internal: GiftVault ─────────────────────────────────────────

    function _deployGiftVault(
        address protocolManager_,
        address creatorFeeProcessor_,
        address bondingCurve_,
        address tokenRegistry_,
        address router_,
        address wmon_,
        address vaultRegistry_
    ) internal returns (address) {
        address vault = _deployProxy(
            address(new GiftVault()),
            abi.encodeCall(
                GiftVault.initialize,
                (
                    protocolManager_,
                    creatorFeeProcessor_,
                    bondingCurve_,
                    tokenRegistry_,
                    vm.envUint("GIFT_EXPIRY_DURATION"),
                    router_,
                    wmon_,
                    vm.envString("GIFT_VAULT_METADATA_URI")
                )
            )
        );
        VaultRegistry(vaultRegistry_).register(vault, "GiftVault", "Gift with expiry", IVaultRegistry.VaultType.Gift);
        return vault;
    }

    // ── Internal: BondingCurve modules ──────────────────────────────

    function _registerModules(Deployed memory d) internal {
        BondingCurve bc = BondingCurve(payable(d.bondingCurve));
        bc.setModule(keccak256("TOKEN_REGISTRY"), d.tokenRegistry);
        bc.setModule(keccak256("LP_MANAGER"), d.lpManager);
        bc.setModule(keccak256("CREATOR_FEE_PROCESSOR"), d.creatorFeeProcessor);
        bc.setModule(keccak256("VAULT_REGISTRY"), d.vaultRegistry);
        bc.setModule(keccak256("FEE_COLLECTOR"), d.feeCollector);
        bc.setModule(keccak256("FACTORY"), d.nadFunFactory);
    }

    // ── Internal: Operator permissions ──────────────────────────────

    function _setPermissions(Deployed memory d, address creatorManager, address settler, address giftRelayer) internal {
        ProtocolManager pm = ProtocolManager(d.protocolManager);
        pm.setOperatorPermission(d.bondingCurve, d.tokenRegistry, TokenRegistry.register.selector, true);
        pm.setOperatorPermission(d.bondingCurve, d.lpManager, LPManager.addLiquidity.selector, true);

        if (creatorManager != address(0)) {
            pm.setOperatorPermission(creatorManager, d.creatorFeeVault, CreatorFeeVault.setCreator.selector, true);
        }

        if (settler != address(0)) {
            pm.setOperatorPermission(settler, d.feeCollector, FeeCollector.settle.selector, true);
        }

        if (giftRelayer != address(0) && d.giftVault != address(0)) {
            pm.setOperatorPermission(giftRelayer, d.giftVault, GiftVault.setReceiver.selector, true);
        }
    }

    // ── Internal: NadFunRouter ──────────────────────────────────────

    function _deployNadFunRouter(address protocolManager_, address bondingCurve_, address tokenRegistry_, address wmon)
        internal
        returns (address)
    {
        address lvmonMinter = vm.envAddress("LVMON_MINTER");
        return _deployProxy(
            address(new NadFunRouter()),
            abi.encodeCall(
                NadFunRouter.initialize, (protocolManager_, bondingCurve_, tokenRegistry_, wmon, lvmonMinter)
            )
        );
    }

    // ── Internal: Proxy helper ──────────────────────────────────────

    function _deployProxy(address impl, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(impl, initData));
    }

    // ── Verification ─────────────────────────────────────────────────

    /// @dev Split into sub-verifiers to keep each function's stack small (Solidity has a
    ///      ~16-slot local limit and `via_ir` is intentionally off).
    function _verify(Deployed memory d) internal view {
        _verifyProtocolConfig(d);
        _verifyPermissions(d);
        _verifyAdminRotation(d);
        console.log("All verifications passed!");
    }

    function _verifyProtocolConfig(Deployed memory d) internal view {
        address wmon = vm.envAddress("WMON");
        address lvmon = vm.envAddress("LV_MON");

        ProtocolManager pm = ProtocolManager(d.protocolManager);
        QuoteTokenConfig memory expectedConfig = _quoteTokenConfig();

        require(pm.feeReceiver() != address(0), "Verify: feeReceiver not set");
        _verifyQuoteTokenConfig(pm, wmon, expectedConfig);
        _verifyQuoteTokenConfig(pm, lvmon, expectedConfig);
        require(address(ILvMonMinter(vm.envAddress("LVMON_MINTER")).lvmon()) == lvmon, "Verify: LV_MON mismatch");

        uint256[] memory expectedTable = _snipingPenaltyTable();
        require(pm.snipingPenaltyTableLength() == expectedTable.length, "Verify: snipingPenaltyTable length mismatch");
        for (uint256 i = 0; i < expectedTable.length; i++) {
            require(pm.snipingPenaltyAt(i) == expectedTable[i], "Verify: snipingPenaltyTable entry mismatch");
        }

        uint16[] memory expectedCreatorFeeRates = _creatorFeeRates();
        for (uint256 i = 0; i < expectedCreatorFeeRates.length; i++) {
            require(pm.isCreatorFeeRateAllowed(expectedCreatorFeeRates[i]), "Verify: creatorFeeRate not allowed");
        }
        require(NadFunFactory(d.nadFunFactory).feeTo() == pm.feeReceiver(), "Verify: factory feeTo mismatch");
    }

    function _verifyQuoteTokenConfig(ProtocolManager pm, address quoteToken, QuoteTokenConfig memory expectedConfig)
        internal
        view
    {
        IProtocolManager.QuoteConfig memory actualConfig = pm.getConfig(quoteToken);

        require(actualConfig.active, "Verify: quoteToken inactive");
        require(actualConfig.virtualReserve == expectedConfig.virtualReserve, "Verify: virtualReserve mismatch");
        require(
            actualConfig.virtualTokenReserve == expectedConfig.virtualTokenReserve,
            "Verify: virtualTokenReserve mismatch"
        );
        require(actualConfig.minTokenReserve == expectedConfig.minTokenReserve, "Verify: minTokenReserve mismatch");
        require(actualConfig.deployFee == expectedConfig.deployFee, "Verify: deployFee mismatch");
        require(actualConfig.graduateFee == expectedConfig.graduateFee, "Verify: graduateFee mismatch");
        require(
            actualConfig.curveProtocolFeeRate == expectedConfig.curveProtocolFeeRate,
            "Verify: curveProtocolFeeRate mismatch"
        );
        require(
            actualConfig.dexProtocolFeeRate == expectedConfig.dexProtocolFeeRate, "Verify: dexProtocolFeeRate mismatch"
        );
        require(
            actualConfig.settlementThreshold == expectedConfig.settlementThreshold,
            "Verify: settlementThreshold mismatch"
        );
    }

    function _verifyPermissions(Deployed memory d) internal view {
        ProtocolManager pm = ProtocolManager(d.protocolManager);
        BondingCurve bc = BondingCurve(payable(d.bondingCurve));

        (bool canRegister,) = pm.canCall(d.bondingCurve, d.tokenRegistry, TokenRegistry.register.selector);
        require(canRegister, "Verify: BondingCurve cannot call TokenRegistry.register");
        (bool canAddLiq,) = pm.canCall(d.bondingCurve, d.lpManager, LPManager.addLiquidity.selector);
        require(canAddLiq, "Verify: BondingCurve cannot call LPManager.addLiquidity");

        require(bc.hasRole(bc.ROUTER_ROLE(), d.nadFunRouter), "Verify: NadFunRouter missing ROUTER_ROLE");
        require(bc.creatorFeeProcessor() == d.creatorFeeProcessor, "Verify: creatorFeeProcessor mismatch");

        address creatorManager = vm.envOr("CREATOR_MANAGER", address(0));
        if (creatorManager != address(0)) {
            (bool canSetCreator,) = pm.canCall(creatorManager, d.creatorFeeVault, CreatorFeeVault.setCreator.selector);
            require(canSetCreator, "Verify: creatorManager missing setCreator permission");
        }

        address settler = vm.envOr("SETTLER", address(0));
        if (settler != address(0)) {
            (bool canSettle,) = pm.canCall(settler, d.feeCollector, FeeCollector.settle.selector);
            require(canSettle, "Verify: settler missing settle permission");
        }

        address giftRelayer = vm.envOr("GIFT_RELAYER", address(0));
        if (giftRelayer != address(0) && d.giftVault != address(0)) {
            (bool canSetReceiver,) = pm.canCall(giftRelayer, d.giftVault, GiftVault.setReceiver.selector);
            require(canSetReceiver, "Verify: giftRelayer missing setReceiver permission");
        }
    }

    function _verifyAdminRotation(Deployed memory d) internal view {
        address deployer = vm.envAddress("DEPLOYER");
        address multisig = vm.envAddress("MULTISIG");

        ProtocolManager pm = ProtocolManager(d.protocolManager);
        BondingCurve bc = BondingCurve(payable(d.bondingCurve));

        require(pm.owner() == multisig, "Verify: PM owner mismatch");
        require(bc.hasRole(bc.DEFAULT_ADMIN_ROLE(), multisig), "Verify: BC admin role mismatch");
        require(bc.hasRole(bc.GUARDIAN_ROLE(), multisig), "Verify: BC guardian role mismatch");
        require(!bc.hasRole(bc.DEFAULT_ADMIN_ROLE(), deployer), "Verify: deployer admin role not revoked");
        require(!bc.hasRole(bc.GUARDIAN_ROLE(), deployer), "Verify: deployer guardian role not revoked");
    }

    // ── Logging ─────────────────────────────────────────────────────

    function _logDeployment(Deployed memory d, address wmon) internal view {
        console.log("========================================");
        console.log("Deployment complete!");
        console.log("========================================");
        _logEnvAddress("WMON", wmon);
        _logEnvAddress("LV_MON", vm.envAddress("LV_MON"));
        _logEnvAddress("LVMON_MINTER", vm.envAddress("LVMON_MINTER"));
        _logEnvAddress("V2_TOKEN_IMPL", d.tokenImpl);
        _logEnvAddress("V2_PROTOCOL_MANAGER", d.protocolManager);
        _logEnvAddress("V2_TOKEN_REGISTRY", d.tokenRegistry);
        _logEnvAddress("V2_LP_MANAGER", d.lpManager);
        _logEnvAddress("V2_BONDING_CURVE", d.bondingCurve);
        _logEnvAddress("V2_CREATOR_FEE_PROCESSOR", d.creatorFeeProcessor);
        _logEnvAddress("V2_FEE_COLLECTOR", d.feeCollector);
        _logEnvAddress("V2_NAD_FUN_PAIR_IMPL", d.nadFunPairImpl);
        _logEnvAddress("V2_NAD_FUN_FACTORY", d.nadFunFactory);
        _logEnvAddress("V2_NAD_SWAP_ADAPTER", d.nadSwapAdapter);
        _logEnvAddress("V2_VAULT_REGISTRY", d.vaultRegistry);
        _logEnvAddress("V2_BURN_VAULT", d.burnVault);
        _logEnvAddress("V2_LP_VAULT", d.lpVault);
        _logEnvAddress("V2_CREATOR_FEE_VAULT", d.creatorFeeVault);
        _logEnvAddress("V2_GIFT_VAULT", d.giftVault);
        _logEnvAddress("V2_NAD_FUN_ROUTER", d.nadFunRouter);
        console.log("========================================");
    }

    function _logEnvAddress(string memory key, address value) internal pure {
        console.log(string.concat(key, "=\"", vm.toString(value), "\""));
    }
}
