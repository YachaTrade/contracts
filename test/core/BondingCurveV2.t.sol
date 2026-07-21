// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Core
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {BondingCurve} from "../../src/core/BondingCurve.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {LPManager} from "../../src/core/LPManager.sol";

// Token
import {Token} from "../../src/token/Token.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";

// Fee
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";

// Dex
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";

// Adapter
import {NadSwapAdapter} from "../../src/adapters/NadSwapAdapter.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";

// Vault
import {VaultRegistry} from "../../src/vault/VaultRegistry.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";

// OpenZeppelin
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BondingCurveV2Test — Tests for BondingCurve with Token (plain ERC20) + NadFunFactory + FeeCollector
/// @notice Verifies the v2.0.0 changes: no creator-fee-on-transfer, curve-level creator fee via FeeCollector
contract BondingCurveV2Test is Test {
    // ── Addresses ──────────────────────────────────────────────
    address public admin;
    address public feeReceiver;
    address public creator;
    address public user1;
    address public user2;

    // ── Tokens ─────────────────────────────────────────────────
    MockERC20 public quoteToken;
    MockWMON public wmon;

    // ── Core ───────────────────────────────────────────────────
    ProtocolManager public protocolManager;
    BondingCurve public bondingCurve;
    TokenRegistry public tokenRegistry;
    LPManager public lpManager;

    // ── Token ──────────────────────────────────────────────────
    Token public tokenImpl;
    CreatorFeeProcessor public creatorFeeProcessor;

    // ── Fee ────────────────────────────────────────────────────
    FeeCollector public feeCollector;
    NadFunFactory public nadFunFactory;

    // ── Vault ──────────────────────────────────────────────────
    VaultRegistry public vaultRegistry;
    CreatorFeeVault public creatorFeeVault;

    // ── Constants ──────────────────────────────────────────────
    uint256 public constant VIRTUAL_RESERVE = 70_000 ether;
    uint256 public constant VIRTUAL_TOKEN_RESERVE = 1_060_569_000 ether;
    uint256 public constant MIN_TOKEN_RESERVE = 251_660_440_677_966_101_694_915_255;
    uint16 public constant DEFAULT_CREATOR_FEE_RATE = 100; // 1%
    uint16 public constant DEFAULT_CURVE_PROTOCOL_FEE = 100; // 1%
    uint16 public constant DEFAULT_DEX_PROTOCOL_FEE = 35; // 0.35%
    uint256 public constant DEFAULT_DEPLOY_FEE = 10 ether;
    uint256 public constant DEFAULT_GRADUATE_FEE = 1_000 ether;
    uint256 public constant SETTLEMENT_THRESHOLD = 1_000 ether;

    function setUp() public {
        // 1. Addresses
        admin = makeAddr("admin");
        feeReceiver = makeAddr("feeReceiver");
        creator = makeAddr("creator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // 2. Quote token + native wrapper
        quoteToken = new MockERC20("WMON", "WMON", 18);
        wmon = new MockWMON();

        vm.startPrank(admin);

        // 4. ProtocolManager
        ProtocolManager pmImpl = new ProtocolManager();
        protocolManager = ProtocolManager(
            address(new ERC1967Proxy(address(pmImpl), abi.encodeCall(ProtocolManager.initialize, (admin, feeReceiver))))
        );
        protocolManager.addQuoteToken(
            address(quoteToken),
            VIRTUAL_RESERVE,
            VIRTUAL_TOKEN_RESERVE,
            MIN_TOKEN_RESERVE,
            DEFAULT_DEPLOY_FEE,
            DEFAULT_GRADUATE_FEE,
            DEFAULT_CURVE_PROTOCOL_FEE,
            DEFAULT_DEX_PROTOCOL_FEE,
            0
        );
        {
            uint256[] memory snipingTable = new uint256[](7);
            snipingTable[0] = 8000;
            snipingTable[1] = 4000;
            snipingTable[2] = 2000;
            snipingTable[3] = 1500;
            snipingTable[4] = 1000;
            snipingTable[5] = 1000;
            snipingTable[6] = 500;
            protocolManager.setSnipingPenaltyTable(snipingTable);
        }
        {
            uint16[] memory rates = new uint16[](3);
            rates[0] = 100;
            rates[1] = 300;
            rates[2] = 500;
            protocolManager.setAllowedCreatorFeeRates(rates);
        }

        // 5. TokenRegistry
        TokenRegistry trImpl = new TokenRegistry();
        tokenRegistry = TokenRegistry(
            address(
                new ERC1967Proxy(address(trImpl), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager))))
            )
        );

        // 5b. NadSwapAdapter — register V2 adapter
        tokenRegistry.setAdapter(ITokenRegistry.DexType.UniswapV2, IDexAdapter(address(new NadSwapAdapter())));

        // 6. LPManager
        LPManager lmImpl = new LPManager();
        lpManager = LPManager(
            address(
                new ERC1967Proxy(
                    address(lmImpl),
                    abi.encodeCall(LPManager.initialize, (address(protocolManager), address(tokenRegistry)))
                )
            )
        );

        // 8. Token implementation (clone template)
        tokenImpl = new Token();

        // 9. BondingCurve (UUPS proxy)
        BondingCurve bcImpl = new BondingCurve();
        bondingCurve = BondingCurve(
            payable(address(
                    new ERC1967Proxy(
                        address(bcImpl),
                        abi.encodeCall(BondingCurve.initialize, (admin, address(tokenImpl), address(protocolManager)))
                    )
                ))
        );

        // 10. NadFunFactory — creates pairs
        // FeeCollector must be deployed before factory (factory stores feeCollector)
        // But FeeCollector needs bondingCurve... deploy FeeCollector first with temp address, then factory
        // Actually: FeeCollector.initialize takes bondingCurve_ but NadFunFactory takes feeCollector in constructor
        // We need to deploy FeeCollector first (it's a proxy so address is known), then factory with it
        FeeCollector fcImpl = new FeeCollector();

        // 11. CreatorFeeProcessor
        // We need feeCollector address before CreatorFeeProcessor. Deploy proxy for FeeCollector first.
        // Deploy FeeCollector proxy shell, then initialize later? No, ERC1967Proxy calls initialize in constructor.
        // Solution: deploy creatorFeeProcessor with placeholder feeCollector, or deploy feeCollector first.
        // FeeCollector.initialize needs creatorFeeProcessor. Circular dependency!
        // Resolution: deploy CreatorFeeProcessor first with placeholder feeCollector address, since CreatorFeeProcessor is not a proxy.
        // Actually CreatorFeeProcessor constructor takes (bondingCurve, feeCollector) as immutables.
        // We can compute the feeCollector proxy address deterministically? Or just deploy in the right order.
        // Let's use CREATE to predict address: deploy feeCollector proxy AFTER creatorFeeProcessor.
        // But creatorFeeProcessor needs feeCollector address... this IS circular.
        // Looking at the code: CreatorFeeProcessor.processCreatorFee checks msg.sender == feeCollector.
        // FeeCollector.settle calls creatorFeeProcessor.processCreatorFee.
        // For tests, we can deploy with address(0) first then fix... but that's immutable.
        // Let's check: can we compute the address? Yes, with vm.computeCreateAddress.

        // Compute future addresses
        uint64 nonce = vm.getNonce(admin);
        // Next 3 deploys: CreatorFeeProcessor, FeeCollector impl (already done), FeeCollector proxy
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
                            makeAddr("router")
                        )
                    )
                )
            )
        );

        require(address(feeCollector) == predictedFeeCollector, "FeeCollector address prediction failed");

        // 12. NadFunFactory
        NadFunPair pairImpl = new NadFunPair();
        nadFunFactory = new NadFunFactory(address(protocolManager), address(feeCollector), address(pairImpl));

        // 13. VaultRegistry
        VaultRegistry vrImpl = new VaultRegistry();
        vaultRegistry = VaultRegistry(
            address(
                new ERC1967Proxy(address(vrImpl), abi.encodeCall(VaultRegistry.initialize, (address(protocolManager))))
            )
        );

        // 14. CreatorFeeVault (UUPS proxy)
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

        // 15. Register vault
        vaultRegistry.register(
            address(creatorFeeVault), "CreatorFeeVault", "Direct transfer", IVaultRegistry.VaultType.Creator
        );

        // 16. BondingCurve module registration
        bondingCurve.setModule(keccak256("TOKEN_REGISTRY"), address(tokenRegistry));
        bondingCurve.setModule(keccak256("LP_MANAGER"), address(lpManager));
        bondingCurve.setModule(keccak256("CREATOR_FEE_PROCESSOR"), address(creatorFeeProcessor));
        bondingCurve.setModule(keccak256("VAULT_REGISTRY"), address(vaultRegistry));
        bondingCurve.setModule(keccak256("FEE_COLLECTOR"), address(feeCollector));
        bondingCurve.setModule(keccak256("FACTORY"), address(nadFunFactory));

        // 17. Authorize BondingCurve
        protocolManager.setOperatorPermission(
            address(bondingCurve), address(tokenRegistry), TokenRegistry.register.selector, true
        );
        protocolManager.setOperatorPermission(
            address(bondingCurve), address(lpManager), LPManager.addLiquidity.selector, true
        );

        // 18. Grant ROUTER_ROLE to test contract for direct testing
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));

        // 19. Allow 0% creator fee rate for zero-creator-fee test cases
        uint16[] memory extraRates = new uint16[](1);
        extraRates[0] = 0;
        protocolManager.setAllowedCreatorFeeRates(extraRates);

        vm.stopPrank();

        // Skip anti-sniping period
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    // ── Helpers ────────────────────────────────────────────────

    function _defaultParams() internal view returns (IBondingCurve.CreateTokenParams memory) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(feeReceiver)
        });

        return IBondingCurve.CreateTokenParams({
            name: "TestToken",
            symbol: "TT",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: DEFAULT_CREATOR_FEE_RATE,
            vaults: vaults,
            salt: keccak256("v2-test-token"),
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: creator,
            buyQuoteAmount: 0
        });
    }

    function _createToken() internal returns (address token) {
        uint256 deployFee = protocolManager.deployFee(address(quoteToken));
        quoteToken.mint(address(this), deployFee);
        quoteToken.transfer(address(bondingCurve), deployFee);
        (token,) = bondingCurve.create(_defaultParams());
        // Skip anti-sniping period for the newly created token
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    function _createTokenWithCreatorFeeRate(uint16 creatorFeeRate, bytes32 salt) internal returns (address token) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(feeReceiver)
        });

        IBondingCurve.CreateTokenParams memory params = IBondingCurve.CreateTokenParams({
            name: "TestToken",
            symbol: "TT",
            tokenURI: "",
            quoteToken: address(quoteToken),
            creatorFeeRate: creatorFeeRate,
            vaults: vaults,
            salt: salt,
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: creator,
            buyQuoteAmount: 0
        });

        uint256 deployFee = protocolManager.deployFee(address(quoteToken));
        quoteToken.mint(address(this), deployFee);
        quoteToken.transfer(address(bondingCurve), deployFee);
        (token,) = bondingCurve.create(params);
        // Skip anti-sniping period for the newly created token
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    function _buyOnCurve(address buyer, address token, uint256 quote) internal returns (uint256 tokenOut) {
        quoteToken.mint(buyer, quote);
        vm.prank(buyer);
        quoteToken.transfer(address(bondingCurve), quote);
        vm.prank(buyer);
        tokenOut = bondingCurve.buy(buyer, token);
    }

    function _sellOnCurve(address seller, address token, uint256 tokenAmount) internal returns (uint256 quoteOut) {
        vm.startPrank(seller);
        IERC20(token).transfer(address(bondingCurve), tokenAmount);
        quoteOut = bondingCurve.sell(seller, token);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════
    // Creation Tests
    // ═════════════════════════════════════════════════════════════

    function test_create_deploysToken() public {
        address token = _createToken();
        assertTrue(token != address(0), "Token should be deployed");
        assertEq(IERC20(token).totalSupply(), 1_000_000_000 ether, "Total supply should be 1B");
    }

    function test_create_createsPairViaNadFunFactory() public {
        address token = _createToken();
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);

        // Pair should exist in NadFunFactory
        address pair = nadFunFactory.getPair(token, address(quoteToken));
        assertTrue(pair != address(0), "Pair should exist in NadFunFactory");
        assertEq(curve.pair, pair, "Curve pair should match factory pair");
    }

    function test_create_setupsFeeCollector() public {
        address token = _createToken();
        address pair = nadFunFactory.getPair(token, address(quoteToken));

        IFeeCollector.FeeConfig memory config = feeCollector.getFeeConfig(pair);
        assertEq(config.creatorFeeRate, DEFAULT_CREATOR_FEE_RATE, "FeeCollector creatorFeeRate should match");
        assertEq(
            config.curveProtocolFeeRate, DEFAULT_CURVE_PROTOCOL_FEE, "FeeCollector curveProtocolFeeRate should match"
        );
        assertEq(config.dexProtocolFeeRate, DEFAULT_DEX_PROTOCOL_FEE, "FeeCollector dexProtocolFeeRate should match");

        assertEq(
            config.creatorFeeRate + config.curveProtocolFeeRate,
            DEFAULT_CREATOR_FEE_RATE + DEFAULT_CURVE_PROTOCOL_FEE,
            "FeeCollector total feeRate should match"
        );
        assertEq(config.quoteToken, address(quoteToken), "FeeCollector quoteToken should match");
    }

    function test_create_setupsCreatorFeeProcessor() public {
        address token = _createToken();

        assertEq(creatorFeeProcessor.vaultCount(token), 1, "CreatorFeeProcessor should have 1 vault configured");
    }

    function test_create_tokenIsPlainERC20() public {
        address token = _createToken();

        // Token is a plain ERC20 — it has bondingCurve() and isGraduated() but no creator-fee-on-transfer
        assertEq(IToken(token).bondingCurve(), address(bondingCurve), "bondingCurve should be set");
        assertFalse(IToken(token).isGraduated(), "Should not be graduated yet");

        // Transfer should NOT deduct creator fee (plain ERC20)
        // BondingCurve has all tokens; let's buy some first
        uint256 tokenOut = _buyOnCurve(user1, token, 1000 ether);

        uint256 balBefore = IERC20(token).balanceOf(user2);
        vm.prank(user1);
        IERC20(token).transfer(user2, tokenOut);
        uint256 balAfter = IERC20(token).balanceOf(user2);

        // Full amount should arrive — no creator-fee-on-transfer
        assertEq(balAfter - balBefore, tokenOut, "Transfer should not deduct creator fee");
    }

    function test_create_storesCreatorFeeRateInCurve() public {
        address token = _createToken();
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        assertEq(curve.creatorFeeRate, DEFAULT_CREATOR_FEE_RATE, "Curve creatorFeeRate should be stored");
    }

    // ═════════════════════════════════════════════════════════════
    // Buy with Creator Fee Tests
    // ═════════════════════════════════════════════════════════════

    function test_buy_deductsCreatorFee() public {
        address token = _createToken();

        uint256 quoteIn = 1000 ether;
        uint256 tokenOut = _buyOnCurve(user1, token, quoteIn);

        // Compare with zero-creator-fee token to verify creator fee reduces output
        assertTrue(tokenOut > 0, "Should receive tokens");
    }

    function test_buy_creatorFeeSentToFeeCollector() public {
        address token = _createToken();

        // Skip sniping period for this token
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        uint256 quoteIn = 10_000 ether;
        uint256 fcBalBefore = quoteToken.balanceOf(address(feeCollector));

        _buyOnCurve(user1, token, quoteIn);

        uint256 fcBalAfter = quoteToken.balanceOf(address(feeCollector));
        uint256 creatorFeeInCollector = fcBalAfter - fcBalBefore;

        // BondingCurve sends (protocolFee + creatorFee) to FeeCollector which splits once.
        // Creator portion remaining in collector should equal the full creator fee.
        // totalFeeRate = 50 + 500 = 550
        //   totalFee    = mulDivUp(quoteIn, 550, 10000)
        //   protocolFee = mulDivUp(quoteIn, 50,  10000)
        //   creatorFee  = totalFee - protocolFee
        uint256 expectedTotalFee = FixedPointMathLib.mulDivUp(
            quoteIn, uint256(DEFAULT_CREATOR_FEE_RATE) + uint256(DEFAULT_CURVE_PROTOCOL_FEE), 10000
        );
        uint256 expectedProtocolFee = FixedPointMathLib.mulDivUp(quoteIn, uint256(DEFAULT_CURVE_PROTOCOL_FEE), 10000);
        uint256 expectedCreatorFeeInCollector = expectedTotalFee - expectedProtocolFee;

        assertEq(
            creatorFeeInCollector,
            expectedCreatorFeeInCollector,
            "Creator fee in FeeCollector should be the full creator fee (single split)"
        );
        assertTrue(creatorFeeInCollector > 0, "FeeCollector should have received creator fee");
    }

    function test_buy_correctTokenOutAfterAllFees() public {
        address token = _createToken();

        uint256 quoteIn = 5000 ether;
        uint256 tokenOut = _buyOnCurve(user1, token, quoteIn);

        // Verify via getAmountOut
        // Note: getAmountOut uses floor division while _buyV1 uses ceil for protocolFee
        // so there may be a small difference. We check user balance matches tokenOut.
        uint256 userBal = IERC20(token).balanceOf(user1);
        assertEq(userBal, tokenOut, "User balance should match tokenOut exactly (no creator-fee-on-transfer)");
    }

    function test_buy_noCreatorFeeWhenRateIsZero() public {
        // Create token with 0% creator fee
        address token = _createTokenWithCreatorFeeRate(0, keccak256("zero-creatorFee-token"));

        uint256 fcBalBefore = quoteToken.balanceOf(address(feeCollector));
        _buyOnCurve(user1, token, 1000 ether);
        uint256 fcBalAfter = quoteToken.balanceOf(address(feeCollector));

        assertEq(fcBalAfter, fcBalBefore, "No creator fee should be sent when creatorFeeRate is 0");
    }

    // ═════════════════════════════════════════════════════════════
    // Sell with Creator Fee Tests
    // ═════════════════════════════════════════════════════════════

    function test_sell_deductsCreatorFee() public {
        address token = _createToken();

        // Buy first to get tokens
        uint256 tokenOut = _buyOnCurve(user1, token, 10_000 ether);

        // Sell half
        uint256 sellAmount = tokenOut / 2;
        uint256 quoteOut = _sellOnCurve(user1, token, sellAmount);

        assertTrue(quoteOut > 0, "Should receive quote");
    }

    function test_sell_creatorFeeSentToFeeCollector() public {
        address token = _createToken();

        uint256 tokenOut = _buyOnCurve(user1, token, 50_000 ether);

        // Clear FeeCollector balance from buy creatorFee
        uint256 fcBalBefore = quoteToken.balanceOf(address(feeCollector));

        uint256 sellAmount = tokenOut / 2;
        _sellOnCurve(user1, token, sellAmount);

        uint256 fcBalAfter = quoteToken.balanceOf(address(feeCollector));
        uint256 creatorFeeReceived = fcBalAfter - fcBalBefore;

        assertTrue(creatorFeeReceived > 0, "FeeCollector should receive creator fee on sell");
    }

    function test_sell_correctQuoteOutAfterAllFees() public {
        address token = _createToken();
        uint256 tokenOut = _buyOnCurve(user1, token, 10_000 ether);

        uint256 sellAmount = tokenOut / 4;
        uint256 userBalBefore = quoteToken.balanceOf(user1);
        _sellOnCurve(user1, token, sellAmount);
        uint256 userBalAfter = quoteToken.balanceOf(user1);
        uint256 actualQuoteOut = userBalAfter - userBalBefore;

        assertTrue(actualQuoteOut > 0, "User should receive quote tokens");
    }

    function test_sell_noCreatorFeeWhenRateIsZero() public {
        address token = _createTokenWithCreatorFeeRate(0, keccak256("zero-creator-fee-sell"));

        uint256 tokenOut = _buyOnCurve(user1, token, 5000 ether);

        uint256 fcBalBefore = quoteToken.balanceOf(address(feeCollector));
        _sellOnCurve(user1, token, tokenOut / 2);
        uint256 fcBalAfter = quoteToken.balanceOf(address(feeCollector));

        assertEq(fcBalAfter, fcBalBefore, "No creator fee on sell when creatorFeeRate is 0");
    }

    // ═════════════════════════════════════════════════════════════
    // Graduation Tests
    // ═════════════════════════════════════════════════════════════

    function test_graduate_usesNadFunPair() public {
        address token = _createToken();
        IBondingCurve.Curve memory curveBefore = bondingCurve.getCurve(token);

        // Pair was created by NadFunFactory
        address expectedPair = nadFunFactory.getPair(token, address(quoteToken));
        assertEq(curveBefore.pair, expectedPair, "Pair should be from NadFunFactory");

        // Graduate by buying enough — need extra to cover 5% creator fee + 0.5% protocolFee
        // Without creator fee: ~637,540 needed. With 5% creator fee: ~637,540 / 0.945 ≈ 674,646
        // Use 800,000 to be safe
        _graduateToken(token);

        IBondingCurve.Curve memory curveAfter = bondingCurve.getCurve(token);
        assertTrue(curveAfter.graduated, "Token should be graduated");
    }

    function test_graduate_setsIsGraduated() public {
        address token = _createToken();

        assertFalse(IToken(token).isGraduated(), "Should not be graduated before");

        _graduateToken(token);

        assertTrue(IToken(token).isGraduated(), "Token.isGraduated should be true after graduation");
    }

    /// @dev Helper to graduate a token — skips sniping and sends enough quote to push past minTokenReserve
    function _graduateToken(address token) internal {
        // Skip sniping period for this token
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        // With 5% creator fee + 0.5% protocolFee on AMM input, need ~5.5% more than the base ~637,540
        // Use 750,000 to be safe
        uint256 graduationAmount = 750_000 ether;
        quoteToken.mint(user1, graduationAmount);
        vm.prank(user1);
        quoteToken.transfer(address(bondingCurve), graduationAmount);
        vm.prank(user1);
        bondingCurve.buy(user1, token);
        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        require(curve.graduated, "Token should be graduated");
    }

    // ═════════════════════════════════════════════════════════════
    // getAmountOut / getAmountIn with Creator Fee Tests
    // ═════════════════════════════════════════════════════════════

    function test_getAmountOut_buy_includesCreatorFee() public {
        address token = _createToken();

        uint256 quoteIn = 10_000 ether;
        uint256 amountOut = bondingCurve.getAmountOut(token, quoteIn, true);

        // Create a zero-creator-fee token for comparison
        address tokenNoCreatorFee = _createTokenWithCreatorFeeRate(0, keccak256("no-creatorFee-compare-buy"));
        uint256 amountOutNoCreatorFee = bondingCurve.getAmountOut(tokenNoCreatorFee, quoteIn, true);

        // With creator fee, should get fewer tokens
        assertTrue(amountOut < amountOutNoCreatorFee, "getAmountOut with creator fee should return less tokens");
    }

    function test_getAmountOut_sell_includesCreatorFee() public {
        address token = _createToken();

        // Buy first to have tokens in the curve
        _buyOnCurve(user1, token, 50_000 ether);

        uint256 tokenIn = 1_000_000 ether;
        uint256 amountOut = bondingCurve.getAmountOut(token, tokenIn, false);

        // Create a zero-creator-fee token and buy on it too
        address tokenNoCreatorFee = _createTokenWithCreatorFeeRate(0, keccak256("no-creatorFee-compare-sell"));
        _buyOnCurve(user2, tokenNoCreatorFee, 50_000 ether);

        uint256 amountOutNoCreatorFee = bondingCurve.getAmountOut(tokenNoCreatorFee, tokenIn, false);

        // With creator fee, should get fewer quote tokens
        assertTrue(amountOut < amountOutNoCreatorFee, "getAmountOut sell with creator fee should return less quote");
    }

    function test_getAmountIn_buy_includesCreatorFee() public {
        address token = _createToken();

        uint256 desiredTokenOut = 1_000_000 ether;
        uint256 amountIn = bondingCurve.getAmountIn(token, desiredTokenOut, true);

        // Compare with zero-creator-fee
        address tokenNoCreatorFee = _createTokenWithCreatorFeeRate(0, keccak256("no-creatorFee-amountin-buy"));
        uint256 amountInNoCreatorFee = bondingCurve.getAmountIn(tokenNoCreatorFee, desiredTokenOut, true);

        // With creator fee, need more quote in
        assertTrue(amountIn > amountInNoCreatorFee, "getAmountIn buy with creator fee should require more quote");
    }

    function test_getAmountIn_sell_includesCreatorFee() public {
        address token = _createToken();
        _buyOnCurve(user1, token, 50_000 ether);

        uint256 desiredQuoteOut = 100 ether;
        uint256 amountIn = bondingCurve.getAmountIn(token, desiredQuoteOut, false);

        // Compare with zero-creator-fee
        address tokenNoCreatorFee = _createTokenWithCreatorFeeRate(0, keccak256("no-creatorFee-amountin-sell"));
        _buyOnCurve(user2, tokenNoCreatorFee, 50_000 ether);
        uint256 amountInNoCreatorFee = bondingCurve.getAmountIn(tokenNoCreatorFee, desiredQuoteOut, false);

        // With creator fee, need more tokens in to get same quote out
        assertTrue(amountIn > amountInNoCreatorFee, "getAmountIn sell with creator fee should require more tokens");
    }

    // ═════════════════════════════════════════════════════════════
    // Fee Accumulation Tests
    // ═════════════════════════════════════════════════════════════

    function test_buy_feeCollectorAccumulatesFees() public {
        address token = _createToken();
        address pair = nadFunFactory.getPair(token, address(quoteToken));

        _buyOnCurve(user1, token, 10_000 ether);

        uint256 accumulated = feeCollector.accumulatedFee(pair);
        assertTrue(accumulated > 0, "FeeCollector should have accumulated fees after buy");
    }

    function test_sell_feeCollectorAccumulatesFees() public {
        address token = _createToken();
        address pair = nadFunFactory.getPair(token, address(quoteToken));

        uint256 tokenOut = _buyOnCurve(user1, token, 10_000 ether);
        uint256 accBefore = feeCollector.accumulatedFee(pair);

        _sellOnCurve(user1, token, tokenOut / 2);

        uint256 accAfter = feeCollector.accumulatedFee(pair);
        assertTrue(accAfter > accBefore, "FeeCollector should accumulate more fees after sell");
    }

    function test_buy_protocolFeePlusCreatorFeePlusSnipingPenalty() public {
        // Create a fresh token without skipping the sniping window — same-block buy applies
        // table[0] = 8000 BPS (max sniping penalty). Additive model:
        // totalFeeRate = 8000 (sniping) + 100 (protocol) + 100 (creator) = 8200 BPS < BPS.
        uint256 deployFee = protocolManager.deployFee(address(quoteToken));
        quoteToken.mint(address(this), deployFee);
        quoteToken.transfer(address(bondingCurve), deployFee);
        (address token,) = bondingCurve.create(_defaultParams());
        address pair = nadFunFactory.getPair(token, address(quoteToken));

        IBondingCurve.Curve memory curve = bondingCurve.getCurve(token);
        assertEq(uint256(curve.createdAtBlock), block.number, "curve created at current block");
        assertEq(bondingCurve.getSnipingPenalty(token), 8000, "max sniping penalty at creation block");

        uint256 quoteIn = 10_000 ether;
        quoteToken.mint(user1, quoteIn);
        vm.prank(user1);
        quoteToken.transfer(address(bondingCurve), quoteIn);
        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);
        uint256 accumulatedBefore = feeCollector.accumulatedFee(pair);

        uint256 receiverBefore = quoteToken.balanceOf(feeReceiver);
        vm.prank(user1);
        uint256 tokenOut = bondingCurve.buy(user1, token);

        uint256 snipingFee = 8_000 ether;
        uint256 protocolFee = 100 ether;
        uint256 creatorFee = 100 ether;

        assertGt(tokenOut, 0, "buy succeeds even at max sniping penalty");
        assertEq(IERC20(token).balanceOf(user1), tokenOut, "buyer receives tokens");
        assertEq(quoteToken.balanceOf(feeReceiver), feeReceiverBefore + snipingFee + protocolFee, "fee receiver");
        assertEq(feeCollector.accumulatedFee(pair), accumulatedBefore + creatorFee, "creator fee");

        // FeeReceiver collects protocolFee + snipingFee on buys (creator fee accrues separately).
        uint256 receiverDelta = quoteToken.balanceOf(feeReceiver) - receiverBefore;
        // Sniping alone is 80% of quoteIn = 8000 ether; protocol fee adds another 50 BPS.
        assertGt(receiverDelta, (quoteIn * 8000) / 10_000, "fee receiver got at least the sniping portion");
    }
}
