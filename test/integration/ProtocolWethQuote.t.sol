// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {IPeripheryImmutableState} from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import {WETH} from "solady/tokens/WETH.sol";

import {Deploy, GIWA_WETH} from "../../script/deploy/normal/Deploy.s.sol";
import {V3LiquidityActor} from "../../src/actors/V3LiquidityActor.sol";
import {BondingCurve} from "../../src/core/BondingCurve.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {V3PoolDeployer} from "../../src/core/V3PoolDeployer.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {IV3SwapAdapter} from "../../src/interfaces/IV3SwapAdapter.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";
import {VaultRegistry} from "../../src/vault/VaultRegistry.sol";

contract MultisigContractStub {}

contract DeployHarness is Deploy {
    function deployCanonicalWethAndProtocolManager(address admin, address feeReceiver)
        external
        returns (address weth, address protocolManager)
    {
        return _deployCanonicalWethAndProtocolManager(admin, feeReceiver, _testConfig());
    }

    function canonicalWeth() external view returns (address) {
        return _canonicalWeth();
    }

    function readUint24(string memory key) external view returns (uint24) {
        return _readUint24(key);
    }

    function transferAdmin(Deployed memory deployed, address newAdmin) external {
        _transferAdminToMultisig(deployed, newAdmin, address(this));
    }

    function deployCanonicalV3Graph(address v3Factory, address creatorManager, address collector)
        external
        returns (Deployed memory d)
    {
        d.v3Factory = v3Factory;
        (d.weth, d.protocolManager) =
            _deployCanonicalWethAndProtocolManager(address(this), address(0xFEE), _testConfig());
        d.tokenRegistry = _deployTokenRegistry(d.protocolManager);
        d.creatorFeeProcessor = _deployCreatorFeeProcessor(d.protocolManager);
        d.v3SwapAdapter = _deployV3SwapAdapter(d.v3Factory, d.tokenRegistry);
        d.lpManager = _deployLPManager(d.protocolManager, d.tokenRegistry, d.creatorFeeProcessor, d.v3SwapAdapter);
        d.v3PoolDeployer = _deployV3PoolDeployer(d.protocolManager, d.v3Factory);
        d.v3LiquidityActor = address(new V3LiquidityActor(d.lpManager, d.v3Factory));
        LPManager(d.lpManager).setV3LiquidityActor(d.v3LiquidityActor, d.v3Factory);
        d.tokenImpl = address(this);
        d.bondingCurve = _deployBondingCurve(address(this), d.tokenImpl, d.protocolManager);
        (d.quoterV2, d.giwaRouter) =
            _deployV3Routing(d.protocolManager, d.bondingCurve, d.tokenRegistry, d.weth, d.v3SwapAdapter, d.v3Factory);

        d.vaultRegistry = _deployVaultRegistry(d.protocolManager);
        _deployVaults(d, "ipfs://creator-fee-vault");
        _registerModules(d);
        _setPermissions(d, creatorManager, collector);

        BondingCurve bondingCurve = BondingCurve(payable(d.bondingCurve));
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), d.giwaRouter);
    }

    function _testConfig() private pure returns (ProtocolDeploymentConfig memory config) {
        config.quoteToken = QuoteTokenConfig({
            virtualReserve: 70_000 ether,
            virtualTokenReserve: 1_060_569_000 ether,
            minTokenReserve: 251_660_440_677_966_101_694_915_255,
            deployFee: 10 ether,
            graduateFee: 1_000 ether,
            curveProtocolFeeRate: 100,
            v3FeeTier: 3000,
            lpFeeProtocolShareBps: 5000
        });
        config.snipingPenaltyTable = new uint256[](1);
    }
}

