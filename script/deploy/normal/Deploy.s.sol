// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPeripheryImmutableState} from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import {QuoterV2} from "@uniswap/v3-periphery/contracts/lens/QuoterV2.sol";

import {Token} from "../../../src/token/Token.sol";
import {CreatorFeeProcessor} from "../../../src/core/CreatorFeeProcessor.sol";
import {V3PoolDeployer} from "../../../src/core/V3PoolDeployer.sol";
import {V3LiquidityActor} from "../../../src/actors/V3LiquidityActor.sol";
import {VaultRegistry} from "../../../src/vault/VaultRegistry.sol";
import {CreatorFeeVault} from "../../../src/vault/CreatorFeeVault.sol";
import {TokenRegistry} from "../../../src/core/TokenRegistry.sol";
import {IProtocolManager} from "../../../src/interfaces/IProtocolManager.sol";
import {IV3SwapAdapter} from "../../../src/interfaces/IV3SwapAdapter.sol";
import {IV3LiquidityActor} from "../../../src/interfaces/IV3LiquidityActor.sol";
import {LPManager} from "../../../src/core/LPManager.sol";
import {GiwaRouter} from "../../../src/router/GiwaRouter.sol";
import {IVaultRegistry} from "../../../src/interfaces/IVaultRegistry.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";
import {BondingCurve} from "../../../src/core/BondingCurve.sol";
import {V3SwapAdapter} from "../../../src/adapters/V3SwapAdapter.sol";

address constant GIWA_WETH = 0x4200000000000000000000000000000000000006;

