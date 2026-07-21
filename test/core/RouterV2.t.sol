// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for RouterV2.

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Core
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {LPManager} from "../../src/core/LPManager.sol";

// Router
import {NadFunRouter} from "../../src/router/NadFunRouter.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";

// Adapter
import {NadSwapAdapter} from "../../src/adapters/NadSwapAdapter.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";

// DEX
import {NadFunFactory} from "../../src/dex/NadFunFactory.sol";
import {NadFunPair} from "../../src/dex/NadFunPair.sol";
import {INadFunPair} from "../../src/dex/interfaces/INadFunPair.sol";

// Fee
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";

// Mocks
import {MockERC20} from "../mocks/MockERC20.sol";

contract RouterV2Test is Test {
    address admin = makeAddr("admin");
    address feeReceiver = makeAddr("feeReceiver");
    address user1 = makeAddr("user1");
    address creatorFeeProcessor = makeAddr("creatorFeeProcessor");

    MockERC20 quoteToken;
    MockERC20 baseToken;

    ProtocolManager protocolManager;
    TokenRegistry tokenRegistry;
    LPManager lpManager;
    NadFunFactory nadFunFactory;
    FeeCollector feeCollector;
    NadFunRouter nadFunRouter;
    address mockBondingCurve = makeAddr("mockBondingCurve");

    address pair;

    uint256 constant INITIAL_TOKEN_LIQ = 100_000 ether;
    uint256 constant INITIAL_QUOTE_LIQ = 10 ether;
    uint16 constant CREATOR_FEE_RATE = 100; // 1%
    uint16 constant PROTOCOL_FEE_RATE = 35; // 0.35%

    function setUp() public {
        // 1. Deploy tokens
        quoteToken = new MockERC20("WMON", "WMON", 18);
        baseToken = new MockERC20("MemeToken", "BASE", 18);

        vm.startPrank(admin);

        // 2. ProtocolManager
        ProtocolManager pmImpl = new ProtocolManager();
        protocolManager = ProtocolManager(
            address(new ERC1967Proxy(address(pmImpl), abi.encodeCall(ProtocolManager.initialize, (admin, feeReceiver))))
        );
        protocolManager.addQuoteToken(
            address(quoteToken),
            70_000 ether, // virtualReserve
            1_060_569_000 ether, // virtualTokenReserve
            251_660_440_677_966_101_694_915_255, // minTokenReserve
            10 ether, // deployFee
            1_000 ether, // graduateFee
            100, // curveProtocolFee
            PROTOCOL_FEE_RATE, // dexProtocolFee
            1_000 ether
        );
        // 3. FeeCollector (UUPS proxy)
        FeeCollector fcImpl = new FeeCollector();
        feeCollector = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(fcImpl),
                    abi.encodeCall(
                        FeeCollector.initialize,
                        (address(protocolManager), creatorFeeProcessor, admin, makeAddr("router"))
                    )
                )
            )
        );

        // 4. NadFunFactory (uses feeCollector)
        NadFunPair pairImpl = new NadFunPair();
        nadFunFactory = new NadFunFactory(address(protocolManager), address(feeCollector), address(pairImpl));

        // 5. TokenRegistry
        TokenRegistry trImpl = new TokenRegistry();
        tokenRegistry = TokenRegistry(
            address(
                new ERC1967Proxy(address(trImpl), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager))))
            )
        );

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
        protocolManager.setOperatorPermission(address(this), address(lpManager), LPManager.addLiquidity.selector, true);

        // 7. NadFunRouter (UUPS proxy)
        NadFunRouter routerImpl = new NadFunRouter();
        nadFunRouter = NadFunRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(routerImpl),
                        abi.encodeCall(
                            NadFunRouter.initialize,
                            (
                                address(protocolManager),
                                mockBondingCurve,
                                address(tokenRegistry),
                                address(quoteToken),
                                address(0)
                            )
                        )
                    )
                ))
        );

        // 8. Create pair via NadFunFactory
        pair = nadFunFactory.createPair(address(baseToken), address(quoteToken));

        // 9. Setup FeeCollector for baseToken (pretend we're bondingCurve = admin in this test)
        // FeeCollector.setup requires msg.sender == bondingCurve (set as admin in initialize)
        feeCollector.setup(
            pair, address(baseToken), address(quoteToken), CREATOR_FEE_RATE, PROTOCOL_FEE_RATE, PROTOCOL_FEE_RATE
        );

        // 10. Register token in TokenRegistry
        vm.stopPrank();
        vm.prank(admin);
        protocolManager.setOperatorPermission(
            address(this), address(tokenRegistry), TokenRegistry.register.selector, true
        );
        tokenRegistry.register(address(baseToken), pair, address(quoteToken), ITokenRegistry.DexType.UniswapV2);

        // 11. Mock BondingCurve.getCurve to return graduated=true for baseToken
        _mockGraduatedCurve(address(baseToken));

        // 12. Seed initial liquidity directly via NadFunPair
        _seedLiquidity();
    }

    function test_nadFunRouter_buy_exactIn() public {
        uint256 buyAmount = 1 ether;
        _mintQuote(user1, buyAmount);

        vm.startPrank(user1);
        quoteToken.approve(address(nadFunRouter), buyAmount);

        uint256 tokensOut = nadFunRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: buyAmount,
                amountOutMin: 0,
                token: address(baseToken),
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertGt(tokensOut, 0, "Should receive tokens");
        assertEq(baseToken.balanceOf(user1), tokensOut, "User should have received tokens");
    }

    function test_nadFunRouter_sell_exactIn() public {
        // First buy some tokens
        uint256 tokenAmount = _buyTokensForUser(user1, 1 ether);

        vm.startPrank(user1);
        baseToken.approve(address(nadFunRouter), tokenAmount);

        uint256 quoteOut = nadFunRouter.sell(
            INadFunRouter.SellParams({
                amountIn: tokenAmount,
                amountOutMin: 0,
                token: address(baseToken),
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertGt(quoteOut, 0, "Should receive quote tokens");
        assertEq(quoteToken.balanceOf(user1), quoteOut, "User should have received quote");
    }

    function test_nadFunRouter_getAmountOut_buy() public view {
        uint256 amountOut = nadFunRouter.getAmountOut(address(baseToken), 1 ether, true);
        assertGt(amountOut, 0, "getAmountOut buy should return nonzero");
    }

    function test_nadFunRouter_getAmountOut_sell() public {
        // Buy some tokens first to have a meaningful sell
        uint256 tokenAmount = _buyTokensForUser(user1, 1 ether);
        uint256 amountOut = nadFunRouter.getAmountOut(address(baseToken), tokenAmount, false);
        assertGt(amountOut, 0, "getAmountOut sell should return nonzero");
    }

    function test_nadFunRouter_getAmountIn_buy() public view {
        uint256 amountIn = nadFunRouter.getAmountIn(address(baseToken), 100 ether, true);
        assertGt(amountIn, 0, "getAmountIn buy should return nonzero");
    }

    function test_nadFunRouter_getAmountIn_sell() public view {
        uint256 amountIn = nadFunRouter.getAmountIn(address(baseToken), 0.5 ether, false);
        assertGt(amountIn, 0, "getAmountIn sell should return nonzero");
    }

    function test_nadFunRouter_exactOutBuy() public {
        uint256 desiredTokens = 50 ether;
        uint256 maxQuote = 5 ether; // generous max
        _mintQuote(user1, maxQuote);

        vm.startPrank(user1);
        quoteToken.approve(address(nadFunRouter), maxQuote);

        uint256 amountIn = nadFunRouter.exactOutBuy(
            INadFunRouter.ExactOutBuyParams({
                amountInMax: maxQuote,
                amountOut: desiredTokens,
                token: address(baseToken),
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertGt(amountIn, 0, "Should spend some quote");
        assertLe(amountIn, maxQuote, "Should not exceed max");
        assertGe(baseToken.balanceOf(user1), desiredTokens, "Should receive at least desired tokens");
    }

    function test_nadFunRouter_exactOutSell() public {
        // Buy tokens first
        uint256 tokenAmount = _buyTokensForUser(user1, 2 ether);
        uint256 desiredQuote = 0.5 ether;

        vm.startPrank(user1);
        baseToken.approve(address(nadFunRouter), tokenAmount);

        uint256 quoteOut = nadFunRouter.exactOutSell(
            INadFunRouter.ExactOutSellParams({
                amountInMax: tokenAmount,
                amountOut: desiredQuote,
                token: address(baseToken),
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(quoteOut, desiredQuote, "Should receive exact desired quote");
    }

    function test_nadFunRouter_buy_slippageProtection() public {
        uint256 buyAmount = 1 ether;
        _mintQuote(user1, buyAmount);

        vm.startPrank(user1);
        quoteToken.approve(address(nadFunRouter), buyAmount);

        vm.expectRevert(INadFunRouter.InsufficientOutput.selector);
        nadFunRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: buyAmount,
                amountOutMin: type(uint256).max, // impossible min
                token: address(baseToken),
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function test_nadFunRouter_getAmountOut_matchesActualBuy() public {
        uint256 buyAmount = 1 ether;

        // Get predicted output
        uint256 predicted = nadFunRouter.getAmountOut(address(baseToken), buyAmount, true);

        // Execute actual buy
        _mintQuote(user1, buyAmount);
        vm.startPrank(user1);
        quoteToken.approve(address(nadFunRouter), buyAmount);
        uint256 actual = nadFunRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: buyAmount,
                amountOutMin: 0,
                token: address(baseToken),
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(actual, predicted, "Predicted and actual output should match");
    }

    function test_nadFunRouter_getAmountOut_matchesActualSell() public {
        // Buy tokens first
        uint256 tokenAmount = _buyTokensForUser(user1, 1 ether);

        // Get predicted output
        uint256 predicted = nadFunRouter.getAmountOut(address(baseToken), tokenAmount, false);

        // Execute actual sell
        vm.startPrank(user1);
        baseToken.approve(address(nadFunRouter), tokenAmount);
        uint256 actual = nadFunRouter.sell(
            INadFunRouter.SellParams({
                amountIn: tokenAmount,
                amountOutMin: 0,
                token: address(baseToken),
                to: user1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(actual, predicted, "Predicted and actual sell output should match");
    }

    function test_lpManager_addLiquidity() public {
        uint256 tokenAmt = 1000 ether;
        uint256 quoteAmt = 1 ether;

        // Deploy a separate base token and pair for this test
        MockERC20 base2 = new MockERC20("Base2", "M2", 18);
        address pair2 = nadFunFactory.createPair(address(base2), address(quoteToken));

        // Register in TokenRegistry
        vm.startPrank(admin);
        protocolManager.setOperatorPermission(
            address(this), address(tokenRegistry), TokenRegistry.register.selector, true
        );
        tokenRegistry.register(address(base2), pair2, address(quoteToken), ITokenRegistry.DexType.UniswapV2);
        vm.stopPrank();

        // Mint tokens to LPManager
        base2.mint(address(lpManager), tokenAmt);
        quoteToken.mint(address(lpManager), quoteAmt);

        // Grant operator permission for LPManager liquidity actions in this test
        vm.startPrank(admin);
        protocolManager.setOperatorPermission(address(this), address(lpManager), LPManager.addLiquidity.selector, true);
        vm.stopPrank();

        uint256 liquidity = lpManager.addLiquidity(
            address(base2), address(quoteToken), tokenAmt, quoteAmt, ITokenRegistry.DexType.UniswapV2, pair2
        );

        assertGt(liquidity, 0, "Should receive LP tokens");
        assertEq(lpManager.getPair(address(base2)), pair2, "Pair should be recorded");
        assertEq(lpManager.getLiquidity(address(base2), address(this)), liquidity, "Liquidity should be tracked");
    }

    function test_nadFunRouter_pairLevelFee_isApplied() public {
        // With FeeCollector configured (CREATOR_FEE_RATE=100 + PROTOCOL_FEE_RATE=35 = 135bps total),
        // the router forwards the full input to pair.getAmountOut (which applies LP + NadFun fee).
        // We verify by comparing against pair.getAmountOut as the source of truth.
        uint256 buyAmount = 1 ether;

        // Get actual output through NadFunRouter (includes pair-level fee)
        uint256 actualOut = nadFunRouter.getAmountOut(address(baseToken), buyAmount, true);

        // Source of truth: pair.getAmountOut with the full input (no router fee).
        uint256 expectedOut = INadFunPair(pair).getAmountOut(address(quoteToken), buyAmount);
        assertEq(actualOut, expectedOut, "NadFunRouter.getAmountOut should match pair.getAmountOut");

        // With a non-zero NadFun fee configured, the net output must be
        // strictly less than the no-slippage linear price (a cheap, formula-free upper bound).
        (uint112 r0, uint112 r1,) = INadFunPair(pair).getReserves();
        address token0 = INadFunPair(pair).token0();
        (uint256 reserveIn, uint256 reserveOut) =
            address(quoteToken) == token0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 linearUpperBound = (buyAmount * reserveOut) / reserveIn;
        assertLt(actualOut, linearUpperBound, "Output with NadFun fee must be below linear (no-slippage) price");
        assertGt(actualOut, 0, "Output must be positive");
    }

    // Internal Helpers

    function _mintQuote(address to, uint256 amount) internal {
        quoteToken.mint(to, amount);
    }

    /// @dev Buy baseTokens for user via NadFunRouter and return token amount received
    function _buyTokensForUser(address user, uint256 quote) internal returns (uint256 tokenAmount) {
        _mintQuote(user, quote);
        vm.startPrank(user);
        quoteToken.approve(address(nadFunRouter), quote);
        tokenAmount = nadFunRouter.buy(
            INadFunRouter.BuyParams({
                amountIn: quote, amountOutMin: 0, token: address(baseToken), to: user, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    /// @dev Seed initial liquidity into the NadFunPair directly
    function _seedLiquidity() internal {
        baseToken.mint(address(this), INITIAL_TOKEN_LIQ);
        quoteToken.mint(address(this), INITIAL_QUOTE_LIQ);

        baseToken.transfer(pair, INITIAL_TOKEN_LIQ);
        quoteToken.transfer(pair, INITIAL_QUOTE_LIQ);

        INadFunPair(pair).mint(address(this));
    }

    /// @dev Mock BondingCurve.getCurve(token) to return a graduated Curve struct
    function _mockGraduatedCurve(address token) internal {
        IBondingCurve.Curve memory curve = IBondingCurve.Curve({
            token: token,
            creator: address(0),
            quoteToken: address(quoteToken),
            virtualQuoteReserve: 0,
            virtualTokenReserve: 0,
            k: 0,
            minTokenReserve: 0,
            initialQuoteReserve: 0,
            initialTokenReserve: 0,
            createdAtBlock: 0,
            graduated: true,
            creatorFeeRate: 0,
            version: IBondingCurve.CurveVersion.V1,
            dexType: ITokenRegistry.DexType.UniswapV2,
            pair: pair,
            graduateFee: 0
        });

        vm.mockCall(mockBondingCurve, abi.encodeWithSelector(IBondingCurve.getCurve.selector, token), abi.encode(curve));
    }
}
