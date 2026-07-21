// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Core
import {BondingCurve} from "../src/core/BondingCurve.sol";
import {ProtocolManager} from "../src/core/ProtocolManager.sol";
import {TokenRegistry} from "../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../src/interfaces/ITokenRegistry.sol";
import {LPManager} from "../src/core/LPManager.sol";
import {GiwaRouter} from "../src/router/GiwaRouter.sol";
import {IGiwaRouter} from "../src/interfaces/IGiwaRouter.sol";
import {IBondingCurve} from "../src/interfaces/IBondingCurve.sol";

// DEX
import {NadFunFactory} from "../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../src/dex/NadFunPair.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {QuoterV2} from "@uniswap/v3-periphery/contracts/lens/QuoterV2.sol";

// Fee
import {FeeCollector} from "../src/core/FeeCollector.sol";

// Token
import {Token} from "../src/token/Token.sol";
import {CreatorFeeProcessor} from "../src/core/CreatorFeeProcessor.sol";

// Vault
import {VaultRegistry} from "../src/vault/VaultRegistry.sol";
import {IVaultRegistry} from "../src/interfaces/IVaultRegistry.sol";
import {BurnVault} from "../src/vault/BurnVault.sol";
import {LPVault} from "../src/vault/LPVault.sol";
import {CreatorFeeVault} from "../src/vault/CreatorFeeVault.sol";

// Adapter
import {NadSwapAdapter} from "../src/adapters/NadSwapAdapter.sol";
import {V3SwapAdapter} from "../src/adapters/V3SwapAdapter.sol";
import {IDexAdapter} from "../src/interfaces/IDexAdapter.sol";

// Mocks
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWMON} from "./mocks/MockWMON.sol";

