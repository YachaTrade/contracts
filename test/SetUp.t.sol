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
import {V3PoolDeployer} from "../src/core/V3PoolDeployer.sol";
import {V3LiquidityActor} from "../src/actors/V3LiquidityActor.sol";
import {GiwaRouter} from "../src/router/GiwaRouter.sol";
import {IGiwaRouter} from "../src/interfaces/IGiwaRouter.sol";
import {IBondingCurve} from "../src/interfaces/IBondingCurve.sol";

// DEX
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {QuoterV2} from "@uniswap/v3-periphery/contracts/lens/QuoterV2.sol";

// Token
import {Token} from "../src/token/Token.sol";
import {CreatorFeeProcessor} from "../src/core/CreatorFeeProcessor.sol";

// Vault
import {VaultRegistry} from "../src/vault/VaultRegistry.sol";
import {IVaultRegistry} from "../src/interfaces/IVaultRegistry.sol";
import {CreatorFeeVault} from "../src/vault/CreatorFeeVault.sol";

import {V3SwapAdapter} from "../src/adapters/V3SwapAdapter.sol";

// Mocks
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";

/// @title SetUp -- Shared base test contract for GIWA
/// @notice Deploys the full protocol stack with real contracts (no mocks except MockERC20/MockWrappedNative).
/// @dev Deployment order mirrors the fresh V3-only deployment graph.
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
    MockWrappedNative public wnative;

    // -- Core (UUPS Proxies) --------------------------------------
    ProtocolManager public protocolManager;
    BondingCurve public bondingCurve;
    TokenRegistry public tokenRegistry;
    LPManager public lpManager;
    V3PoolDeployer public v3PoolDeployer;
    V3LiquidityActor public v3LiquidityActor;

    // -- Router ---------------------------------------------------
    GiwaRouter public giwaRouter;

    // -- Token ----------------------------------------------------
    Token public tokenImpl;
    CreatorFeeProcessor public creatorFeeProcessor;

    // -- DEX ------------------------------------------------------
    UniswapV3Factory public v3Factory;
    QuoterV2 public quoterV2;

    // -- Adapter --------------------------------------------------
    V3SwapAdapter public v3SwapAdapter;

    // -- Vault ----------------------------------------------------
    VaultRegistry public vaultRegistry;
    CreatorFeeVault public creatorFeeVault;

    // -- Constants ------------------------------------------------
    uint256 public constant VIRTUAL_RESERVE = 70_000 ether;
    uint256 public constant VIRTUAL_TOKEN_RESERVE = 1_060_569_000 ether;
    uint256 public constant MIN_TOKEN_RESERVE = 251_660_440_677_966_101_694_915_255;
    uint16 public constant DEFAULT_CURVE_PROTOCOL_FEE = 100; // 1%
    uint16 public constant DEFAULT_DEX_PROTOCOL_FEE = 35; // 0.35%
    uint256 public constant DEFAULT_DEPLOY_FEE = 10 ether;
    uint256 public constant DEFAULT_GRADUATE_FEE = 1_000 ether;
    uint24 public constant DEFAULT_V3_FEE_TIER = 3_000;
    uint16 public constant DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS = 5_000;

    // -- Runtime config ------------------------------------------
    uint256 public virtualReserve;
    uint256 public virtualTokenReserve;
    uint256 public minTokenReserve;
    uint16 public defaultCurveProtocolFee;
    uint16 public defaultDexProtocolFee;
    uint256 public defaultDeployFee;
    uint256 public defaultGraduateFee;

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
        quoteToken = new MockERC20("WNATIVE", "WNATIVE", 18);
        wnative = new MockWrappedNative();

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
            defaultDexProtocolFee
        );
        protocolManager.setV3QuoteConfig(address(quoteToken), DEFAULT_V3_FEE_TIER, DEFAULT_LP_FEE_PROTOCOL_SHARE_BPS);
        protocolManager.setSnipingPenaltyTable(_testSnipingPenaltyTable());

        // 4. TokenRegistry (UUPS proxy)
        TokenRegistry trImpl = new TokenRegistry();
        tokenRegistry = TokenRegistry(
            address(
                new ERC1967Proxy(address(trImpl), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager))))
            )
        );

        // 5. Creator fee and canonical V3 swap dependencies.
        creatorFeeProcessor = new CreatorFeeProcessor(address(protocolManager));
        v3Factory = new UniswapV3Factory();
        v3SwapAdapter = new V3SwapAdapter(address(v3Factory), address(tokenRegistry));

        // 6. LPManager (UUPS proxy)
        LPManager lmImpl = new LPManager();
        lpManager = LPManager(
            address(
                new ERC1967Proxy(
                    address(lmImpl),
                    abi.encodeCall(
                        LPManager.initialize,
                        (
                            address(protocolManager),
                            address(tokenRegistry),
                            address(creatorFeeProcessor),
                            address(v3SwapAdapter)
                        )
                    )
                )
            )
        );

        V3PoolDeployer v3PoolDeployerImpl = new V3PoolDeployer();
        v3PoolDeployer = V3PoolDeployer(
            address(
                new ERC1967Proxy(
                    address(v3PoolDeployerImpl),
                    abi.encodeCall(V3PoolDeployer.initialize, (address(protocolManager), address(v3Factory)))
                )
            )
        );
        v3LiquidityActor = new V3LiquidityActor(address(lpManager), address(v3Factory));
        lpManager.setV3LiquidityActor(address(v3LiquidityActor), address(v3Factory));

        // 7. Token implementation (clone template) -- plain ERC20, no creator-fee-on-transfer
        tokenImpl = new Token();

        // 8. BondingCurve (UUPS proxy)
        BondingCurve bcImpl = new BondingCurve();
        bondingCurve = BondingCurve(
            payable(address(
                    new ERC1967Proxy(
                        address(bcImpl),
                        abi.encodeCall(BondingCurve.initialize, (admin, address(tokenImpl), address(protocolManager)))
                    )
                ))
        );

        // 9. GiwaRouter (UUPS proxy)
        quoterV2 = new QuoterV2(address(v3Factory), address(wnative));
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
                                address(wnative),
                                address(v3SwapAdapter),
                                address(quoterV2)
                            )
                        )
                    )
                ))
        );

        // 10. VaultRegistry (UUPS proxy)
        VaultRegistry vrImpl = new VaultRegistry();
        vaultRegistry = VaultRegistry(
            address(
                new ERC1967Proxy(address(vrImpl), abi.encodeCall(VaultRegistry.initialize, (address(protocolManager))))
            )
        );

        // 11. Creator fee vault singleton (UUPS proxy)
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
                                ""
                            )
                        )
                    )
                ))
        );

        // 12. Register the only vault supported by fresh deployments.
        vaultRegistry.register(
            address(creatorFeeVault), "CreatorFeeVault", "Direct transfer", IVaultRegistry.VaultType.Creator
        );

        // 13. BondingCurve module registration
        bondingCurve.setModule(keccak256("TOKEN_REGISTRY"), address(tokenRegistry));
        bondingCurve.setModule(keccak256("LP_MANAGER"), address(lpManager));
        bondingCurve.setModule(keccak256("CREATOR_FEE_PROCESSOR"), address(creatorFeeProcessor));
        bondingCurve.setModule(keccak256("VAULT_REGISTRY"), address(vaultRegistry));
        bondingCurve.setModule(keccak256("V3_POOL_DEPLOYER"), address(v3PoolDeployer));

        // 14. Authorize the active V3 lifecycle graph.
        protocolManager.setOperatorPermission(
            address(bondingCurve), address(v3PoolDeployer), V3PoolDeployer.createPool.selector, true
        );
        protocolManager.setOperatorPermission(
            address(bondingCurve), address(tokenRegistry), TokenRegistry.registerV3.selector, true
        );
        protocolManager.setOperatorPermission(
            address(bondingCurve), address(lpManager), LPManager.allocate.selector, true
        );
        protocolManager.setOperatorPermission(
            address(bondingCurve), address(creatorFeeProcessor), CreatorFeeProcessor.setup.selector, true
        );
        protocolManager.setOperatorPermission(
            address(lpManager), address(creatorFeeProcessor), CreatorFeeProcessor.processCreatorFee.selector, true
        );
        // Tests act as the V3 fee collector keeper.
        protocolManager.setOperatorPermission(address(this), address(lpManager), LPManager.collect.selector, true);

        // 15. Grant ROUTER_ROLE to GiwaRouter.
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(giwaRouter));

        vm.stopPrank();

        // 16. Skip anti-sniping period (100 minutes)
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
        if (vm.envExists("TEST_SNIPING_PENALTY_TABLE")) {
            table = vm.envUint("TEST_SNIPING_PENALTY_TABLE", ",");
        } else if (vm.envExists("SNIPING_PENALTY_TABLE")) {
            table = vm.envUint("SNIPING_PENALTY_TABLE", ",");
        } else {
            table = _defaultSnipingPenaltyTable();
        }
        require(table.length > 0, "SetUp: empty sniping penalty table");
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
            vaults: vaults,
            salt: keccak256("default-test-token"),
            dexType: ITokenRegistry.DexType.UniswapV3,
            creator: address(this),
            buyQuoteAmount: 0
        });
    }

    /// @notice Returns CreateTokenParams with custom name, symbol, and salt.
    function _createTokenParams(string memory name, string memory symbol, bytes32 salt)
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
            vaults: vaults,
            salt: salt,
            dexType: ITokenRegistry.DexType.UniswapV3,
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
    function _createTokenWith(string memory name, string memory symbol, bytes32 salt) internal returns (address token) {
        token = _createViaRouter(_createTokenParams(name, symbol, salt), creator);
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

    /// @notice Buys tokens on the bonding curve through the Router.
    /// @return tokenOut Amount of tokens received by buyer
    function _buyOnCurve(address buyer, address token, uint256 quote) internal returns (uint256 tokenOut) {
        _mintAndApprove(buyer, address(giwaRouter), quote);
        vm.prank(buyer);
        tokenOut = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: quote, amountOutMin: 1, token: token, to: buyer, deadline: block.timestamp
            })
        );
    }

    /// @notice Sells tokens on the bonding curve through the Router.
    /// @return quoteOut Amount of quoteToken received by seller
    function _sellOnCurve(address seller, address token, uint256 tokenAmount) internal returns (uint256 quoteOut) {
        vm.startPrank(seller);
        IERC20(token).approve(address(giwaRouter), tokenAmount);
        quoteOut = giwaRouter.sell(
            IGiwaRouter.SellParams({
                amountIn: tokenAmount, amountOutMin: 1, token: token, to: seller, deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    // -- Helper: Graduation ----------------------------------------

    /// @notice Buys enough to graduate the token in one shot
    /// @dev Setup has already advanced past the sniping window. This input leaves enough quote
    ///      after the curve protocol fee to cross minTokenReserve and fund graduation liquidity.
    function _graduateToken(address token) internal {
        uint256 graduationAmount = 800_000 ether;
        _mintAndApprove(user1, address(giwaRouter), graduationAmount);
        vm.prank(user1);
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: graduationAmount, amountOutMin: 1, token: token, to: user1, deadline: block.timestamp
            })
        );
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        require(curve.graduated, "Token should be graduated");
    }

    // -- Helper: Anti-Sniping --------------------------------------

    /// @notice Advances `block.number` past the per-block sniping table so subsequent buys/sells
    ///         pay no sniping fee. The 100-minute timestamp bump is preserved for any callers that
    ///         also depend on time-based test assumptions.
    function _skipAntiSniping() internal {
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }
}