/// @title Deploy -- full canonical Uniswap V3 protocol deployment script
/// @notice Deploys all contracts in correct order, initializes and configures them.
/// @dev Environment variables (required):  PRIVATE_KEY, DEPLOYER, MULTISIG,
///      CHAIN_ID, FEE_RECEIVER, V3_FACTORY,
///      VIRTUAL_RESERVE, VIRTUAL_TOKEN_RESERVE, MIN_TOKEN_RESERVE, DEPLOY_FEE, GRADUATE_FEE,
///      CURVE_PROTOCOL_FEE_RATE, V3_FEE_TIER, LP_FEE_PROTOCOL_SHARE_BPS, SNIPING_PENALTY_TABLE,
///      CREATOR_FEE_VAULT_METADATA_URI
///      Environment variables (optional):  CREATOR_MANAGER, COLLECTOR (defaults to MULTISIG)
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
        uint24 v3FeeTier;
        uint16 lpFeeProtocolShareBps;
    }

    struct ProtocolDeploymentConfig {
        QuoteTokenConfig quoteToken;
        uint256[] snipingPenaltyTable;
    }

    struct Deployed {
        address weth;
        address tokenImpl;
        address creatorFeeProcessor;
        address tokenRegistry;
        address lpManager;
        address protocolManager;
        address bondingCurve;
        address giwaRouter;
        address vaultRegistry;
        address creatorFeeVault;
        address v3Factory;
        address v3PoolDeployer;
        address v3LiquidityActor;
        address v3SwapAdapter;
        address quoterV2;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerEnv = vm.envAddress("DEPLOYER");
        address feeReceiver = vm.envAddress("FEE_RECEIVER");
        address creatorManager = vm.envOr("CREATOR_MANAGER", address(0));
        address multisig = vm.envAddress("MULTISIG");
        address collector = vm.envOr("COLLECTOR", multisig);

        address deployer = vm.addr(deployerPrivateKey);
        require(block.chainid == vm.envUint("CHAIN_ID"), "Deploy: CHAIN_ID mismatch");
        require(deployer == deployerEnv, "Deploy: PRIVATE_KEY does not match DEPLOYER env");
        require(feeReceiver != address(0), "Deploy: FEE_RECEIVER required");
        require(multisig != address(0), "Deploy: MULTISIG required");
        require(collector != address(0), "Deploy: COLLECTOR required");

        address v3Factory = vm.envAddress("V3_FACTORY");
        require(v3Factory.code.length > 0, "Deploy: invalid V3_FACTORY");
        require(IUniswapV3Factory(v3Factory).owner() == multisig, "Deploy: V3_FACTORY owner mismatch");
        ProtocolDeploymentConfig memory protocolConfig = _protocolDeploymentConfig();
        require(
            IUniswapV3Factory(v3Factory).feeAmountTickSpacing(protocolConfig.quoteToken.v3FeeTier) != 0,
            "Deploy: unsupported V3_FEE_TIER"
        );

        vm.startBroadcast(deployerPrivateKey);

        Deployed memory d;
        d.v3Factory = v3Factory;

        // ── 1. Reuse canonical WETH predeploy + ProtocolManager ──────
        (d.weth, d.protocolManager) = _deployCanonicalWethAndProtocolManager(deployer, feeReceiver, protocolConfig);

        // ── 2. TokenRegistry (UUPS proxy) ────────────────────────────
        d.tokenRegistry = _deployTokenRegistry(d.protocolManager);

        // ── 3. Creator fee and V3 swap dependencies ─────────────────
        d.creatorFeeProcessor = _deployCreatorFeeProcessor(d.protocolManager);
        d.v3SwapAdapter = _deployV3SwapAdapter(d.v3Factory, d.tokenRegistry);

        // ── 4. LPManager (UUPS proxy) ───────────────────────────────
        d.lpManager = _deployLPManager(d.protocolManager, d.tokenRegistry, d.creatorFeeProcessor, d.v3SwapAdapter);

        // ── 5. Canonical V3 pool + permanent-liquidity infrastructure ─
        d.v3PoolDeployer = _deployV3PoolDeployer(d.protocolManager, d.v3Factory);
        d.v3LiquidityActor = address(new V3LiquidityActor(d.lpManager, d.v3Factory));
        LPManager(d.lpManager).setV3LiquidityActor(d.v3LiquidityActor, d.v3Factory);

        // ── 6. Token implementation + BondingCurve (UUPS proxy) ─────
        d.tokenImpl = address(new Token());
        d.bondingCurve = _deployBondingCurve(deployer, d.tokenImpl, d.protocolManager);

        // ── 7. Canonical V3 quote dependency + GiwaRouter ────────────
        (d.quoterV2, d.giwaRouter) =
            _deployV3Routing(d.protocolManager, d.bondingCurve, d.tokenRegistry, d.weth, d.v3SwapAdapter, d.v3Factory);

        // ── 8. VaultRegistry ─────────────────────────────────────────
        d.vaultRegistry = _deployVaultRegistry(d.protocolManager);

        // ── 9. Creator fee vault (the only registered vault) ─────────
        _deployVaults(d, vm.envString("CREATOR_FEE_VAULT_METADATA_URI"));

        // ── 10. BondingCurve module registration ─────────────────────
        _registerModules(d);

        // ── 11. Operator permissions ─────────────────────────────────
        _setPermissions(d, creatorManager, collector);

        // ── 12. Grant ROUTER_ROLE to GiwaRouter ──────────────────────
        BondingCurve(payable(d.bondingCurve))
            .grantRole(BondingCurve(payable(d.bondingCurve)).ROUTER_ROLE(), d.giwaRouter);

        // ── 13. Rotate admin to multisig ─────────────────────────────
        _transferAdminToMultisig(d, multisig, deployer);

        vm.stopBroadcast();

        _verify(d);
        _logDeployment(d);
    }

    // ── Internal: Admin rotation ─────────────────────────────────────

    /// @dev Grants admin/guardian roles on BondingCurve to `multisig`, transfers
    ///      ProtocolManager ownership, then renounces roles from the old admin.
    ///      ProtocolManager ownership transfer alone covers all AccessManaged targets;
    ///      BondingCurve uses AccessControl so its roles must be handled explicitly.
    function _transferAdminToMultisig(Deployed memory d, address multisig, address oldAdmin) internal {
        if (multisig == oldAdmin) return;

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

    function _canonicalWeth() internal view returns (address weth) {
        weth = GIWA_WETH;
        require(weth.code.length > 0, "Deploy: canonical WETH missing code");
    }

    function _deployCanonicalWethAndProtocolManager(
        address admin,
        address feeReceiver,
        ProtocolDeploymentConfig memory config
    ) internal returns (address weth, address protocolManager) {
        weth = _canonicalWeth();
        protocolManager = _deployProtocolManager(admin, feeReceiver, weth, config);
    }

    function _deployProtocolManager(
        address admin,
        address feeReceiver,
        address weth,
        ProtocolDeploymentConfig memory config
    ) internal returns (address) {
        address proxy = _deployProxy(
            address(new ProtocolManager()), abi.encodeCall(ProtocolManager.initialize, (admin, feeReceiver))
        );

        ProtocolManager pm = ProtocolManager(proxy);
        _addV3QuoteToken(pm, weth, config.quoteToken);
        pm.setSnipingPenaltyTable(config.snipingPenaltyTable);

        return proxy;
    }

    function _addV3QuoteToken(ProtocolManager pm, address quoteToken, QuoteTokenConfig memory config) internal {
        pm.addV3QuoteToken(
            quoteToken,
            config.virtualReserve,
            config.virtualTokenReserve,
            config.minTokenReserve,
            config.deployFee,
            config.graduateFee,
            config.curveProtocolFeeRate,
            0,
            config.v3FeeTier,
            config.lpFeeProtocolShareBps
        );
    }

    function _protocolDeploymentConfig() internal view returns (ProtocolDeploymentConfig memory config) {
        config.quoteToken = _quoteTokenConfig();
        config.snipingPenaltyTable = _snipingPenaltyTable();
    }

    function _quoteTokenConfig() internal view returns (QuoteTokenConfig memory config) {
        config.virtualReserve = vm.envUint("VIRTUAL_RESERVE");
        config.virtualTokenReserve = vm.envUint("VIRTUAL_TOKEN_RESERVE");
        config.minTokenReserve = vm.envUint("MIN_TOKEN_RESERVE");
        config.deployFee = vm.envUint("DEPLOY_FEE");
        config.graduateFee = vm.envUint("GRADUATE_FEE");
        config.curveProtocolFeeRate = _readUint16("CURVE_PROTOCOL_FEE_RATE");
        config.v3FeeTier = _readUint24("V3_FEE_TIER");
        config.lpFeeProtocolShareBps = _readUint16("LP_FEE_PROTOCOL_SHARE_BPS");
    }

    function _snipingPenaltyTable() internal view returns (uint256[] memory table) {
        table = vm.envUint("SNIPING_PENALTY_TABLE", ",");
        require(table.length > 0, "Deploy: empty SNIPING_PENALTY_TABLE");
    }

    function _readUint16(string memory key) internal view returns (uint16 value) {
        uint256 rawValue = vm.envUint(key);
        require(rawValue <= type(uint16).max, "Deploy: uint16 env overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        value = uint16(rawValue);
    }

    function _readUint24(string memory key) internal view returns (uint24 value) {
        uint256 rawValue = vm.envUint(key);
        require(rawValue <= type(uint24).max, "Deploy: uint24 env overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        value = uint24(rawValue);
    }

    // ── Internal: TokenRegistry ─────────────────────────────────────

    function _deployTokenRegistry(address protocolManager_) internal returns (address) {
        return _deployProxy(address(new TokenRegistry()), abi.encodeCall(TokenRegistry.initialize, (protocolManager_)));
    }

    // ── Internal: LPManager ─────────────────────────────────────────

    function _deployLPManager(
        address protocolManager_,
        address tokenRegistry_,
        address creatorFeeProcessor_,
        address v3SwapAdapter_
    ) internal returns (address) {
        return _deployProxy(
            address(new LPManager()),
            abi.encodeCall(
                LPManager.initialize, (protocolManager_, tokenRegistry_, creatorFeeProcessor_, v3SwapAdapter_)
            )
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

    function _deployCreatorFeeProcessor(address protocolManager_) internal returns (address) {
        return address(new CreatorFeeProcessor(protocolManager_));
    }

    // ── Internal: Canonical V3 dependencies ─────────────────────────

    function _deployV3PoolDeployer(address protocolManager_, address v3Factory_) internal returns (address) {
        return _deployProxy(
            address(new V3PoolDeployer()), abi.encodeCall(V3PoolDeployer.initialize, (protocolManager_, v3Factory_))
        );
    }

    function _deployQuoterV2(address v3Factory_, address weth_) internal returns (address quoterV2) {
        quoterV2 = address(new QuoterV2(v3Factory_, weth_));
        IPeripheryImmutableState immutableState = IPeripheryImmutableState(quoterV2);
        require(immutableState.factory() == v3Factory_, "Deploy: QuoterV2 factory mismatch");
        require(immutableState.WETH9() == weth_, "Deploy: QuoterV2 WETH mismatch");
    }

    function _deployV3SwapAdapter(address v3Factory_, address tokenRegistry_) internal returns (address) {
        return address(new V3SwapAdapter(v3Factory_, tokenRegistry_));
    }

    function _deployV3Routing(
        address protocolManager_,
        address bondingCurve_,
        address tokenRegistry_,
        address weth_,
        address v3SwapAdapter_,
        address v3Factory_
    ) internal returns (address quoterV2, address giwaRouter) {
        require(weth_ == _canonicalWeth(), "Deploy: non-canonical WETH");
        require(IV3SwapAdapter(v3SwapAdapter_).factory() == v3Factory_, "Deploy: swap adapter factory mismatch");
        require(
            IV3SwapAdapter(v3SwapAdapter_).tokenRegistry() == tokenRegistry_, "Deploy: swap adapter registry mismatch"
        );
        quoterV2 = _deployQuoterV2(v3Factory_, weth_);
        giwaRouter = _deployGiwaRouter(protocolManager_, bondingCurve_, tokenRegistry_, weth_, v3SwapAdapter_, quoterV2);
    }

    // ── Internal: VaultRegistry ─────────────────────────────────────

    function _deployVaultRegistry(address protocolManager_) internal returns (address) {
        return _deployProxy(address(new VaultRegistry()), abi.encodeCall(VaultRegistry.initialize, (protocolManager_)));
    }

    // ── Internal: CreatorFeeVault ───────────────────────────────────

    function _deployCreatorFeeVault(
        address protocolManager_,
        address bondingCurve_,
        address creatorFeeProcessor_,
        address tokenRegistry_,
        address weth_,
        address vaultRegistry_,
        string memory metadataURI_
    ) internal returns (address) {
        address vault = _deployProxy(
            address(new CreatorFeeVault()),
            abi.encodeCall(
                CreatorFeeVault.initialize,
                (protocolManager_, bondingCurve_, creatorFeeProcessor_, tokenRegistry_, weth_, metadataURI_)
            )
        );
        VaultRegistry(vaultRegistry_)
            .register(vault, "CreatorFeeVault", "Direct transfer", IVaultRegistry.VaultType.Creator);
        return vault;
    }

    function _deployVaults(Deployed memory d, string memory creatorFeeVaultMetadataURI) internal {
        d.creatorFeeVault = _deployCreatorFeeVault(
            d.protocolManager,
            d.bondingCurve,
            d.creatorFeeProcessor,
            d.tokenRegistry,
            d.weth,
            d.vaultRegistry,
            creatorFeeVaultMetadataURI
        );
    }

    // ── Internal: BondingCurve modules ──────────────────────────────

    function _registerModules(Deployed memory d) internal {
        BondingCurve bc = BondingCurve(payable(d.bondingCurve));
        bc.setModule(keccak256("TOKEN_REGISTRY"), d.tokenRegistry);
        bc.setModule(keccak256("LP_MANAGER"), d.lpManager);
        bc.setModule(keccak256("CREATOR_FEE_PROCESSOR"), d.creatorFeeProcessor);
        bc.setModule(keccak256("VAULT_REGISTRY"), d.vaultRegistry);
        bc.setModule(keccak256("V3_POOL_DEPLOYER"), d.v3PoolDeployer);
    }

    // ── Internal: Operator permissions ──────────────────────────────

    function _setPermissions(Deployed memory d, address creatorManager, address collector) internal {
        ProtocolManager pm = ProtocolManager(d.protocolManager);
        pm.setOperatorPermission(d.bondingCurve, d.v3PoolDeployer, V3PoolDeployer.createPool.selector, true);
        pm.setOperatorPermission(d.bondingCurve, d.tokenRegistry, TokenRegistry.registerV3.selector, true);
        pm.setOperatorPermission(d.bondingCurve, d.lpManager, LPManager.allocate.selector, true);
        pm.setOperatorPermission(d.bondingCurve, d.creatorFeeProcessor, CreatorFeeProcessor.setup.selector, true);
        pm.setOperatorPermission(
            d.lpManager, d.creatorFeeProcessor, CreatorFeeProcessor.processCreatorFee.selector, true
        );

        if (creatorManager != address(0)) {
            pm.setOperatorPermission(creatorManager, d.creatorFeeVault, CreatorFeeVault.setCreator.selector, true);
        }

        if (collector != address(0)) {
            pm.setOperatorPermission(collector, d.lpManager, LPManager.collect.selector, true);
        }
    }

    // ── Internal: GiwaRouter ────────────────────────────────────────

    function _deployGiwaRouter(
        address protocolManager_,
        address bondingCurve_,
        address tokenRegistry_,
        address weth_,
        address v3SwapAdapter_,
        address quoterV2_
    ) internal returns (address) {
        return _deployProxy(
            address(new GiwaRouter()),
            abi.encodeCall(
                GiwaRouter.initialize,
                (protocolManager_, bondingCurve_, tokenRegistry_, weth_, v3SwapAdapter_, quoterV2_)
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
        _verifyV3Wiring(d);
        _verifyPermissions(d);
        _verifyAdminRotation(d);
        console.log("All verifications passed!");
    }

    function _verifyProtocolConfig(Deployed memory d) internal view {
        ProtocolManager pm = ProtocolManager(d.protocolManager);
        QuoteTokenConfig memory expectedConfig = _quoteTokenConfig();

        require(pm.feeReceiver() == vm.envAddress("FEE_RECEIVER"), "Verify: feeReceiver mismatch");
        _verifyQuoteTokenConfig(pm, d.weth, expectedConfig, 0);
        IProtocolManager.QuoteConfig memory wethConfig = pm.getConfig(d.weth);
        require(wethConfig.v3FeeTier == expectedConfig.v3FeeTier, "Verify: WETH V3 fee tier mismatch");
        require(
            wethConfig.lpFeeProtocolShareBps == expectedConfig.lpFeeProtocolShareBps,
            "Verify: WETH LP fee share mismatch"
        );

        uint256[] memory expectedTable = _snipingPenaltyTable();
        require(pm.snipingPenaltyTableLength() == expectedTable.length, "Verify: snipingPenaltyTable length mismatch");
        for (uint256 i = 0; i < expectedTable.length; i++) {
            require(pm.snipingPenaltyAt(i) == expectedTable[i], "Verify: snipingPenaltyTable entry mismatch");
        }
    }

    function _verifyQuoteTokenConfig(
        ProtocolManager pm,
        address quoteToken,
        QuoteTokenConfig memory expectedConfig,
        uint16 expectedDexProtocolFeeRate
    ) internal view {
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
        require(actualConfig.dexProtocolFeeRate == expectedDexProtocolFeeRate, "Verify: dexProtocolFeeRate mismatch");
    }

    function _verifyV3Wiring(Deployed memory d) internal view {
        require(d.weth == _canonicalWeth(), "Verify: non-canonical WETH");
        require(d.v3Factory.code.length > 0, "Verify: V3 factory missing code");
        require(
            IUniswapV3Factory(d.v3Factory).owner() == vm.envAddress("MULTISIG"), "Verify: V3 factory owner mismatch"
        );
        require(
            IUniswapV3Factory(d.v3Factory).feeAmountTickSpacing(_readUint24("V3_FEE_TIER")) != 0,
            "Verify: unsupported V3 fee tier"
        );
        require(V3PoolDeployer(d.v3PoolDeployer).factory() == d.v3Factory, "Verify: pool deployer factory mismatch");

        IV3LiquidityActor actor = IV3LiquidityActor(d.v3LiquidityActor);
        require(actor.owner() == d.lpManager, "Verify: liquidity actor owner mismatch");
        require(actor.factory() == d.v3Factory, "Verify: liquidity actor factory mismatch");
        require(LPManager(d.lpManager).v3LiquidityActor() == d.v3LiquidityActor, "Verify: LPManager actor mismatch");
        require(LPManager(d.lpManager).v3Factory() == d.v3Factory, "Verify: LPManager factory mismatch");
        require(
            LPManager(d.lpManager).creatorFeeProcessor() == d.creatorFeeProcessor,
            "Verify: LPManager processor mismatch"
        );
        require(LPManager(d.lpManager).v3SwapAdapter() == d.v3SwapAdapter, "Verify: LPManager adapter mismatch");
        require(
            address(CreatorFeeProcessor(d.creatorFeeProcessor).protocolManager()) == d.protocolManager,
            "Verify: processor authority mismatch"
        );

        IV3SwapAdapter adapter = IV3SwapAdapter(d.v3SwapAdapter);
        require(adapter.factory() == d.v3Factory, "Verify: swap adapter factory mismatch");
        require(adapter.tokenRegistry() == d.tokenRegistry, "Verify: swap adapter registry mismatch");

        IPeripheryImmutableState quoter = IPeripheryImmutableState(d.quoterV2);
        require(quoter.factory() == d.v3Factory, "Verify: QuoterV2 factory mismatch");
        require(quoter.WETH9() == d.weth, "Verify: QuoterV2 WETH mismatch");

        GiwaRouter router = GiwaRouter(payable(d.giwaRouter));
        require(router.authority() == d.protocolManager, "Verify: GiwaRouter authority mismatch");
        require(router.bondingCurve() == d.bondingCurve, "Verify: GiwaRouter curve mismatch");
        require(router.tokenRegistry() == d.tokenRegistry, "Verify: GiwaRouter registry mismatch");
        require(router.wrappedNative() == d.weth, "Verify: GiwaRouter WETH mismatch");
        require(router.v3SwapAdapter() == d.v3SwapAdapter, "Verify: GiwaRouter adapter mismatch");
        require(router.quoterV2() == d.quoterV2, "Verify: GiwaRouter quoter mismatch");
    }

    function _verifyPermissions(Deployed memory d) internal view {
        ProtocolManager pm = ProtocolManager(d.protocolManager);
        BondingCurve bc = BondingCurve(payable(d.bondingCurve));

        (bool canCreatePool,) = pm.canCall(d.bondingCurve, d.v3PoolDeployer, V3PoolDeployer.createPool.selector);
        require(canCreatePool, "Verify: BondingCurve cannot create V3 pool");
        (bool canRegister,) = pm.canCall(d.bondingCurve, d.tokenRegistry, TokenRegistry.registerV3.selector);
        require(canRegister, "Verify: BondingCurve cannot call TokenRegistry.registerV3");
        (bool canAllocate,) = pm.canCall(d.bondingCurve, d.lpManager, LPManager.allocate.selector);
        require(canAllocate, "Verify: BondingCurve cannot call LPManager.allocate");
        (bool canSetup,) = pm.canCall(d.bondingCurve, d.creatorFeeProcessor, CreatorFeeProcessor.setup.selector);
        require(canSetup, "Verify: BondingCurve cannot set up creator fees");
        (bool canProcessCreatorFee,) =
            pm.canCall(d.lpManager, d.creatorFeeProcessor, CreatorFeeProcessor.processCreatorFee.selector);
        require(canProcessCreatorFee, "Verify: LPManager cannot process creator fees");

        require(bc.hasRole(bc.ROUTER_ROLE(), d.giwaRouter), "Verify: GiwaRouter missing ROUTER_ROLE");
        require(bc.creatorFeeProcessor() == d.creatorFeeProcessor, "Verify: creatorFeeProcessor mismatch");

        address creatorManager = vm.envOr("CREATOR_MANAGER", address(0));
        if (creatorManager != address(0)) {
            (bool canSetCreator,) = pm.canCall(creatorManager, d.creatorFeeVault, CreatorFeeVault.setCreator.selector);
            require(canSetCreator, "Verify: creatorManager missing setCreator permission");
        }

        address collector = vm.envOr("COLLECTOR", vm.envAddress("MULTISIG"));
        require(
            pm.isOperatorAllowed(collector, d.lpManager, LPManager.collect.selector),
            "Verify: collector missing collect permission"
        );
        require(
            !pm.isOperatorAllowed(collector, d.lpManager, LPManager.allocate.selector),
            "Verify: collector has excess LPManager permission"
        );
    }

    function _verifyAdminRotation(Deployed memory d) internal view {
        address deployer = vm.envAddress("DEPLOYER");
        address multisig = vm.envAddress("MULTISIG");

        ProtocolManager pm = ProtocolManager(d.protocolManager);
        BondingCurve bc = BondingCurve(payable(d.bondingCurve));

        require(pm.owner() == multisig, "Verify: PM owner mismatch");
        require(bc.hasRole(bc.DEFAULT_ADMIN_ROLE(), multisig), "Verify: BC admin role mismatch");
        require(bc.hasRole(bc.GUARDIAN_ROLE(), multisig), "Verify: BC guardian role mismatch");
        if (deployer != multisig) {
            require(!bc.hasRole(bc.DEFAULT_ADMIN_ROLE(), deployer), "Verify: deployer admin role not revoked");
            require(!bc.hasRole(bc.GUARDIAN_ROLE(), deployer), "Verify: deployer guardian role not revoked");
        }
    }

    // ── Logging ─────────────────────────────────────────────────────

    function _logDeployment(Deployed memory d) internal view {
        console.log("========================================");
        console.log("Deployment complete!");
        console.log("========================================");
        _logEnvAddress("WETH_ADDRESS", d.weth);
        _logEnvAddress("TOKEN_IMPL", d.tokenImpl);
        _logEnvAddress("PROTOCOL_MANAGER", d.protocolManager);
        _logEnvAddress("TOKEN_REGISTRY", d.tokenRegistry);
        _logEnvAddress("LP_MANAGER", d.lpManager);
        _logEnvAddress("BONDING_CURVE", d.bondingCurve);
        _logEnvAddress("CREATOR_FEE_PROCESSOR", d.creatorFeeProcessor);
        _logEnvAddress("V3_FACTORY", d.v3Factory);
        _logEnvAddress("V3_POOL_DEPLOYER", d.v3PoolDeployer);
        _logEnvAddress("V3_LIQUIDITY_ACTOR", d.v3LiquidityActor);
        _logEnvAddress("V3_SWAP_ADAPTER", d.v3SwapAdapter);
        _logEnvAddress("QUOTER_V2", d.quoterV2);
        _logEnvAddress("VAULT_REGISTRY", d.vaultRegistry);
        _logEnvAddress("CREATOR_FEE_VAULT", d.creatorFeeVault);
        _logEnvAddress("GIWA_ROUTER", d.giwaRouter);
        console.log("========================================");
    }

    function _logEnvAddress(string memory key, address value) internal pure {
        console.log(string.concat(key, "=\"", vm.toString(value), "\""));
    }
}