/// @title SetUp -- Shared base test contract for GIWA
/// @notice Deploys the full protocol stack with real contracts (no mocks except MockERC20/MockWMON).
/// @dev Deployment order: ProtocolManager -> TokenRegistry -> BondingCurve -> FeeCollector ->
contract SetUp is Test {
    // -- Addresses ------------------------------------------------
    address public admin;
    address public feeReceiver;
    address public creator;
    address public user1;
    address public user2;
    address public user3;

    // -- Tokens ---------------------------------------------------
    MockERC20 public quoteToken;
    MockWMON public wmon;

    // -- Core (UUPS Proxies) --------------------------------------
    ProtocolManager public protocolManager;
    BondingCurve public bondingCurve;
    TokenRegistry public tokenRegistry;
    LPManager public lpManager;

    // -- Router ---------------------------------------------------
    GiwaRouter public giwaRouter;

    // -- Token ----------------------------------------------------
    Token public tokenImpl;
    CreatorFeeProcessor public creatorFeeProcessor;

    // -- Fee ------------------------------------------------------
    FeeCollector public feeCollector;

    // -- DEX ------------------------------------------------------
    NadFunFactory public nadFunFactory;
    UniswapV3Factory public v3Factory;
    QuoterV2 public quoterV2;

    // -- Adapter --------------------------------------------------
    NadSwapAdapter public nadSwapAdapter;
    V3SwapAdapter public v3SwapAdapter;

    // -- Vault ----------------------------------------------------
    VaultRegistry public vaultRegistry;
    BurnVault public burnVault;
    LPVault public lpVault;
    CreatorFeeVault public creatorFeeVault;

    // -- Constants ------------------------------------------------
    uint256 public constant VIRTUAL_RESERVE = 70_000 ether;
    uint256 public constant VIRTUAL_TOKEN_RESERVE = 1_060_569_000 ether;
    uint256 public constant MIN_TOKEN_RESERVE = 251_660_440_677_966_101_694_915_255;
    uint16 public constant DEFAULT_CREATOR_FEE_RATE = 100; // 1%
    uint16 public constant DEFAULT_CURVE_PROTOCOL_FEE = 100; // 1%
    uint16 public constant DEFAULT_DEX_PROTOCOL_FEE = 35; // 0.35%
    uint256 public constant DEFAULT_DEPLOY_FEE = 10 ether;
    uint256 public constant DEFAULT_GRADUATE_FEE = 1_000 ether;
    uint256 public constant SETTLEMENT_THRESHOLD = 1_000 ether;

    // -- Runtime config ------------------------------------------
    uint256 public virtualReserve;
    uint256 public virtualTokenReserve;
    uint256 public minTokenReserve;
    uint16 public defaultCreatorFeeRate;
    uint16 public defaultCurveProtocolFee;
    uint16 public defaultDexProtocolFee;
    uint256 public defaultDeployFee;
    uint256 public defaultGraduateFee;
    uint256 public settlementThreshold;

    // -- setUp ----------------------------------------------------

    function setUp() public virtual {
        // 1. Addresses
        admin = makeAddr("admin");
        feeReceiver = makeAddr("feeReceiver");
        creator = makeAddr("creator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        _loadProtocolConfig();

        // 2. Quote token + wrapped native
        quoteToken = new MockERC20("WMON", "WMON", 18);
        wmon = new MockWMON();

        vm.startPrank(admin);

        // 3. ProtocolManager (UUPS proxy)
        ProtocolManager pmImpl = new ProtocolManager();
        protocolManager = ProtocolManager(
            address(new ERC1967Proxy(address(pmImpl), abi.encodeCall(ProtocolManager.initialize, (admin, feeReceiver))))
        );
        protocolManager.addQuoteToken(
            address(quoteToken),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee,
            settlementThreshold
        );
        protocolManager.setSnipingPenaltyTable(_testSnipingPenaltyTable());
        protocolManager.setAllowedCreatorFeeRates(_testCreatorFeeRates());

        // 4. TokenRegistry (UUPS proxy)
        TokenRegistry trImpl = new TokenRegistry();
        tokenRegistry = TokenRegistry(
            address(
                new ERC1967Proxy(address(trImpl), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager))))
            )
        );

        // 4.5. Canonical V3 dependencies used by GiwaRouter.
        v3Factory = new UniswapV3Factory();
        v3SwapAdapter = new V3SwapAdapter(address(v3Factory), address(tokenRegistry));
        quoterV2 = new QuoterV2(address(v3Factory), address(wmon));

        // 5. LPManager (UUPS proxy)
        LPManager lmImpl = new LPManager();
        lpManager = LPManager(
            address(
                new ERC1967Proxy(
                    address(lmImpl),
                    abi.encodeCall(LPManager.initialize, (address(protocolManager), address(tokenRegistry)))
                )
            )
        );

        // 6. Token implementation (clone template) -- plain ERC20, no creator-fee-on-transfer
        tokenImpl = new Token();

        // 7. BondingCurve (UUPS proxy)
        BondingCurve bcImpl = new BondingCurve();
        bondingCurve = BondingCurve(
            payable(address(
                    new ERC1967Proxy(
                        address(bcImpl),
                        abi.encodeCall(BondingCurve.initialize, (admin, address(tokenImpl), address(protocolManager)))
                    )
                ))
        );

        // 7.5. GiwaRouter (UUPS proxy) — FeeCollector and vaults reference it for lifecycle-aware quotes/trades.
        GiwaRouter giwaRouterImpl = new GiwaRouter();
        giwaRouter = GiwaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(giwaRouterImpl),
                        abi.encodeCall(
                            GiwaRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wmon),
                                address(v3SwapAdapter),
                                address(quoterV2)
                            )
                        )
                    )
                ))
        );

        // 8. FeeCollector + CreatorFeeProcessor (circular dependency resolved via address prediction)
        FeeCollector fcImpl = new FeeCollector();

        uint64 nonce = vm.getNonce(admin);
        // Next deploy: CreatorFeeProcessor (nonce), then FeeCollector proxy (nonce+1)
        address predictedFeeCollector = vm.computeCreateAddress(admin, nonce + 1);

        creatorFeeProcessor = new CreatorFeeProcessor(address(bondingCurve), predictedFeeCollector);

        feeCollector = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(fcImpl),
                    abi.encodeCall(
                        FeeCollector.initialize,
                        (
                            address(protocolManager),
                            address(creatorFeeProcessor),
                            address(bondingCurve),
                            address(giwaRouter)
                        )
                    )
                )
            )
        );
        require(address(feeCollector) == predictedFeeCollector, "FeeCollector address prediction failed");

        // 9. NadFunFactory
        NadFunPair pairImpl = new NadFunPair();
        nadFunFactory = new NadFunFactory(address(protocolManager), address(feeCollector), address(pairImpl));

        // 10. VaultRegistry (UUPS proxy)
        VaultRegistry vrImpl = new VaultRegistry();
        vaultRegistry = VaultRegistry(
            address(
                new ERC1967Proxy(address(vrImpl), abi.encodeCall(VaultRegistry.initialize, (address(protocolManager))))
            )
        );

        // 11. Vault singletons (UUPS proxies)
        burnVault = BurnVault(
            address(
                new ERC1967Proxy(
                    address(new BurnVault()),
                    abi.encodeCall(
                        BurnVault.initialize,
                        (
                            address(protocolManager),
                            address(tokenRegistry),
                            address(creatorFeeProcessor),
                            address(bondingCurve),
                            address(giwaRouter),
                            ""
                        )
                    )
                )
            )
        );
        lpVault = LPVault(
            address(
                new ERC1967Proxy(
                    address(new LPVault()),
                    abi.encodeCall(
                        LPVault.initialize,
                        (address(protocolManager), address(tokenRegistry), address(creatorFeeProcessor), "")
                    )
                )
            )
        );
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
                                address(wmon),
                                ""
                            )
                        )
                    )
                ))
        );

        // 12. Register vaults in VaultRegistry
        vaultRegistry.register(address(burnVault), "BurnVault", "Buyback and burn", IVaultRegistry.VaultType.Burn);
        vaultRegistry.register(address(lpVault), "LPVault", "Liquidity injection", IVaultRegistry.VaultType.LP);
        vaultRegistry.register(
            address(creatorFeeVault), "CreatorFeeVault", "Direct transfer", IVaultRegistry.VaultType.Creator
        );

        // 13. BondingCurve module registration
        bondingCurve.setModule(keccak256("TOKEN_REGISTRY"), address(tokenRegistry));
        bondingCurve.setModule(keccak256("LP_MANAGER"), address(lpManager));
        bondingCurve.setModule(keccak256("CREATOR_FEE_PROCESSOR"), address(creatorFeeProcessor));
        bondingCurve.setModule(keccak256("VAULT_REGISTRY"), address(vaultRegistry));
        bondingCurve.setModule(keccak256("FEE_COLLECTOR"), address(feeCollector));
        bondingCurve.setModule(keccak256("FACTORY"), address(nadFunFactory));

        // 14. NadSwapAdapter — register V2 adapter in TokenRegistry
        nadSwapAdapter = new NadSwapAdapter();
        tokenRegistry.setAdapter(ITokenRegistry.DexType.UniswapV2, IDexAdapter(address(nadSwapAdapter)));

        // 15. Authorize BondingCurve as operator for TokenRegistry and LPManager
        protocolManager.setOperatorPermission(
            address(bondingCurve), address(tokenRegistry), TokenRegistry.register.selector, true
        );
        protocolManager.setOperatorPermission(
            address(bondingCurve), address(lpManager), LPManager.addLiquidity.selector, true
        );
        // Tests act as the settler keeper so they can trigger FeeCollector.settle directly.
        protocolManager.setOperatorPermission(address(this), address(feeCollector), FeeCollector.settle.selector, true);

        // 16. Grant ROUTER_ROLE to GiwaRouter.
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(giwaRouter));

        vm.stopPrank();

        // 18. Skip anti-sniping period (100 minutes)
        _skipAntiSniping();
    }

    // -- Helper: Test config --------------------------------------

    function _loadProtocolConfig() internal {
        virtualReserve = _envOrUint("TEST_VIRTUAL_RESERVE", "VIRTUAL_RESERVE", VIRTUAL_RESERVE);
        virtualTokenReserve = _envOrUint("TEST_VIRTUAL_TOKEN_RESERVE", "VIRTUAL_TOKEN_RESERVE", VIRTUAL_TOKEN_RESERVE);
        minTokenReserve = _envOrUint("TEST_MIN_TOKEN_RESERVE", "MIN_TOKEN_RESERVE", MIN_TOKEN_RESERVE);
        defaultDeployFee = _envOrUint("TEST_DEPLOY_FEE", "DEPLOY_FEE", DEFAULT_DEPLOY_FEE);
        defaultGraduateFee = _envOrUint("TEST_GRADUATE_FEE", "GRADUATE_FEE", DEFAULT_GRADUATE_FEE);
        defaultCurveProtocolFee =
            _envOrUint16("TEST_CURVE_PROTOCOL_FEE_RATE", "CURVE_PROTOCOL_FEE_RATE", DEFAULT_CURVE_PROTOCOL_FEE);
        defaultDexProtocolFee =
            _envOrUint16("TEST_DEX_PROTOCOL_FEE_RATE", "DEX_PROTOCOL_FEE_RATE", DEFAULT_DEX_PROTOCOL_FEE);
        settlementThreshold = _envOrUint("TEST_SETTLEMENT_THRESHOLD", "SETTLEMENT_THRESHOLD", SETTLEMENT_THRESHOLD);

        uint16[] memory creatorRates = _testCreatorFeeRates();
        uint16 fallbackCreatorFeeRate = _containsCreatorFeeRate(creatorRates, DEFAULT_CREATOR_FEE_RATE)
            ? DEFAULT_CREATOR_FEE_RATE
            : creatorRates[0];
        defaultCreatorFeeRate =
            _envOrUint16("TEST_DEFAULT_CREATOR_FEE_RATE", "DEFAULT_CREATOR_FEE_RATE", fallbackCreatorFeeRate);
        require(_containsCreatorFeeRate(creatorRates, defaultCreatorFeeRate), "SetUp: default creator fee not allowed");
    }

    function _envOrUint(string memory testKey, string memory deployKey, uint256 fallbackValue)
        internal
        view
        returns (uint256)
    {
        return vm.envOr(testKey, vm.envOr(deployKey, fallbackValue));
    }

    function _envOrUint16(string memory testKey, string memory deployKey, uint16 fallbackValue)
        internal
        view
        returns (uint16)
    {
        return _toUint16(_envOrUint(testKey, deployKey, fallbackValue));
    }

    function _testSnipingPenaltyTable() internal view returns (uint256[] memory table) {
        uint256[] memory defaultTable = _defaultSnipingPenaltyTable();
        uint256[] memory deployTable = vm.envOr("SNIPING_PENALTY_TABLE", ",", defaultTable);
        table = vm.envOr("TEST_SNIPING_PENALTY_TABLE", ",", deployTable);
        require(table.length > 0, "SetUp: empty sniping penalty table");
    }

    function _testCreatorFeeRates() internal view returns (uint16[] memory rates) {
        uint256[] memory defaultRates = _defaultCreatorFeeRates();
        uint256[] memory deployRates = vm.envOr("CREATOR_FEE_RATES", ",", defaultRates);
        uint256[] memory rawRates = vm.envOr("TEST_CREATOR_FEE_RATES", ",", deployRates);
        require(rawRates.length > 0, "SetUp: empty creator fee rates");

        rates = new uint16[](rawRates.length);
        for (uint256 i = 0; i < rawRates.length; i++) {
            rates[i] = _toUint16(rawRates[i]);
        }
    }

    function _defaultSnipingPenaltyTable() internal pure returns (uint256[] memory table) {
        // Production sniping penalty table (BPS). index = block.number - createdAtBlock.
        // 8000/4000/2000/1500/1000/1000/500 for blocks 0..6, 0 for block 7+.
        table = new uint256[](7);
        table[0] = 8000;
        table[1] = 4000;
        table[2] = 2000;
        table[3] = 1500;
        table[4] = 1000;
        table[5] = 1000;
        table[6] = 500;
    }

    function _defaultCreatorFeeRates() internal pure returns (uint256[] memory rates) {
        rates = new uint256[](3);
        rates[0] = 100;
        rates[1] = 300;
        rates[2] = 500;
    }

    function _containsCreatorFeeRate(uint16[] memory rates, uint16 rate) internal pure returns (bool) {
        for (uint256 i = 0; i < rates.length; i++) {
            if (rates[i] == rate) return true;
        }
        return false;
    }

    function _toUint16(uint256 value) internal pure returns (uint16) {
        require(value <= type(uint16).max, "SetUp: uint16 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value);
    }

    // -- Helper: Default CreateTokenParams -------------------------

    /// @notice Returns default CreateTokenParams with CreatorFeeVault at 100% BPS, feeReceiver as recipient
    function _defaultParams() internal view returns (IBondingCurve.CreateTokenParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(feeReceiver)
        });

        params = IBondingCurve.CreateTokenParams({
            name: "TestToken",
            symbol: "TT",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: defaultCreatorFeeRate,
            vaults: vaults,
            salt: keccak256("default-test-token"),
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }

    /// @notice Returns CreateTokenParams with custom name, symbol, creatorFeeRate, and salt
    function _createTokenParams(string memory name, string memory symbol, uint16 creatorFeeRate, bytes32 salt)
        internal
        view
        returns (IBondingCurve.CreateTokenParams memory params)
    {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(feeReceiver)
        });

        params = IBondingCurve.CreateTokenParams({
            name: name,
            symbol: symbol,
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: creatorFeeRate,
            vaults: vaults,
            salt: salt,
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }

    // -- Helper: Token Creation (via GiwaRouter) -------------------

    /// @notice Creates a token with default params via GiwaRouter
    function _createToken() internal returns (address token) {
        token = _createViaRouter(_defaultParams(), creator);
    }

    /// @notice Creates a token with custom params via GiwaRouter
    function _createTokenWith(string memory name, string memory symbol, uint16 creatorFeeRate, bytes32 salt)
        internal
        returns (address token)
    {
        token = _createViaRouter(_createTokenParams(name, symbol, creatorFeeRate, salt), creator);
    }

    /// @notice Creates a token via GiwaRouter.create() -- deployFee approve + call
    function _createViaRouter(IBondingCurve.CreateTokenParams memory bcParams, address caller)
        internal
        returns (address token)
    {
        uint256 deployFee = protocolManager.deployFee(address(quoteToken));
        if (deployFee > 0) {
            quoteToken.mint(caller, deployFee);
            vm.prank(caller);
            quoteToken.approve(address(giwaRouter), deployFee);
        }
        vm.prank(caller);
        (token,) = giwaRouter.create(
            IGiwaRouter.CreateParams({
                name: bcParams.name,
                symbol: bcParams.symbol,
                tokenURI: "",
                quoteToken: bcParams.quoteToken,
                creatorFeeRate: bcParams.creatorFeeRate,
                vaults: bcParams.vaults,
                salt: bcParams.salt,
                dexType: bcParams.dexType,
                buyQuoteAmount: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    // -- Helper: Mint & Transfer -----------------------------------

    /// @notice Mints quoteToken to user and transfers it to bondingCurve (balance-change buy pattern)
    function _mintAndTransfer(address user, uint256 amount) internal {
        quoteToken.mint(user, amount);
        vm.prank(user);
        quoteToken.transfer(address(bondingCurve), amount);
    }

    /// @notice Mints quoteToken to user and approves spender
    function _mintAndApprove(address user, address spender, uint256 amount) internal {
        quoteToken.mint(user, amount);
        vm.prank(user);
        quoteToken.approve(spender, amount);
    }

    // -- Helper: Buy & Sell on Curve --------------------------------

    /// @notice Buys tokens on the bonding curve: mint quote -> transfer to BC -> call buy
    /// @return tokenOut Amount of tokens received by buyer
    function _buyOnCurve(address buyer, address token, uint256 quote) internal returns (uint256 tokenOut) {
        _mintAndTransfer(buyer, quote);
        vm.prank(buyer);
        tokenOut = bondingCurve.buy(buyer, token);
    }

    /// @notice Sells tokens on the bonding curve: user transfers token to BC -> call sell
    /// @return quoteOut Amount of quoteToken received by seller
    function _sellOnCurve(address seller, address token, uint256 tokenAmount) internal returns (uint256 quoteOut) {
        vm.startPrank(seller);
        IERC20(token).transfer(address(bondingCurve), tokenAmount);
        quoteOut = bondingCurve.sell(seller, token);
        vm.stopPrank();
    }

    // -- Helper: Graduation ----------------------------------------

    /// @notice Buys enough to graduate the token in one shot
    /// @dev With creator fees (5% + 0.5% protocolFee), need more than base ~637,540.
    function _graduateToken(address token) internal {
        uint256 graduationAmount = 800_000 ether;
        _mintAndTransfer(user1, graduationAmount);
        vm.prank(user1);
        bondingCurve.buy(user1, token);
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        require(curve.graduated, "Token should be graduated");
    }

    // -- Helper: Anti-Sniping --------------------------------------

    /// @notice Advances `block.number` past the per-block sniping table so subsequent buys/sells
    ///         pay no sniping fee. The 100-minute timestamp bump is preserved for any callers that
    ///         also depend on time-based effects (e.g. older fee accumulation paths).
    function _skipAntiSniping() internal {
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }
}
