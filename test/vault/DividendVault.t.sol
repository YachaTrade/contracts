// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DividendVault} from "../../src/vault/DividendVault.sol";
import {IDividendVault} from "../../src/interfaces/IDividendVault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockGiwaRouter} from "../mocks/MockGiwaRouter.sol";
import {NadSwapAdapter} from "../../src/adapters/NadSwapAdapter.sol";
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {UniswapV2ExternalAdapter} from "../../src/adapters/UniswapV2ExternalAdapter.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";
import {MockCapricornPool} from "../mocks/MockCapricornPool.sol";
import {UniswapV3ExternalAdapter} from "../../src/adapters/UniswapV3ExternalAdapter.sol";
import {MockBondingCurveV1} from "../mocks/MockBondingCurveV1.sol";

/// @dev Bot-driven conversion model (docs/plans/2026-06-12-dividend-bot-conversion-design.md +
///      2026-06-13-dividend-router-lane-design.md): afterDeposit records the ratio split only; the
///      operator bot converts pending quote through executeConversion — current launch tokens via
///      the GiwaRouter hop (pre-graduation curve or canonical V3), legacy V2 pools via NadSwapAdapter,
///      and external tokens through the uni adapter lanes; Merkle claim unchanged.
contract DividendVaultTest is Test {
    DividendVault public vault;
    MockERC20 public quoteToken;
    MockERC20 public memeA; // registered nad.fun token used as a dividend token
    NadFunFactory public factory;
    TokenRegistry public tokenRegistry;
    ProtocolManager public protocolManager;

    address bondingCurve = makeAddr("bondingCurve");
    MockBondingCurveV1 public bondingCurveV1; // V1 admission gate: createdAt/isGraduated source
    MockGiwaRouter public mockRouter; // the vault's router — executeConversion's router hop calls buy() on it
    NadSwapAdapter public nadSwapAdapter; // the general NadFunPair lane (USDC/WMON, cross-quote legs)
    address sourceToken = makeAddr("sourceToken"); // the dividend-enabled token (holders of this get paid)
    address operator = makeAddr("operator"); // bot identity: Merkle root publishing + conversions
    address pairA;

    uint256 constant INITIAL_TOKEN_LIQ = 100_000 ether;
    uint256 constant INITIAL_QUOTE_LIQ = 100 ether;

    function setUp() public {
        quoteToken = new MockERC20("WMON", "WMON", 18);
        memeA = new MockERC20("MEMEA", "MEMEA", 18);

        // The vault's GiwaRouter sentinel — pre-graduation curve and canonical V3 launch-token hops
        // call buy() through this branch; graduated legacy V2 pools use NadSwapAdapter instead.
        // DividendRouterLane.t.sol covers the live curve/refund and explicit legacy-V2 paths.
        mockRouter = new MockGiwaRouter(address(quoteToken));
        // The general NadFunPair lane — vanilla pool swaps (USDC/WMON, cross-quote bridge legs).
        nadSwapAdapter = new NadSwapAdapter();

        // V1 curve for the admission gate (setAllowedDividendToken pre-graduation block).
        bondingCurveV1 = new MockBondingCurveV1();

        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), makeAddr("feeReceiver")))
                )
            )
        );

        NadFunPair pairImpl = new NadFunPair();
        factory = new NadFunFactory(address(this), makeAddr("feeCollector"), address(pairImpl));
        // pairA = a real NadFunPair (quoteToken/memeA) with liquidity — the nadSwapAdapter lane
        // swaps through it (general-pool case). Router-hop tests don't touch it.
        pairA = factory.createPair(address(quoteToken), address(memeA));
        _seedLiquidity(pairA, address(memeA), INITIAL_TOKEN_LIQ, INITIAL_QUOTE_LIQ);

        tokenRegistry = TokenRegistry(
            address(
                new ERC1967Proxy(
                    address(new TokenRegistry()), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager)))
                )
            )
        );
        protocolManager.setOperatorPermission(
            bondingCurve, address(tokenRegistry), TokenRegistry.register.selector, true
        );
        tokenRegistry.setAdapter(ITokenRegistry.DexType.UniswapV2, IDexAdapter(address(new NadSwapAdapter())));

        // Register the source token (quoteToken = WMON) so setup() can resolve its quoteToken.
        vm.prank(bondingCurve);
        tokenRegistry.register(sourceToken, pairA, address(quoteToken), ITokenRegistry.DexType.UniswapV2);
        // Register memeA as a real nad.fun token (used as a dividend token).
        vm.prank(bondingCurve);
        tokenRegistry.register(address(memeA), pairA, address(quoteToken), ITokenRegistry.DexType.UniswapV2);

        // Deploy DividendVault; creatorFeeProcessor = address(this) for direct afterDeposit calls.
        vault = DividendVault(
            payable(address(
                    new ERC1967Proxy(
                        address(new DividendVault()),
                        abi.encodeCall(
                            DividendVault.initialize,
                            (
                                address(protocolManager),
                                address(tokenRegistry),
                                address(this),
                                bondingCurve,
                                address(mockRouter),
                                address(bondingCurveV1),
                                ""
                            )
                        )
                    )
                ))
        );

        // Adapter allowlist: wire the nadSwap lane for the whole suite; external uni lanes are added
        // per-test via setAdapters. The router hop needs no lane wiring — executeConversion
        // recognizes hop.adapter == router (set at init).
        _grantSelector(address(this), DividendVault.setAdapters.selector);
        vault.setAdapters(address(nadSwapAdapter), address(0), address(0));
    }

    function _seedLiquidity(address pair, address meme, uint256 tokenAmt, uint256 quoteAmt) internal {
        MockERC20(meme).mint(pair, tokenAmt);
        quoteToken.mint(pair, quoteAmt);
        INadFunPair(pair).mint(address(this));
    }

    function _grantSelector(address who, bytes4 sel) internal {
        protocolManager.setOperatorPermission(who, address(vault), sel, true);
    }

    function _setup(address[] memory tokens, uint16[] memory ratios, uint256 minBalance) internal {
        vm.prank(bondingCurve);
        vault.setup(sourceToken, abi.encode(tokens, ratios, minBalance));
    }

    function _single(address t) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = t;
    }

    function _singleRatio(uint16 r) internal pure returns (uint16[] memory a) {
        a = new uint16[](1);
        a[0] = r;
    }

    /// @dev Length-1 uint256 array for the array-shaped Converted event expectations.
    function _singleAmount(uint256 amount) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = amount;
    }

    /// @dev NadFunPair getAmountOut/swap read FeeCollector config — stub the factory's feeCollector
    ///      (an EOA in this suite) with a zero-fee config for the given pair.
    function _stubPairFeeConfig(address pair, address baseToken, address pairQuote) internal {
        address feeCollector = makeAddr("feeCollector");
        bytes memory feeConfigReturn = abi.encode(baseToken, pairQuote, uint16(0), uint16(0), uint16(0));
        vm.mockCall(feeCollector, abi.encodeWithSignature("getFeeConfig(address)", pair), feeConfigReturn);
        vm.mockCall(feeCollector, abi.encodeWithSignature("isSettling(address)", pair), abi.encode(false));
    }

    function _hop(address adapter, address pair, address tokenOut)
        internal
        pure
        returns (IDividendVault.ConversionHop memory)
    {
        return IDividendVault.ConversionHop({adapter: IDexAdapter(adapter), pair: pair, tokenOut: tokenOut});
    }

    function _singleHop(address adapter, address pair, address tokenOut)
        internal
        pure
        returns (IDividendVault.ConversionHop[] memory path)
    {
        path = new IDividendVault.ConversionHop[](1);
        path[0] = _hop(adapter, pair, tokenOut);
    }

    /// @dev Wraps a single conversion into the length-1 order array the batched executeConversion takes.
    function _order(
        address src,
        address dt,
        IDividendVault.ConversionHop[] memory path,
        uint256 quoteIn,
        uint256 amountOutMin
    ) internal pure returns (IDividendVault.ConversionOrder[] memory orders) {
        orders = new IDividendVault.ConversionOrder[](1);
        orders[0] = IDividendVault.ConversionOrder({
            sourceToken: src, dividendToken: dt, path: path, quoteIn: quoteIn, amountOutMin: amountOutMin
        });
    }

    /// @dev Admin opens the setup() entrance for an external (non-registered) ERC20 dividend token.
    function _allowDividendToken(address token) internal {
        _grantSelector(address(this), DividendVault.setAllowedDividendToken.selector);
        vault.setAllowedDividendToken(token, true);
    }

    // ── initialize / interface ───────────────────────────────────────────

    function test_initialize_setsDependencies() public view {
        // The V2 registry keeps its explicit version suffix (TokenInfoLens precedent).
        assertEq(address(vault.tokenRegistryV2()), address(tokenRegistry));
        assertEq(vault.creatorFeeProcessor(), address(this));
        assertEq(vault.bondingCurve(), bondingCurve);
        // GiwaRouter is the current lifecycle conversion target (pre-graduation curve or canonical
        // V3), wired at init — NOT a setAdapters lane. Legacy V2 pools use NadSwapAdapter.
        assertEq(vault.router(), address(mockRouter));
        assertEq(address(vault.bondingCurveV1()), address(bondingCurveV1));
    }

    function test_initialize_revertsOnZeroRouter() public {
        address impl = address(new DividendVault());
        vm.expectRevert(IDividendVault.ZeroAddress.selector);
        new ERC1967Proxy(
            impl,
            abi.encodeCall(
                DividendVault.initialize,
                (
                    address(protocolManager),
                    address(tokenRegistry),
                    address(this),
                    bondingCurve,
                    address(0),
                    address(bondingCurveV1),
                    ""
                )
            )
        );
    }

    function test_initialize_revertsOnCodelessRouter() public {
        // router is the immutable dispatch sentinel — a codeless/wrong address would brick every
        // router-hop conversion. Fail fast at init (mirrors the bondingCurveV1 NotContract gate).
        address impl = address(new DividendVault());
        vm.expectRevert(IDividendVault.NotContract.selector);
        new ERC1967Proxy(
            impl,
            abi.encodeCall(
                DividendVault.initialize,
                (
                    address(protocolManager),
                    address(tokenRegistry),
                    address(this),
                    bondingCurve,
                    makeAddr("codelessRouter"),
                    address(bondingCurveV1),
                    ""
                )
            )
        );
    }

    function test_initialize_revertsOnZeroBondingCurveV1() public {
        address impl = address(new DividendVault());
        vm.expectRevert(IDividendVault.ZeroAddress.selector);
        new ERC1967Proxy(
            impl,
            abi.encodeCall(
                DividendVault.initialize,
                (
                    address(protocolManager),
                    address(tokenRegistry),
                    address(this),
                    bondingCurve,
                    address(mockRouter),
                    address(0),
                    ""
                )
            )
        );
    }

    function test_initialize_revertsOnCodelessBondingCurveV1() public {
        // A wrong (codeless) V1 curve address would silently disable the admission gate:
        // every V1 token would read createdAt == 0 and pass as an external ERC20.
        address impl = address(new DividendVault());
        vm.expectRevert(IDividendVault.NotContract.selector);
        new ERC1967Proxy(
            impl,
            abi.encodeCall(
                DividendVault.initialize,
                (
                    address(protocolManager),
                    address(tokenRegistry),
                    address(this),
                    bondingCurve,
                    address(mockRouter),
                    makeAddr("codelessCurve"),
                    ""
                )
            )
        );
    }

    function test_supportsInterface_IVault() public view {
        assertTrue(vault.supportsInterface(type(IVault).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    // ── setup: shape validation (unchanged) ──────────────────────────────

    function test_setup_storesConfig() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(quoteToken);
        tokens[1] = address(memeA);
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 6000;
        ratios[1] = 4000;

        _setup(tokens, ratios, 1_000 ether);

        // configured-ness == dividendTokens.length != 0 (setup enforces 1~10) — no separate active flag
        IDividendVault.DividendConfig memory config = vault.getConfig(sourceToken);
        assertEq(config.dividendTokens.length, 2);
        assertEq(config.dividendTokens[0], address(quoteToken));
        assertEq(config.dividendTokens[1], address(memeA));
        assertEq(config.ratios[0], 6000);
        assertEq(config.ratios[1], 4000);
        assertEq(config.minBalance, 1_000 ether);
    }

    function test_setup_revertsOnNonBondingCurve() public {
        vm.expectRevert(IDividendVault.NotAuthorized.selector);
        vault.setup(sourceToken, abi.encode(_single(address(quoteToken)), _singleRatio(10000), 0));
    }

    function test_setup_revertsOnRatioSumNot10000() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(quoteToken);
        tokens[1] = address(memeA);
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 6000;
        ratios[1] = 3000; // sum 9000
        vm.prank(bondingCurve);
        vm.expectRevert(IDividendVault.InvalidRatioTotal.selector);
        vault.setup(sourceToken, abi.encode(tokens, ratios, 0));
    }

    function test_setup_revertsOnDuplicateDividendToken() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(memeA);
        tokens[1] = address(memeA);
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        vm.prank(bondingCurve);
        vm.expectRevert(IDividendVault.DuplicateDividendToken.selector);
        vault.setup(sourceToken, abi.encode(tokens, ratios, 0));
    }

    function test_setup_revertsOnSecondSetup() public {
        _setup(_single(address(quoteToken)), _singleRatio(10000), 0);
        vm.prank(bondingCurve);
        vm.expectRevert(IDividendVault.AlreadyConfigured.selector);
        vault.setup(sourceToken, abi.encode(_single(address(quoteToken)), _singleRatio(10000), 0));
    }

    function test_setup_revertsOnTooManyTokens() public {
        address[] memory tokens = new address[](11);
        uint16[] memory ratios = new uint16[](11);
        for (uint256 i; i < 11; ++i) {
            tokens[i] = address(uint160(i + 1));
            ratios[i] = 909;
        }
        vm.prank(bondingCurve);
        vm.expectRevert(IDividendVault.InvalidTokenCount.selector);
        vault.setup(sourceToken, abi.encode(tokens, ratios, 0));
    }

    // ── setup: token rule (simplified — quote-match checks are GONE) ─────
    // dt == quoteToken || tokenRegistryV2.isRegistered(dt) || allowedDividendToken[dt]

    function test_setup_revertsOnUnsupportedDividendToken() public {
        address random = makeAddr("randomToken"); // not quoteToken, not registered, not allowlisted
        vm.prank(bondingCurve);
        vm.expectRevert(IDividendVault.UnsupportedDividendToken.selector);
        vault.setup(sourceToken, abi.encode(_single(random), _singleRatio(10000), 0));
    }

    function test_setup_acceptsRegisteredTokenWithDifferentQuote() public {
        // Bot-conversion model: setup no longer requires the dividend token's quote to match the
        // source's quote — a registered token quoted in a DIFFERENT asset is accepted, and the
        // operator bot bridges quotes with a multi-hop conversion path.
        MockERC20 otherQuote = new MockERC20("OTHERQ", "OTHERQ", 18);
        MockERC20 foreignMeme = new MockERC20("FOREIGN", "FOREIGN", 18);
        address foreignPair = factory.createPair(address(otherQuote), address(foreignMeme));
        vm.prank(bondingCurve);
        tokenRegistry.register(address(foreignMeme), foreignPair, address(otherQuote), ITokenRegistry.DexType.UniswapV2);

        vm.prank(bondingCurve);
        vault.setup(sourceToken, abi.encode(_single(address(foreignMeme)), _singleRatio(10000), uint256(0)));

        IDividendVault.DividendConfig memory config = vault.getConfig(sourceToken);
        assertEq(config.dividendTokens[0], address(foreignMeme), "registered token accepted without quote match");
    }

    function test_setup_acceptsAllowlistedExternalErc20() public {
        MockERC20 usdt = new MockERC20("USDT", "USDT", 18); // not registered in the V2 registry
        _allowDividendToken(address(usdt));

        vm.prank(bondingCurve);
        vault.setup(sourceToken, abi.encode(_single(address(usdt)), _singleRatio(10000), uint256(0)));

        IDividendVault.DividendConfig memory config = vault.getConfig(sourceToken);
        assertEq(config.dividendTokens[0], address(usdt));
    }

    function test_setup_acceptsIsAllowedQuoteToken() public {
        // New admission path: a token that is a configured quote token in ProtocolManager
        // (isAllowed == true) but is NOT in the V2 registry and NOT manually allowlisted must be
        // accepted as a dividend token. This lets quote tokens (WMON/LVMON) be picked as dividend
        // tokens for any source without a manual allowlist entry.
        MockERC20 quoteLike = new MockERC20("LVMON", "LVMON", 18); // not registered, not allowlisted
        assertFalse(tokenRegistry.isRegistered(address(quoteLike)), "precondition: not registered");
        assertFalse(vault.allowedDividendToken(address(quoteLike)), "precondition: not allowlisted");
        // flip isAllowed on the real ProtocolManager (the vault's authority) for this token
        vm.mockCall(
            address(protocolManager),
            abi.encodeWithSignature("isAllowed(address)", address(quoteLike)),
            abi.encode(true)
        );

        vm.prank(bondingCurve);
        vault.setup(sourceToken, abi.encode(_single(address(quoteLike)), _singleRatio(10000), uint256(0)));

        IDividendVault.DividendConfig memory config = vault.getConfig(sourceToken);
        assertEq(config.dividendTokens[0], address(quoteLike), "isAllowed quote token accepted as dividend token");
    }

    function test_setup_acceptsGraduatedV1Token() public {
        // New admission path: a graduated V1 bonding-curve token (createdAt != 0 && isGraduated) is
        // accepted as a dividend token directly in setup() — no manual allowlist entry needed —
        // mirroring the graduation gate in setAllowedDividendToken. Graduated V1 tokens have a real
        // DEX pool, so the conversion bot can route into them.
        MockERC20 v1Meme = new MockERC20("V1MEME", "V1MEME", 18); // not registered, not allowlisted, not quote
        bondingCurveV1.createToken(address(v1Meme));
        bondingCurveV1.graduate(address(v1Meme)); // createdAt stays set; isGraduated == true
        assertFalse(tokenRegistry.isRegistered(address(v1Meme)), "precondition: not V2-registered");
        assertFalse(vault.allowedDividendToken(address(v1Meme)), "precondition: not allowlisted");

        vm.prank(bondingCurve);
        vault.setup(sourceToken, abi.encode(_single(address(v1Meme)), _singleRatio(10000), uint256(0)));

        IDividendVault.DividendConfig memory config = vault.getConfig(sourceToken);
        assertEq(config.dividendTokens[0], address(v1Meme), "graduated V1 token accepted in setup");
    }

    function test_setup_revertsUngraduatedV1Token() public {
        // A V1 token still on its bonding curve (createdAt != 0, NOT graduated) has no DEX pool to
        // convert into — setup() must reject it (not quote / registered / allowlisted / isAllowed,
        // and the V1 path requires graduation).
        MockERC20 v1Meme = new MockERC20("V1MEME", "V1MEME", 18);
        bondingCurveV1.createToken(address(v1Meme)); // on V1 curve, NOT graduated

        vm.prank(bondingCurve);
        vm.expectRevert(IDividendVault.UnsupportedDividendToken.selector);
        vault.setup(sourceToken, abi.encode(_single(address(v1Meme)), _singleRatio(10000), uint256(0)));
    }

    function test_setup_revertsWhenAllowlistRevoked() public {
        MockERC20 usdt = new MockERC20("USDT", "USDT", 18);
        _allowDividendToken(address(usdt));
        vault.setAllowedDividendToken(address(usdt), false);

        vm.prank(bondingCurve);
        vm.expectRevert(IDividendVault.UnsupportedDividendToken.selector);
        vault.setup(sourceToken, abi.encode(_single(address(usdt)), _singleRatio(10000), uint256(0)));
    }

    // ── setAllowedDividendToken (admin) ──────────────────────────────────

    function test_setAllowedDividendToken_storesFlag() public {
        // Admission requires a deployed contract (NotContract gate) — a bare makeAddr won't do.
        address externalToken = address(new MockERC20("XAUT", "XAUT", 18));
        _grantSelector(address(this), DividendVault.setAllowedDividendToken.selector);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IDividendVault.SetAllowedDividendToken(externalToken, true);
        vault.setAllowedDividendToken(externalToken, true);
        assertTrue(vault.allowedDividendToken(externalToken));

        vault.setAllowedDividendToken(externalToken, false);
        assertFalse(vault.allowedDividendToken(externalToken));
    }

    function test_setAllowedDividendToken_revertsOnUnauthorized() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(); // AccessManagedUnauthorized
        vault.setAllowedDividendToken(makeAddr("externalToken"), true);
    }

    // ── setAllowedDividendToken: V1 admission gate ───────────────────────
    // Pre-graduation V1 tokens have no conversion lane (no CL pool yet, and GiwaRouter serves the
    // current registry), so admitting one would strand its pendingSwap quote until graduation — which may
    // never come. The gate blocks admission until the V1 curve reports graduation.

    function test_setAllowedDividendToken_revertsOnPreGraduationV1Token() public {
        MockERC20 v1Meme = new MockERC20("V1MEME", "V1MEME", 18);
        bondingCurveV1.createToken(address(v1Meme)); // on the V1 curve, not graduated
        _grantSelector(address(this), DividendVault.setAllowedDividendToken.selector);

        vm.expectRevert(IDividendVault.V1TokenNotGraduated.selector);
        vault.setAllowedDividendToken(address(v1Meme), true);
    }

    function test_setAllowedDividendToken_acceptsGraduatedV1Token() public {
        MockERC20 v1Meme = new MockERC20("V1MEME", "V1MEME", 18);
        bondingCurveV1.createToken(address(v1Meme));
        bondingCurveV1.graduate(address(v1Meme)); // createdAt stays set — V1 never clears it
        _grantSelector(address(this), DividendVault.setAllowedDividendToken.selector);

        vault.setAllowedDividendToken(address(v1Meme), true);
        assertTrue(vault.allowedDividendToken(address(v1Meme)));
    }

    function test_setAllowedDividendToken_revertsOnCodelessToken() public {
        // V1 tokens are deterministic CREATE2 clones: a predicted address could be allowlisted
        // BEFORE creation (createdAt == 0 reads as external ERC20), bypassing the graduation
        // gate. V1 deploys code and records createdAt atomically in create(), so requiring code
        // closes that hole — and catches plain admin typos.
        _grantSelector(address(this), DividendVault.setAllowedDividendToken.selector);

        vm.expectRevert(IDividendVault.NotContract.selector);
        vault.setAllowedDividendToken(makeAddr("predictedV1Token"), true);
    }

    function test_setAllowedDividendToken_removeSkipsAdmissionChecks() public {
        // The gate guards admission only — removal must always work, whatever the token's state.
        MockERC20 v1Meme = new MockERC20("V1MEME", "V1MEME", 18);
        bondingCurveV1.createToken(address(v1Meme)); // pre-graduation V1 token
        _grantSelector(address(this), DividendVault.setAllowedDividendToken.selector);

        vault.setAllowedDividendToken(address(v1Meme), false);
        assertFalse(vault.allowedDividendToken(address(v1Meme)));

        vault.setAllowedDividendToken(makeAddr("codeless"), false);
        assertFalse(vault.allowedDividendToken(makeAddr("codeless")));
    }

    // ── afterDeposit: record only (no conversion, no self-call) ──────────

    function test_afterDeposit_quoteTokenSlice_accumulates() public {
        // config: 100% quoteToken → immediate credit at record time
        _setup(_single(address(quoteToken)), _singleRatio(10000), 0);

        uint256 amount = 5 ether;
        quoteToken.mint(address(vault), amount);
        // caller == creatorFeeProcessor == address(this)
        vault.afterDeposit(sourceToken, address(quoteToken), amount);

        assertEq(vault.dividendBalance(sourceToken, address(quoteToken)), amount);
        // 100% quoteToken config — no swap slots, nothing can be pending.
    }

    function test_afterDeposit_revertsOnNonProcessor() public {
        _setup(_single(address(quoteToken)), _singleRatio(10000), 0);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IDividendVault.NotAuthorized.selector);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);
    }

    function test_afterDeposit_zeroAmount_noop() public {
        _setup(_single(address(quoteToken)), _singleRatio(10000), 0);
        vault.afterDeposit(sourceToken, address(quoteToken), 0);
        assertEq(vault.dividendBalance(sourceToken, address(quoteToken)), 0);
    }

    function test_afterDeposit_unconfiguredSource_noop() public {
        address unconfigured = makeAddr("unconfiguredSource");
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(unconfigured, address(quoteToken), 1 ether);
        assertEq(vault.dividendBalance(unconfigured, address(quoteToken)), 0, "nothing recorded without a config");
    }

    function test_afterDeposit_recordsSplit_noConversion() public {
        // 60% quote (immediate credit) + 40% memeA (pendingSwap). Recording ONLY: no conversion is
        // attempted inside afterDeposit — the vault must still hold the FULL deposit in quote and
        // must not have bought anything. No isGraduated / feeCollector stubs are wired on purpose:
        // any external call attempt would revert this test.
        address[] memory tokens = new address[](2);
        tokens[0] = address(quoteToken);
        tokens[1] = address(memeA);
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 6000;
        ratios[1] = 4000;
        _setup(tokens, ratios, 0);

        uint256 amount = 10 ether;
        quoteToken.mint(address(vault), amount);
        // ONE array-shaped Deposit per afterDeposit (emitted once, outside the loop) covering the
        // FULL split in config order: quote slice (credited, pending=false) + meme slice
        // (pending=true). Recording only — never Converted.
        address[] memory evTokens = new address[](2);
        evTokens[0] = address(quoteToken);
        evTokens[1] = address(memeA);
        uint256[] memory evSlices = new uint256[](2);
        evSlices[0] = 6 ether;
        evSlices[1] = 4 ether;
        bool[] memory evPending = new bool[](2);
        evPending[0] = false; // quote slot credited at record time
        evPending[1] = true; // meme slice awaits bot conversion
        vm.expectEmit(true, false, false, true, address(vault));
        emit IDividendVault.Deposit(sourceToken, evTokens, evSlices, evPending);
        vault.afterDeposit(sourceToken, address(quoteToken), amount);

        assertEq(vault.dividendBalance(sourceToken, address(quoteToken)), 6 ether, "quote slot credited at record time");
        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 4 ether, "meme slice recorded as pending");
        assertEq(vault.dividendBalance(sourceToken, address(memeA)), 0, "no conversion inside afterDeposit");
        assertEq(memeA.balanceOf(address(vault)), 0, "nothing bought");
        assertEq(quoteToken.balanceOf(address(vault)), amount, "vault still holds the full quote deposit");
    }

    function test_afterDeposit_multipleDeposits_accumulate() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(quoteToken);
        tokens[1] = address(memeA);
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        _setup(tokens, ratios, 0);

        quoteToken.mint(address(vault), 10 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 10 ether);
        quoteToken.mint(address(vault), 4 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 4 ether);

        assertEq(vault.dividendBalance(sourceToken, address(quoteToken)), 7 ether, "quote slot accumulates");
        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 7 ether, "pending accumulates across deposits");
        assertEq(quoteToken.balanceOf(address(vault)), 14 ether, "nothing leaves the vault at record time");
    }

    function test_afterDeposit_lastSliceAbsorbsRoundingRemainder() public {
        MockERC20 memeB = new MockERC20("MEMEB", "MEMEB", 18);
        vm.prank(bondingCurve);
        tokenRegistry.register(address(memeB), pairA, address(quoteToken), ITokenRegistry.DexType.UniswapV2);

        address[] memory tokens = new address[](3);
        tokens[0] = address(quoteToken);
        tokens[1] = address(memeA);
        tokens[2] = address(memeB);
        uint16[] memory ratios = new uint16[](3);
        ratios[0] = 3333;
        ratios[1] = 3333;
        ratios[2] = 3334;
        _setup(tokens, ratios, 0);

        uint256 amount = 1 ether + 1; // forces flooring on the BPS slices
        quoteToken.mint(address(vault), amount);
        vault.afterDeposit(sourceToken, address(quoteToken), amount);

        uint256 quoteSlice = (amount * 3333) / 10000;
        uint256 memeASlice = (amount * 3333) / 10000;
        assertEq(vault.dividendBalance(sourceToken, address(quoteToken)), quoteSlice);
        assertEq(vault.pendingSwap(sourceToken, address(memeA)), memeASlice);
        assertEq(
            vault.pendingSwap(sourceToken, address(memeB)),
            amount - quoteSlice - memeASlice,
            "last slice absorbs the rounding remainder, full amount conserved"
        );
    }

    // ── admin setters: setMerkleRoot / setWmon / setAdapters ─────────────

    function test_setMerkleRoot_storesRoot() public {
        _grantSelector(operator, DividendVault.setMerkleRoot.selector);
        bytes32 root = keccak256("root-1");
        vm.prank(operator);
        vault.setMerkleRoot(root);
        assertEq(vault.merkleRoot(), root);
    }

    function test_setMerkleRoot_revertsOnZero() public {
        _grantSelector(operator, DividendVault.setMerkleRoot.selector);
        vm.prank(operator);
        vm.expectRevert(IDividendVault.InvalidMerkleRoot.selector);
        vault.setMerkleRoot(bytes32(0));
    }

    function test_setMerkleRoot_revertsOnUnauthorized() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(); // AccessManagedUnauthorized
        vault.setMerkleRoot(keccak256("x"));
    }

    function test_setWmon_storesWmon() public {
        address wmonAddr = makeAddr("wMon");
        _grantSelector(address(this), DividendVault.setWmon.selector);
        vault.setWmon(wmonAddr);
        assertEq(vault.wmon(), wmonAddr);
    }

    function test_setAdapters_storesAndAllowsZero() public {
        // Three adapter lanes: nadSwap (general NadFunPair) + the two external uni lanes. The router
        // hop is NOT a setAdapters lane — it's the init-time `router`.
        vm.expectEmit(false, false, false, true, address(vault));
        emit IDividendVault.SetAdapters(
            makeAddr("nadSwapAdapter"), makeAddr("uniswapV2Adapter"), makeAddr("uniswapV3Adapter")
        );
        vault.setAdapters(makeAddr("nadSwapAdapter"), makeAddr("uniswapV2Adapter"), makeAddr("uniswapV3Adapter"));
        assertEq(address(vault.nadSwapAdapter()), makeAddr("nadSwapAdapter"));
        assertEq(address(vault.uniswapV2Adapter()), makeAddr("uniswapV2Adapter"));
        assertEq(address(vault.uniswapV3Adapter()), makeAddr("uniswapV3Adapter"));
        // each lane allows 0 = that lane disabled (a hop through a disabled lane reverts UnknownAdapter)
        vault.setAdapters(address(0), address(0), address(0));
        assertEq(address(vault.nadSwapAdapter()), address(0));
        assertEq(address(vault.uniswapV2Adapter()), address(0));
        assertEq(address(vault.uniswapV3Adapter()), address(0));
    }

    function test_setters_revertOnUnauthorized() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(); // AccessManagedUnauthorized
        vault.setAdapters(makeAddr("nadSwapAdapter"), makeAddr("uniswapV2Adapter"), makeAddr("uniswapV3Adapter"));
        vm.prank(rando);
        vm.expectRevert(); // AccessManagedUnauthorized
        vault.setWmon(makeAddr("wMon"));
    }

    // ── executeConversion (operator bot, hop path) ───────────────────────
    // 플랜: docs/plans/2026-06-12-dividend-bot-conversion-design.md §3 +
    //       2026-06-13-dividend-router-lane-design.md. GiwaRouter hops buy current launch tokens
    //       (pre-graduation curve or canonical V3); NadSwapAdapter hops handle legacy V2 pools;
    //       the uniswapV2Adapter / uniswapV3Adapter lanes handle external pools.

    function test_executeConversion_singleHop_convertsPendingToDividend() public {
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);
        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 1 ether, "recorded pending before conversion");

        uint256 expectedOut = 42 ether;
        mockRouter.setNextOut(expectedOut);
        IDividendVault.ConversionHop[] memory path = _singleHop(address(mockRouter), address(memeA), address(memeA));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IDividendVault.Converted(
            _single(sourceToken), _single(address(memeA)), _singleAmount(1 ether), _singleAmount(expectedOut)
        );
        vm.prank(operator);
        vault.executeConversion(_order(sourceToken, address(memeA), path, 1 ether, expectedOut));

        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 0, "pending fully consumed");
        assertEq(vault.dividendBalance(sourceToken, address(memeA)), expectedOut, "credited the real balance delta");
        assertEq(memeA.balanceOf(address(vault)), expectedOut, "vault holds the bought memeA");
        assertEq(quoteToken.balanceOf(address(vault)), 0, "no quote left behind");
    }

    function test_executeConversion_nadSwapLane_convertsViaPair() public {
        // The general-pool lane: swap quote → token through a real NadFunPair (pairA), not the
        // router. This is the path for vanilla pools (USDC/WMON) and cross-quote bridge legs that
        // the router cannot express (it only buys nad.fun tokens by address).
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);

        _stubPairFeeConfig(pairA, address(memeA), address(quoteToken));
        uint256 expectedOut = INadFunPair(pairA).getAmountOut(address(quoteToken), 1 ether);
        IDividendVault.ConversionHop[] memory path = _singleHop(address(nadSwapAdapter), pairA, address(memeA));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IDividendVault.Converted(
            _single(sourceToken), _single(address(memeA)), _singleAmount(1 ether), _singleAmount(expectedOut)
        );
        vm.prank(operator);
        vault.executeConversion(_order(sourceToken, address(memeA), path, 1 ether, expectedOut));

        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 0, "pending fully consumed through the pair");
        assertEq(vault.dividendBalance(sourceToken, address(memeA)), expectedOut, "credited the real AMM delta");
        assertEq(memeA.balanceOf(address(vault)), expectedOut, "vault holds the swapped memeA");
        assertEq(quoteToken.balanceOf(address(vault)), 0, "no quote left behind");
    }

    function test_executeConversion_routerLane_forwardsBuyParams() public {
        // The vault's parameter contract with the router: exact quoteIn, output direct to the
        // vault, amountOutMin 0 (slippage is the vault's order-level check), same-block deadline.
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 2 ether);

        uint256 outAmount = 50 ether;
        mockRouter.setNextOut(outAmount);
        IDividendVault.ConversionHop[] memory path = _singleHop(address(mockRouter), address(memeA), address(memeA));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.expectCall(
            address(mockRouter),
            abi.encodeCall(
                IGiwaRouter.buy,
                (IGiwaRouter.BuyParams({
                        amountIn: 2 ether,
                        amountOutMin: 0,
                        token: address(memeA),
                        to: address(vault),
                        deadline: block.timestamp
                    }))
            )
        );
        vm.prank(operator);
        vault.executeConversion(_order(sourceToken, address(memeA), path, 2 ether, outAmount));

        assertEq(vault.dividendBalance(sourceToken, address(memeA)), outAmount);
        assertEq(quoteToken.balanceOf(address(mockRouter)), 2 ether, "mock router sank the consumed quote");
    }

    function test_executeConversion_routerLane_partialConsume_keepsRefundPending() public {
        // Graduation-cap partial fill: router.buy consumes only 70% of the pulled quote and refunds
        // the 30% leftover to the vault (msg.sender) within the same call, so the first-hop delta
        // accounting deducts only the consumed quote from pendingSwap.
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 10 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 10 ether);

        uint256 outAmount = 33 ether;
        mockRouter.setConsumeBps(7000);
        mockRouter.setNextOut(outAmount);
        IDividendVault.ConversionHop[] memory path = _singleHop(address(mockRouter), address(memeA), address(memeA));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        uint256 consumed = (10 ether * 7000) / 10000; // 7e18
        uint256 refunded = 10 ether - consumed; // 3e18

        vm.expectEmit(false, false, false, true, address(vault));
        emit IDividendVault.Converted(
            _single(sourceToken), _single(address(memeA)), _singleAmount(consumed), _singleAmount(outAmount)
        );
        vm.prank(operator);
        vault.executeConversion(_order(sourceToken, address(memeA), path, 10 ether, outAmount));

        assertEq(vault.dividendBalance(sourceToken, address(memeA)), outAmount);
        assertEq(vault.pendingSwap(sourceToken, address(memeA)), refunded, "refund stays pending");
        assertEq(quoteToken.balanceOf(address(vault)), refunded, "vault balance == pendingSwap");
        assertEq(quoteToken.balanceOf(address(mockRouter)), consumed, "router only sank the consumed quote");
    }

    function test_executeConversion_multiHop_chainsBalanceDeltas() public {
        // quote → midToken (GiwaRouter lane) → destToken (UniswapV2 lane). destToken is an
        // allowlisted external ERC20; hop2's input is hop1's measured output delta, and no
        // intermediate midToken may remain in the vault after the path completes.
        MockERC20 midToken = new MockERC20("MID", "MID", 18);
        MockERC20 destToken = new MockERC20("DEST", "DEST", 18);

        // destPair trades midToken ↔ destToken on an external V2 pool.
        (address token0, address token1) = address(midToken) < address(destToken)
            ? (address(midToken), address(destToken))
            : (address(destToken), address(midToken));
        MockUniswapV2Pair pairDest = new MockUniswapV2Pair(token0, token1);
        midToken.mint(address(pairDest), 1000 ether);
        destToken.mint(address(pairDest), 1000 ether);
        pairDest.sync();
        UniswapV2ExternalAdapter externalAdapter = new UniswapV2ExternalAdapter();
        vault.setAdapters(address(nadSwapAdapter), address(externalAdapter), address(0));

        _allowDividendToken(address(destToken));
        _setup(_single(address(destToken)), _singleRatio(10000), 0);

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);

        uint256 midOut = 5 ether;
        mockRouter.setNextOut(midOut); // hop1: router lane buys midToken with the pending quote
        uint256 destOut = externalAdapter.getAmountOut(address(pairDest), address(midToken), midOut);
        IDividendVault.ConversionHop[] memory path = new IDividendVault.ConversionHop[](2);
        path[0] = _hop(address(mockRouter), address(midToken), address(midToken));
        path[1] = _hop(address(externalAdapter), address(pairDest), address(destToken));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IDividendVault.Converted(
            _single(sourceToken), _single(address(destToken)), _singleAmount(1 ether), _singleAmount(destOut)
        );
        vm.prank(operator);
        vault.executeConversion(_order(sourceToken, address(destToken), path, 1 ether, destOut));

        assertEq(vault.pendingSwap(sourceToken, address(destToken)), 0);
        assertEq(vault.dividendBalance(sourceToken, address(destToken)), destOut, "final hop delta credited");
        assertEq(destToken.balanceOf(address(vault)), destOut);
        assertEq(midToken.balanceOf(address(vault)), 0, "no intermediate midToken residue");
        assertEq(quoteToken.balanceOf(address(vault)), 0);
    }

    // Fee-on-transfer dividend token → credit the REAL balance delta, not the adapter's pre-fee
    // output (otherwise dividendBalance overstates and claims underfund).
    function test_executeConversion_feeOnTransfer_creditsRealDelta() public {
        MockFeeOnTransferERC20 feeUsd = new MockFeeOnTransferERC20();
        (address token0, address token1) = address(quoteToken) < address(feeUsd)
            ? (address(quoteToken), address(feeUsd))
            : (address(feeUsd), address(quoteToken));
        MockUniswapV2Pair externalPair = new MockUniswapV2Pair(token0, token1);
        quoteToken.mint(address(externalPair), 1000 ether);
        feeUsd.mint(address(externalPair), 1000 ether);
        externalPair.sync();
        UniswapV2ExternalAdapter externalAdapter = new UniswapV2ExternalAdapter();
        vault.setAdapters(address(nadSwapAdapter), address(externalAdapter), address(0));

        _allowDividendToken(address(feeUsd));
        _setup(_single(address(feeUsd)), _singleRatio(10000), 0);

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);

        uint256 preFeeOut = externalAdapter.getAmountOut(address(externalPair), address(quoteToken), 1 ether);
        IDividendVault.ConversionHop[] memory path =
            _singleHop(address(externalAdapter), address(externalPair), address(feeUsd));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.prank(operator);
        vault.executeConversion(_order(sourceToken, address(feeUsd), path, 1 ether, 1));

        uint256 credited = vault.dividendBalance(sourceToken, address(feeUsd));
        assertEq(credited, feeUsd.balanceOf(address(vault)), "credited == actually held");
        assertLt(credited, preFeeOut, "credited is post-fee, less than adapter pre-fee output");
        assertEq(vault.pendingSwap(sourceToken, address(feeUsd)), 0);
    }

    function test_executeConversion_firstHopPartialFill_keepsUnconsumedPending() public {
        // First-hop partial fill is ALLOWED (existing pendingSwap model): the V3 adapter refunds
        // the unconsumed quote to the vault and only the actually-consumed quote leaves pending.
        MockERC20 externalGold = new MockERC20("XAUT", "XAUT", 18);
        MockCapricornPool capricornPool = new MockCapricornPool(address(quoteToken), address(externalGold));
        externalGold.mint(address(capricornPool), 1_000 ether);
        capricornPool.setFillBps(5000); // pool consumes only half the pushed quote (rate 1:1)

        UniswapV3ExternalAdapter externalV3Adapter = new UniswapV3ExternalAdapter();
        vault.setAdapters(address(nadSwapAdapter), address(0), address(externalV3Adapter));

        _allowDividendToken(address(externalGold));
        _setup(_single(address(externalGold)), _singleRatio(10000), 0);

        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 2 ether);

        IDividendVault.ConversionHop[] memory path =
            _singleHop(address(externalV3Adapter), address(capricornPool), address(externalGold));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IDividendVault.Converted(
            _single(sourceToken), _single(address(externalGold)), _singleAmount(1 ether), _singleAmount(1 ether)
        );
        vm.prank(operator);
        vault.executeConversion(_order(sourceToken, address(externalGold), path, 2 ether, 1 ether));

        assertEq(vault.dividendBalance(sourceToken, address(externalGold)), 1 ether, "credited for the consumed half");
        assertEq(vault.pendingSwap(sourceToken, address(externalGold)), 1 ether, "unconsumed refund stays pending");
        assertEq(quoteToken.balanceOf(address(vault)), 1 ether, "refunded quote held by the vault");
        assertEq(externalGold.balanceOf(address(vault)), 1 ether);
    }

    function test_executeConversion_intermediateHopPartialFill_revertsPathResidue() public {
        // quote → midToken (GiwaRouter lane, full fill) → destToken (Capricorn mock, 50% fill).
        // The partially-filled hop2 refunds leftover midToken to the vault — an intermediate
        // currency OUTSIDE the pendingSwap accounting — so the whole frame must revert PathResidue
        // and leave the pending slice fully intact for a complete retry.
        MockERC20 midToken = new MockERC20("MID", "MID", 18);
        MockERC20 destToken = new MockERC20("DEST", "DEST", 18);

        MockCapricornPool capricornPool = new MockCapricornPool(address(midToken), address(destToken));
        destToken.mint(address(capricornPool), 1_000 ether);
        capricornPool.setFillBps(5000); // hop2 consumes only half the pushed midToken

        UniswapV3ExternalAdapter externalV3Adapter = new UniswapV3ExternalAdapter();
        vault.setAdapters(address(nadSwapAdapter), address(0), address(externalV3Adapter));

        _allowDividendToken(address(destToken));
        _setup(_single(address(destToken)), _singleRatio(10000), 0);

        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);

        mockRouter.setNextOut(4 ether); // hop1: router lane buys midToken in full
        IDividendVault.ConversionHop[] memory path = new IDividendVault.ConversionHop[](2);
        path[0] = _hop(address(mockRouter), address(midToken), address(midToken));
        path[1] = _hop(address(externalV3Adapter), address(capricornPool), address(destToken));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.prank(operator);
        vm.expectRevert(IDividendVault.PathResidue.selector);
        vault.executeConversion(_order(sourceToken, address(destToken), path, 1 ether, 1));

        assertEq(vault.pendingSwap(sourceToken, address(destToken)), 1 ether, "pending fully intact for retry");
        assertEq(vault.dividendBalance(sourceToken, address(destToken)), 0);
        assertEq(quoteToken.balanceOf(address(vault)), 1 ether, "whole conversion rolled back");
        assertEq(midToken.balanceOf(address(vault)), 0, "no midToken residue after rollback");
    }

    function test_executeConversion_revertsOnInsufficientOutput() public {
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);

        uint256 expectedOut = 42 ether;
        mockRouter.setNextOut(expectedOut);
        IDividendVault.ConversionHop[] memory path = _singleHop(address(mockRouter), address(memeA), address(memeA));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.prank(operator);
        vm.expectRevert(IDividendVault.InsufficientOutput.selector);
        vault.executeConversion(_order(sourceToken, address(memeA), path, 1 ether, expectedOut + 1));

        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 1 ether, "pending intact after slippage revert");
        assertEq(vault.dividendBalance(sourceToken, address(memeA)), 0);
        assertEq(quoteToken.balanceOf(address(vault)), 1 ether, "quote rolled back to the vault");
    }

    function test_executeConversion_revertsOnExcessiveConversion() public {
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);

        IDividendVault.ConversionHop[] memory path = _singleHop(address(mockRouter), address(memeA), address(memeA));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        // quoteIn exceeds this (sourceToken, dividendToken) slot's pendingSwap by 1 wei
        vm.prank(operator);
        vm.expectRevert(IDividendVault.ExcessiveConversion.selector);
        vault.executeConversion(_order(sourceToken, address(memeA), path, 1 ether + 1, 1));
    }

    function test_executeConversion_revertsOnEmptyPath() public {
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);

        IDividendVault.ConversionHop[] memory emptyPath = new IDividendVault.ConversionHop[](0);
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.prank(operator);
        vm.expectRevert(IDividendVault.InvalidPath.selector);
        vault.executeConversion(_order(sourceToken, address(memeA), emptyPath, 1 ether, 1));
    }

    function test_executeConversion_revertsOnWrongPathEndpoint() public {
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);

        // last hop tokenOut != dividendToken → the path does not end where the accounting credits
        IDividendVault.ConversionHop[] memory path =
            _singleHop(address(mockRouter), address(quoteToken), address(quoteToken));
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.prank(operator);
        vm.expectRevert(IDividendVault.InvalidPath.selector);
        vault.executeConversion(_order(sourceToken, address(memeA), path, 1 ether, 1));
    }

    function test_executeConversion_revertsOnUnknownAdapter() public {
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);
        _grantSelector(operator, DividendVault.executeConversion.selector);

        // a real adapter instance that was never wired into a vault lane
        UniswapV2ExternalAdapter rogueAdapter = new UniswapV2ExternalAdapter();
        IDividendVault.ConversionHop[] memory roguePath = _singleHop(address(rogueAdapter), pairA, address(memeA));
        vm.prank(operator);
        vm.expectRevert(IDividendVault.UnknownAdapter.selector);
        vault.executeConversion(_order(sourceToken, address(memeA), roguePath, 1 ether, 1));

        // adapter == 0 must NOT match the disabled (zero) uniswapV2/uniswapV3 lanes
        IDividendVault.ConversionHop[] memory zeroAdapterPath = _singleHop(address(0), pairA, address(memeA));
        vm.prank(operator);
        vm.expectRevert(IDividendVault.UnknownAdapter.selector);
        vault.executeConversion(_order(sourceToken, address(memeA), zeroAdapterPath, 1 ether, 1));

        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 1 ether, "nothing spent through unknown adapters");
    }

    function test_executeConversion_revertsOnNonOperator() public {
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 1 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 1 ether);

        IDividendVault.ConversionHop[] memory path = _singleHop(address(mockRouter), address(memeA), address(memeA));

        vm.prank(makeAddr("rando"));
        vm.expectRevert(); // AccessManagedUnauthorized
        vault.executeConversion(_order(sourceToken, address(memeA), path, 1 ether, 1));
    }

    /// @dev Stack relief: builds the 2-order Converted expectation in its own frame.
    function _expectBatchConverted(address dividendToken0, uint256 received0, address dividendToken1, uint256 received1)
        internal
    {
        address[] memory sources = new address[](2);
        sources[0] = sourceToken;
        sources[1] = sourceToken;
        address[] memory dividendTokens = new address[](2);
        dividendTokens[0] = dividendToken0;
        dividendTokens[1] = dividendToken1;
        uint256[] memory consumedQuote = new uint256[](2);
        consumedQuote[0] = 1 ether;
        consumedQuote[1] = 1 ether;
        uint256[] memory receivedAmounts = new uint256[](2);
        receivedAmounts[0] = received0;
        receivedAmounts[1] = received1;
        vm.expectEmit(false, false, false, true, address(vault));
        emit IDividendVault.Converted(sources, dividendTokens, consumedQuote, receivedAmounts);
    }

    function test_executeConversion_batch_convertsMultipleOrders() public {
        // Two dividend tokens, two lanes: memeA through the GiwaRouter lane and an
        // allowlisted external ERC20 through the UniswapV2 lane. ONE executeConversion call with
        // two orders settles both pending slots in a single batch.
        MockERC20 usdt = new MockERC20("USDT", "USDT", 18);
        (address token0, address token1) = address(quoteToken) < address(usdt)
            ? (address(quoteToken), address(usdt))
            : (address(usdt), address(quoteToken));
        MockUniswapV2Pair externalPair = new MockUniswapV2Pair(token0, token1);
        quoteToken.mint(address(externalPair), 1000 ether);
        usdt.mint(address(externalPair), 1000 ether);
        externalPair.sync();
        UniswapV2ExternalAdapter externalAdapter = new UniswapV2ExternalAdapter();
        vault.setAdapters(address(nadSwapAdapter), address(externalAdapter), address(0));

        _allowDividendToken(address(usdt));
        address[] memory tokens = new address[](2);
        tokens[0] = address(memeA);
        tokens[1] = address(usdt);
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        _setup(tokens, ratios, 0);

        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 2 ether);
        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 1 ether, "memeA slice pending");
        assertEq(vault.pendingSwap(sourceToken, address(usdt)), 1 ether, "usdt slice pending");

        uint256 memeOut = 42 ether;
        mockRouter.setNextOut(memeOut);
        uint256 usdtOut = externalAdapter.getAmountOut(address(externalPair), address(quoteToken), 1 ether);

        IDividendVault.ConversionOrder[] memory orders = new IDividendVault.ConversionOrder[](2);
        orders[0] = IDividendVault.ConversionOrder({
            sourceToken: sourceToken,
            dividendToken: address(memeA),
            path: _singleHop(address(mockRouter), address(memeA), address(memeA)),
            quoteIn: 1 ether,
            amountOutMin: memeOut
        });
        orders[1] = IDividendVault.ConversionOrder({
            sourceToken: sourceToken,
            dividendToken: address(usdt),
            path: _singleHop(address(externalAdapter), address(externalPair), address(usdt)),
            quoteIn: 1 ether,
            amountOutMin: usdtOut
        });
        _grantSelector(operator, DividendVault.executeConversion.selector);

        // batch semantics: ONE Converted event per operator call — parallel arrays, one entry per order
        _expectBatchConverted(address(memeA), memeOut, address(usdt), usdtOut);
        vm.prank(operator);
        vault.executeConversion(orders);

        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 0, "memeA pending fully consumed");
        assertEq(vault.pendingSwap(sourceToken, address(usdt)), 0, "usdt pending fully consumed");
        assertEq(vault.dividendBalance(sourceToken, address(memeA)), memeOut, "memeA credited the real delta");
        assertEq(vault.dividendBalance(sourceToken, address(usdt)), usdtOut, "usdt credited the real delta");
        assertEq(memeA.balanceOf(address(vault)), memeOut, "vault holds the bought memeA");
        assertEq(usdt.balanceOf(address(vault)), usdtOut, "vault holds the bought usdt");
        assertEq(quoteToken.balanceOf(address(vault)), 0, "all pending quote spent");
    }

    function test_executeConversion_batch_revertsWholeBatchOnOneFailure() public {
        // Same two-order setup as the batch happy path, but the second order's amountOutMin is
        // impossible — the batch is ALL-OR-NOTHING: the first order's already-executed conversion
        // must roll back with it, leaving every pending slot intact for a full retry.
        MockERC20 usdt = new MockERC20("USDT", "USDT", 18);
        (address token0, address token1) = address(quoteToken) < address(usdt)
            ? (address(quoteToken), address(usdt))
            : (address(usdt), address(quoteToken));
        MockUniswapV2Pair externalPair = new MockUniswapV2Pair(token0, token1);
        quoteToken.mint(address(externalPair), 1000 ether);
        usdt.mint(address(externalPair), 1000 ether);
        externalPair.sync();
        UniswapV2ExternalAdapter externalAdapter = new UniswapV2ExternalAdapter();
        vault.setAdapters(address(nadSwapAdapter), address(externalAdapter), address(0));

        _allowDividendToken(address(usdt));
        address[] memory tokens = new address[](2);
        tokens[0] = address(memeA);
        tokens[1] = address(usdt);
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        _setup(tokens, ratios, 0);

        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 2 ether);

        uint256 memeOut = 42 ether;
        mockRouter.setNextOut(memeOut);
        uint256 usdtOut = externalAdapter.getAmountOut(address(externalPair), address(quoteToken), 1 ether);

        IDividendVault.ConversionOrder[] memory orders = new IDividendVault.ConversionOrder[](2);
        orders[0] = IDividendVault.ConversionOrder({
            sourceToken: sourceToken,
            dividendToken: address(memeA),
            path: _singleHop(address(mockRouter), address(memeA), address(memeA)),
            quoteIn: 1 ether,
            amountOutMin: memeOut
        });
        orders[1] = IDividendVault.ConversionOrder({
            sourceToken: sourceToken,
            dividendToken: address(usdt),
            path: _singleHop(address(externalAdapter), address(externalPair), address(usdt)),
            quoteIn: 1 ether,
            amountOutMin: usdtOut + 1 // impossible: 1 wei above the pool's actual output
        });
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.prank(operator);
        vm.expectRevert(IDividendVault.InsufficientOutput.selector);
        vault.executeConversion(orders);

        assertEq(vault.pendingSwap(sourceToken, address(memeA)), 1 ether, "memeA pending intact");
        assertEq(vault.pendingSwap(sourceToken, address(usdt)), 1 ether, "usdt pending intact");
        assertEq(vault.dividendBalance(sourceToken, address(memeA)), 0, "no memeA credit, first order rolled back");
        assertEq(vault.dividendBalance(sourceToken, address(usdt)), 0, "no usdt credit");
        assertEq(memeA.balanceOf(address(vault)), 0, "no memeA bought");
        assertEq(quoteToken.balanceOf(address(vault)), 2 ether, "whole batch rolled back");
    }

    function test_executeConversion_revertsOnEmptyOrders() public {
        IDividendVault.ConversionOrder[] memory orders = new IDividendVault.ConversionOrder[](0);
        _grantSelector(operator, DividendVault.executeConversion.selector);

        vm.prank(operator);
        vm.expectRevert(IDividendVault.InvalidPath.selector);
        vault.executeConversion(orders);
    }

    // ── claim (Merkle distribution — unchanged by the bot-conversion redesign) ──

    function _claimLeaf(address src, address holder, address divToken, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(src, holder, divToken, amount));
    }

    /// @dev Root of a 2-leaf tree (OZ MerkleProof sorted-pair hashing).
    function _pairRoot(bytes32 leaf, bytes32 sibling) internal pure returns (bytes32) {
        return leaf < sibling ? keccak256(abi.encodePacked(leaf, sibling)) : keccak256(abi.encodePacked(sibling, leaf));
    }

    /// @dev Single-element proof (the sibling) for a 2-leaf tree.
    function _proofOf(bytes32 sibling) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }

    function _setRoot(bytes32 root) internal {
        _grantSelector(operator, DividendVault.setMerkleRoot.selector);
        vm.prank(operator);
        vault.setMerkleRoot(root);
    }

    function _configureAndFund(address divToken, uint256 minBalance, uint256 vaultHolds) internal {
        _setup(_single(divToken), _singleRatio(10000), minBalance);
        MockERC20(divToken).mint(address(vault), vaultHolds);
    }

    function _mockHolderBalance(address holder, uint256 bal) internal {
        vm.mockCall(sourceToken, abi.encodeWithSelector(IERC20.balanceOf.selector, holder), abi.encode(bal));
    }

    function _claimOne(address holder, address src, address divToken, uint256 amount, bytes32[] memory proof) internal {
        address[] memory srcs = new address[](1);
        srcs[0] = src;
        address[] memory dts = new address[](1);
        dts[0] = divToken;
        uint256[] memory amts = new uint256[](1);
        amts[0] = amount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = proof;
        vm.prank(holder);
        vault.claim(srcs, dts, amts, proofs);
    }

    function test_claim_erc20_transfersToSender() public {
        address holder = makeAddr("holder");
        _configureAndFund(address(memeA), 100 ether, 50 ether);
        _mockHolderBalance(holder, 100 ether);
        bytes32 leaf = _claimLeaf(sourceToken, holder, address(memeA), 10 ether);
        _setRoot(leaf);
        // claim() emits ONE Claim event per call: parallel arrays, amounts[i] = actually paid amount
        vm.expectEmit(true, false, false, true, address(vault));
        emit IDividendVault.Claim(holder, _single(sourceToken), _single(address(memeA)), _singleAmount(10 ether));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 10 ether);
    }

    function test_claim_revertsOnInvalidProof() public {
        address holder = makeAddr("holder");
        _configureAndFund(address(memeA), 0, 50 ether);
        _mockHolderBalance(holder, 1 ether);
        _setRoot(keccak256("some-other-root"));
        vm.expectRevert(IDividendVault.InvalidMerkleProof.selector);
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
    }

    function test_claim_revertsOnArrayLengthMismatch() public {
        address holder = makeAddr("holder");
        _setRoot(keccak256("r"));
        address[] memory srcs = new address[](1);
        srcs[0] = sourceToken;
        address[] memory dts = new address[](2);
        uint256[] memory amts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        vm.prank(holder);
        vm.expectRevert(IDividendVault.InvalidArrayLength.selector);
        vault.claim(srcs, dts, amts, proofs);
    }

    function test_claim_revertsBelowMinBalance() public {
        address holder = makeAddr("holder");
        _configureAndFund(address(memeA), 100 ether, 50 ether);
        _mockHolderBalance(holder, 99 ether); // < minBalance
        bytes32 leaf = _claimLeaf(sourceToken, holder, address(memeA), 10 ether);
        _setRoot(leaf);
        // Option A: ineligibility now reverts (was skip-as-zero) so the failure reason surfaces.
        // BelowMinBalance() added to IDividendVault by the implementation.
        vm.expectRevert(bytes4(keccak256("BelowMinBalance()")));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 0);
    }

    function test_claim_skipsAlreadyClaimed() public {
        address holder = makeAddr("holder");
        _configureAndFund(address(memeA), 0, 50 ether);
        _mockHolderBalance(holder, 1 ether);
        bytes32 leaf = _claimLeaf(sourceToken, holder, address(memeA), 10 ether);
        _setRoot(leaf);
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 10 ether);
        // already-claimed skip is reported as a zero entry in the second call's Claim event
        vm.expectEmit(true, false, false, true, address(vault));
        emit IDividendVault.Claim(holder, _single(sourceToken), _single(address(memeA)), _singleAmount(0));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 10 ether); // skipped second time
    }

    function test_claim_wmon_unwrapsToNative() public {
        address holder = makeAddr("holderW");
        MockWMON wmonTok = new MockWMON();
        vm.prank(bondingCurve);
        tokenRegistry.register(address(wmonTok), pairA, address(quoteToken), ITokenRegistry.DexType.UniswapV2);
        _setup(_single(address(wmonTok)), _singleRatio(10000), 0);

        vm.deal(address(this), 20 ether);
        wmonTok.deposit{value: 20 ether}();
        wmonTok.transfer(address(vault), 20 ether);
        _grantSelector(address(this), DividendVault.setWmon.selector);
        vault.setWmon(address(wmonTok));

        _mockHolderBalance(holder, 1 ether);
        bytes32 leaf = _claimLeaf(sourceToken, holder, address(wmonTok), 5 ether);
        _setRoot(leaf);

        uint256 nativeBefore = holder.balance;
        _claimOne(holder, sourceToken, address(wmonTok), 5 ether, new bytes32[](0));

        assertEq(holder.balance - nativeBefore, 5 ether, "holder received native MON");
        assertEq(wmonTok.balanceOf(holder), 0, "no WMON to holder");
    }

    function test_claim_revertsInsufficientVaultBalance() public {
        address holder = makeAddr("holderUF");
        _configureAndFund(address(memeA), 0, 3 ether); // vault holds only 3
        _mockHolderBalance(holder, 1 ether);
        bytes32 leaf = _claimLeaf(sourceToken, holder, address(memeA), 10 ether); // claim 10 > 3
        _setRoot(leaf);
        // Option A: under-funded now reverts (was skip-as-zero). cumulative untouched, so the same
        // claim succeeds once funded. InsufficientVaultBalance() added to IDividendVault by the impl.
        vm.expectRevert(bytes4(keccak256("InsufficientVaultBalance()")));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 0, "under-funded reverts, nothing paid");
        // not marked claimed → fund the vault and the same claim now succeeds
        memeA.mint(address(vault), 10 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IDividendVault.Claim(holder, _single(sourceToken), _single(address(memeA)), _singleAmount(10 ether));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 10 ether, "claimable after funding");
    }

    function test_claim_skipsZeroAmount() public {
        address holder = makeAddr("holderZ");
        _configureAndFund(address(memeA), 0, 50 ether);
        _mockHolderBalance(holder, 1 ether);
        bytes32 leaf = _claimLeaf(sourceToken, holder, address(memeA), 0);
        _setRoot(leaf);
        // zero-amount skip still appears in the single Claim event as a zero entry
        vm.expectEmit(true, false, false, true, address(vault));
        emit IDividendVault.Claim(holder, _single(sourceToken), _single(address(memeA)), _singleAmount(0));
        _claimOne(holder, sourceToken, address(memeA), 0, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 0);
        // zero-amount must not advance the cumulative high-water mark (slot stays reusable)
        assertEq(vault.claimedCumulative(sourceToken, holder, address(memeA)), 0, "zero-amount advanced cumulative");
    }

    function test_claim_cumulative_getterTracksHighWaterMark() public {
        address holder = makeAddr("holderHWM");
        _configureAndFund(address(memeA), 0, 100 ether);
        _mockHolderBalance(holder, 1 ether);

        assertEq(vault.claimedCumulative(sourceToken, holder, address(memeA)), 0, "starts at zero");

        _setRoot(_claimLeaf(sourceToken, holder, address(memeA), 10 ether));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
        assertEq(vault.claimedCumulative(sourceToken, holder, address(memeA)), 10 ether, "tracks first claim");

        _setRoot(_claimLeaf(sourceToken, holder, address(memeA), 25 ether));
        _claimOne(holder, sourceToken, address(memeA), 25 ether, new bytes32[](0));
        assertEq(
            vault.claimedCumulative(sourceToken, holder, address(memeA)), 25 ether, "high-water mark == latest accrued"
        );
    }

    function test_claim_revertsUnconfiguredSource() public {
        address holder = makeAddr("holderUnconfigured");
        address unconfigured = makeAddr("unconfiguredSource");
        memeA.mint(address(vault), 50 ether);
        _mockHolderBalance(holder, 1 ether);
        // build a root for an unconfigured source token
        bytes32 leaf = _claimLeaf(unconfigured, holder, address(memeA), 10 ether);
        _setRoot(leaf);
        // balanceOf on the unconfigured (EOA) source would revert if reached; mock it harmlessly
        vm.mockCall(
            unconfigured, abi.encodeWithSelector(IERC20.balanceOf.selector, holder), abi.encode(uint256(1 ether))
        );
        address[] memory srcs = new address[](1);
        srcs[0] = unconfigured;
        address[] memory dts = new address[](1);
        dts[0] = address(memeA);
        uint256[] memory amts = new uint256[](1);
        amts[0] = 10 ether;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        // Option A: unconfigured source now reverts (was skip-as-zero).
        // SourceNotConfigured() added to IDividendVault by the implementation.
        vm.prank(holder);
        vm.expectRevert(bytes4(keccak256("SourceNotConfigured()")));
        vault.claim(srcs, dts, amts, proofs);
        assertEq(memeA.balanceOf(holder), 0, "unconfigured source reverts");
    }

    // ── cumulative-claimed model ──
    // The merkle leaf amount is the FULL cumulative accrued for that holder (computed off-chain,
    // NOT decremented there). claim() pays only (amount - claimedCumulative), so republishing a root
    // with the same or lower cumulative pays 0 — distribution is race-free regardless of root timing.

    function test_claim_cumulative_newRootSameAmount_paysZero() public {
        // The canonical double-pay vector: a holder's cumulative is unchanged across periods, but the
        // root differs because OTHER leaves changed. A 2-leaf tree keeps holderLeaf fixed (amount 10)
        // while the sibling rotates, so root1 != root2 with the holder's accrued still 10.
        address holder = makeAddr("holderCumSame");
        _configureAndFund(address(memeA), 0, 100 ether);
        _mockHolderBalance(holder, 1 ether);

        bytes32 holderLeaf = _claimLeaf(sourceToken, holder, address(memeA), 10 ether);

        // Period 1: tree {holderLeaf, sibling1}
        bytes32 sibling1 = keccak256("cum-same-sibling-1");
        _setRoot(_pairRoot(holderLeaf, sibling1));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, _proofOf(sibling1));
        assertEq(memeA.balanceOf(holder), 10 ether);

        // Period 2: NEW root (sibling rotated) but holder's cumulative is STILL 10 → must pay 0
        bytes32 sibling2 = keccak256("cum-same-sibling-2");
        _setRoot(_pairRoot(holderLeaf, sibling2));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, _proofOf(sibling2));
        assertEq(memeA.balanceOf(holder), 10 ether, "republished root must not double-pay (same cumulative)");
    }

    function test_claim_cumulative_higherAccrual_paysDelta() public {
        address holder = makeAddr("holderCumUp");
        _configureAndFund(address(memeA), 0, 100 ether);
        _mockHolderBalance(holder, 1 ether);

        _setRoot(_claimLeaf(sourceToken, holder, address(memeA), 10 ether));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 10 ether);

        // Accrued grows to 25 → pays only the 15 delta, holder total == latest cumulative
        _setRoot(_claimLeaf(sourceToken, holder, address(memeA), 25 ether));
        _claimOne(holder, sourceToken, address(memeA), 25 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 25 ether, "pays cumulative delta, total == latest accrued");
    }

    function test_claim_cumulative_lowerAccrual_paysZero() public {
        address holder = makeAddr("holderCumDown");
        _configureAndFund(address(memeA), 0, 100 ether);
        _mockHolderBalance(holder, 1 ether);

        _setRoot(_claimLeaf(sourceToken, holder, address(memeA), 10 ether));
        _claimOne(holder, sourceToken, address(memeA), 10 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 10 ether);

        // A stale/lower root (cumulative 7 < already-claimed 10) → pays 0, no rollback
        _setRoot(_claimLeaf(sourceToken, holder, address(memeA), 7 ether));
        _claimOne(holder, sourceToken, address(memeA), 7 ether, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), 10 ether, "lower/equal cumulative pays nothing");
    }

    function test_integration_afterDeposit_then_claim() public {
        address holder = makeAddr("holderI");
        _setup(_single(address(quoteToken)), _singleRatio(10000), 0); // 100% quote, no conversion needed
        _mockHolderBalance(holder, 1 ether);

        uint256 deposit = 8 ether;
        quoteToken.mint(address(vault), deposit);
        vault.afterDeposit(sourceToken, address(quoteToken), deposit);
        assertEq(vault.dividendBalance(sourceToken, address(quoteToken)), deposit);

        bytes32 leaf = _claimLeaf(sourceToken, holder, address(quoteToken), deposit);
        _setRoot(leaf);

        uint256 before = quoteToken.balanceOf(holder);
        _claimOne(holder, sourceToken, address(quoteToken), deposit, new bytes32[](0));
        assertEq(quoteToken.balanceOf(holder) - before, deposit, "holder received quote dividend");
    }

    function test_claim_batch_multipleDividendTokens() public {
        address holder = makeAddr("holderB");
        address[] memory tokens = new address[](2);
        tokens[0] = address(quoteToken);
        tokens[1] = address(memeA);
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        vm.prank(bondingCurve);
        vault.setup(sourceToken, abi.encode(tokens, ratios, uint256(0)));
        _mockHolderBalance(holder, 1 ether);
        quoteToken.mint(address(vault), 4 ether);
        memeA.mint(address(vault), 4 ether);

        bytes32 leafQuote = _claimLeaf(sourceToken, holder, address(quoteToken), 3 ether);
        bytes32 leafMeme = _claimLeaf(sourceToken, holder, address(memeA), 2 ether);
        bytes32 root = leafQuote < leafMeme
            ? keccak256(abi.encodePacked(leafQuote, leafMeme))
            : keccak256(abi.encodePacked(leafMeme, leafQuote));
        _setRoot(root);

        address[] memory srcs = new address[](2);
        srcs[0] = sourceToken;
        srcs[1] = sourceToken;
        address[] memory dts = new address[](2);
        dts[0] = address(quoteToken);
        dts[1] = address(memeA);
        uint256[] memory amts = new uint256[](2);
        amts[0] = 3 ether;
        amts[1] = 2 ether;
        bytes32[][] memory proofs = new bytes32[][](2);
        bytes32[] memory pQuote = new bytes32[](1);
        pQuote[0] = leafMeme;
        bytes32[] memory pMeme = new bytes32[](1);
        pMeme[0] = leafQuote;
        proofs[0] = pQuote;
        proofs[1] = pMeme;

        // ONE Claim event per call: full parallel arrays covering every input item, in order
        vm.expectEmit(true, false, false, true, address(vault));
        emit IDividendVault.Claim(holder, srcs, dts, amts);
        vm.prank(holder);
        vault.claim(srcs, dts, amts, proofs);

        assertEq(quoteToken.balanceOf(holder), 3 ether);
        assertEq(memeA.balanceOf(holder), 2 ether);
    }

    // ── integration: deposit → bot conversion → claim (3-stage pipeline) ──

    function test_integration_deposit_convert_claim() public {
        _setup(_single(address(memeA)), _singleRatio(10000), 0);
        quoteToken.mint(address(vault), 2 ether);
        vault.afterDeposit(sourceToken, address(quoteToken), 2 ether);

        uint256 expectedOut = 42 ether;
        mockRouter.setNextOut(expectedOut);
        IDividendVault.ConversionHop[] memory path = _singleHop(address(mockRouter), address(memeA), address(memeA));
        _grantSelector(operator, DividendVault.executeConversion.selector);
        vm.prank(operator);
        vault.executeConversion(_order(sourceToken, address(memeA), path, 2 ether, expectedOut));

        address holder = makeAddr("holderConverted");
        _mockHolderBalance(holder, 1 ether);
        bytes32 leaf = _claimLeaf(sourceToken, holder, address(memeA), expectedOut);
        _setRoot(leaf);
        _claimOne(holder, sourceToken, address(memeA), expectedOut, new bytes32[](0));
        assertEq(memeA.balanceOf(holder), expectedOut, "holder received the bot-converted dividend");
    }
}