contract ProtocolWethQuoteTest is Test {
    address private constant FEE_RECEIVER = address(0xFEE);

    function setUp() public {
        vm.etch(GIWA_WETH, type(WETH).runtimeCode);
    }

    function test_canonicalWethPredeployIsReusedWithoutCreate() public {
        DeployHarness harness = new DeployHarness();
        uint64 nonceBefore = vm.getNonce(address(harness));

        (address weth, address protocolManagerAddress) =
            harness.deployCanonicalWethAndProtocolManager(address(harness), FEE_RECEIVER);

        assertEq(weth, 0x4200000000000000000000000000000000000006);
        assertEq(weth, harness.canonicalWeth());
        assertEq(vm.getNonce(address(harness)), nonceBefore + 2, "only ProtocolManager impl and proxy should deploy");

        IProtocolManager.QuoteConfig memory wethConfig = ProtocolManager(protocolManagerAddress).getConfig(weth);
        assertTrue(wethConfig.active);
        assertEq(wethConfig.dexProtocolFeeRate, 0);
        assertEq(wethConfig.v3FeeTier, 3000);
        assertEq(wethConfig.lpFeeProtocolShareBps, 5000);
    }

    function test_canonicalWethRequiresPredeployCode() public {
        vm.etch(GIWA_WETH, hex"");
        DeployHarness harness = new DeployHarness();

        vm.expectRevert("Deploy: canonical WETH missing code");
        harness.canonicalWeth();
    }

    function test_readUint24RejectsOverflow() public {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("OVERFLOWING_UINT24", vm.toString(uint256(type(uint24).max) + 1));

        DeployHarness harness = new DeployHarness();
        vm.expectRevert("Deploy: uint24 env overflow");
        harness.readUint24("OVERFLOWING_UINT24");
    }

    function test_runSupportsContractMultisigWithoutItsPrivateKey() public {
        uint256 deployerPrivateKey = 0xA11CE;
        address deployer = vm.addr(deployerPrivateKey);
        address feeReceiver = makeAddr("deployFeeReceiver");
        MultisigContractStub multisig = new MultisigContractStub();
        UniswapV3Factory factory = new UniswapV3Factory();
        factory.setOwner(address(multisig));

        _setEnv("PRIVATE_KEY", vm.toString(deployerPrivateKey));
        _setEnv("DEPLOYER", vm.toString(deployer));
        _setEnv("MULTISIG_PRIVATE_KEY", "");
        _setEnv("MULTISIG", vm.toString(address(multisig)));
        _setEnv("COLLECTOR", vm.toString(address(multisig)));
        _setEnv("CREATOR_MANAGER", vm.toString(address(0)));
        _setEnv("CHAIN_ID", vm.toString(block.chainid));
        _setEnv("FEE_RECEIVER", vm.toString(feeReceiver));
        _setEnv("V3_FACTORY", vm.toString(address(factory)));
        _setEnv("VIRTUAL_RESERVE", vm.toString(uint256(70_000 ether)));
        _setEnv("VIRTUAL_TOKEN_RESERVE", vm.toString(uint256(1_060_569_000 ether)));
        _setEnv("MIN_TOKEN_RESERVE", vm.toString(uint256(251_660_440_677_966_101_694_915_255)));
        _setEnv("DEPLOY_FEE", vm.toString(uint256(10 ether)));
        _setEnv("GRADUATE_FEE", vm.toString(uint256(1_000 ether)));
        _setEnv("CURVE_PROTOCOL_FEE_RATE", "100");
        _setEnv("V3_FEE_TIER", "3000");
        _setEnv("LP_FEE_PROTOCOL_SHARE_BPS", "5000");
        _setEnv("SNIPING_PENALTY_TABLE", "8000,4000,2000,1500,1000,1000,500");
        _setEnv("CREATOR_FEE_VAULT_METADATA_URI", "ipfs://creator-fee-vault");

        new Deploy().run();
    }

    function test_deploymentHarnessWiresCanonicalV3AndOnlyCreatorFeeVault() public {
        UniswapV3Factory factory = new UniswapV3Factory();
        DeployHarness harness = new DeployHarness();
        address creatorManager = address(0xC0FFEE);
        address collector = address(0xC011EC70);

        vm.recordLogs();
        Deploy.Deployed memory deployed = harness.deployCanonicalV3Graph(address(factory), creatorManager, collector);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertRouting(deployed, address(factory));
        _assertPermissions(deployed, creatorManager, collector);

        BondingCurve bondingCurve = BondingCurve(payable(deployed.bondingCurve));
        assertTrue(bondingCurve.hasRole(bondingCurve.ROUTER_ROLE(), deployed.giwaRouter));
        assertEq(
            address(CreatorFeeProcessor(deployed.creatorFeeProcessor).protocolManager()),
            deployed.protocolManager,
            "Processor authority"
        );
        assertEq(CreatorFeeVault(payable(deployed.creatorFeeVault)).wmon(), GIWA_WETH);
        assertTrue(VaultRegistry(deployed.vaultRegistry).isActive(deployed.creatorFeeVault));
        _assertRegistrationLogs(logs, deployed);
        assertEq(
            uint8(VaultRegistry(deployed.vaultRegistry).getVaultType(deployed.creatorFeeVault)),
            uint8(IVaultRegistry.VaultType.Creator)
        );
    }

    function test_deploymentHarnessTransfersAllAdminAuthority() public {
        UniswapV3Factory factory = new UniswapV3Factory();
        DeployHarness harness = new DeployHarness();
        Deploy.Deployed memory deployed =
            harness.deployCanonicalV3Graph(address(factory), address(0), address(0xC011EC70));
        address newAdmin = address(new MultisigContractStub());

        harness.transferAdmin(deployed, newAdmin);

        ProtocolManager protocolManager = ProtocolManager(deployed.protocolManager);
        BondingCurve bondingCurve = BondingCurve(payable(deployed.bondingCurve));
        assertEq(protocolManager.owner(), newAdmin);
        assertTrue(bondingCurve.hasRole(bondingCurve.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertTrue(bondingCurve.hasRole(bondingCurve.GUARDIAN_ROLE(), newAdmin));
        assertFalse(bondingCurve.hasRole(bondingCurve.DEFAULT_ADMIN_ROLE(), address(harness)));
        assertFalse(bondingCurve.hasRole(bondingCurve.GUARDIAN_ROLE(), address(harness)));
    }

    function test_deploymentHarnessKeepsRolesForSingleTestnetAdmin() public {
        UniswapV3Factory factory = new UniswapV3Factory();
        DeployHarness harness = new DeployHarness();
        Deploy.Deployed memory deployed =
            harness.deployCanonicalV3Graph(address(factory), address(0), address(0xC011EC70));

        harness.transferAdmin(deployed, address(harness));

        ProtocolManager protocolManager = ProtocolManager(deployed.protocolManager);
        BondingCurve bondingCurve = BondingCurve(payable(deployed.bondingCurve));
        assertEq(protocolManager.owner(), address(harness));
        assertTrue(bondingCurve.hasRole(bondingCurve.DEFAULT_ADMIN_ROLE(), address(harness)));
        assertTrue(bondingCurve.hasRole(bondingCurve.GUARDIAN_ROLE(), address(harness)));
    }

    function _assertRouting(Deploy.Deployed memory deployed, address factory) private view {
        assertEq(deployed.weth, GIWA_WETH);
        GiwaRouter router = GiwaRouter(payable(deployed.giwaRouter));
        assertEq(router.authority(), deployed.protocolManager);
        assertEq(router.bondingCurve(), deployed.bondingCurve);
        assertEq(router.tokenRegistry(), deployed.tokenRegistry);
        assertEq(router.wrappedNative(), GIWA_WETH);
        assertEq(router.v3SwapAdapter(), deployed.v3SwapAdapter);
        assertEq(router.quoterV2(), deployed.quoterV2);

        IPeripheryImmutableState quoter = IPeripheryImmutableState(deployed.quoterV2);
        assertEq(quoter.factory(), address(factory));
        assertEq(quoter.WETH9(), GIWA_WETH);
        assertEq(IV3SwapAdapter(deployed.v3SwapAdapter).factory(), address(factory));
        assertEq(IV3SwapAdapter(deployed.v3SwapAdapter).tokenRegistry(), deployed.tokenRegistry);
        assertEq(V3PoolDeployer(deployed.v3PoolDeployer).factory(), address(factory));
        assertEq(LPManager(deployed.lpManager).v3Factory(), address(factory));
        assertEq(LPManager(deployed.lpManager).v3LiquidityActor(), deployed.v3LiquidityActor);
        assertEq(LPManager(deployed.lpManager).creatorFeeProcessor(), deployed.creatorFeeProcessor);
        assertEq(LPManager(deployed.lpManager).v3SwapAdapter(), deployed.v3SwapAdapter);
    }

    function _assertPermissions(Deploy.Deployed memory deployed, address creatorManager, address collector)
        private
        view
    {
        ProtocolManager protocolManager = ProtocolManager(deployed.protocolManager);
        (bool canCreatePool,) =
            protocolManager.canCall(deployed.bondingCurve, deployed.v3PoolDeployer, V3PoolDeployer.createPool.selector);
        (bool canRegisterV3,) =
            protocolManager.canCall(deployed.bondingCurve, deployed.tokenRegistry, TokenRegistry.registerV3.selector);
        (bool canAllocate,) =
            protocolManager.canCall(deployed.bondingCurve, deployed.lpManager, LPManager.allocate.selector);
        (bool canSetup,) = protocolManager.canCall(
            deployed.bondingCurve, deployed.creatorFeeProcessor, CreatorFeeProcessor.setup.selector
        );
        (bool canProcessCreatorFee,) = protocolManager.canCall(
            deployed.lpManager, deployed.creatorFeeProcessor, CreatorFeeProcessor.processCreatorFee.selector
        );
        bool canCollect = protocolManager.isOperatorAllowed(collector, deployed.lpManager, LPManager.collect.selector);
        bool canCollectorAllocate =
            protocolManager.isOperatorAllowed(collector, deployed.lpManager, LPManager.allocate.selector);
        (bool canSetCreator,) =
            protocolManager.canCall(creatorManager, deployed.creatorFeeVault, CreatorFeeVault.setCreator.selector);
        assertTrue(canCreatePool);
        assertTrue(canRegisterV3);
        assertTrue(canAllocate);
        assertTrue(canSetup);
        assertTrue(canProcessCreatorFee);
        assertTrue(canCollect);
        assertFalse(canCollectorAllocate, "collector permission must be selector-scoped");
        assertTrue(canSetCreator);
    }

    function _assertRegistrationLogs(Vm.Log[] memory logs, Deploy.Deployed memory deployed) private pure {
        bytes32 vaultRegisterSignature = keccak256("Register(address,string,address,uint8)");
        bytes32 moduleUpdateSignature = keccak256("ModuleUpdate(bytes32,address)");
        bytes32 legacyFactoryModule = keccak256("FACTORY");
        bytes32 feeCollectorModule = keccak256("FEE_COLLECTOR");
        uint256 vaultRegistrations;
        uint256 moduleRegistrations;
        bool legacyFactoryRegistered;
        bool feeCollectorRegistered;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == deployed.vaultRegistry && logs[i].topics[0] == vaultRegisterSignature) {
                vaultRegistrations++;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), deployed.creatorFeeVault);
            }
            if (logs[i].emitter == deployed.bondingCurve && logs[i].topics[0] == moduleUpdateSignature) {
                moduleRegistrations++;
                if (logs[i].topics[1] == legacyFactoryModule) legacyFactoryRegistered = true;
                if (logs[i].topics[1] == feeCollectorModule) feeCollectorRegistered = true;
            }
        }

        assertEq(vaultRegistrations, 1, "only CreatorFeeVault should be registered");
        assertEq(moduleRegistrations, 5, "only active V3 lifecycle modules should be registered");
        assertFalse(legacyFactoryRegistered, "legacy Nad factory module must not be registered");
        assertFalse(feeCollectorRegistered, "FeeCollector module must not be registered");
    }

    function _setEnv(string memory key, string memory value) private {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(key, value);
    }
}
