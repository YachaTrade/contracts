// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {QuoterV2} from "@uniswap/v3-periphery/contracts/lens/QuoterV2.sol";

import {SetUp} from "../SetUp.t.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IWrappedNative} from "../../src/interfaces/IWrappedNative.sol";
import {MockERC20Permit} from "../mocks/MockERC20Permit.sol";

contract GiwaRouterNativeQuoteForkTest is SetUp {
    using SafeERC20 for IERC20;

    uint24 private constant FEE_TIER = 500;
    uint128 private constant LIQUIDITY = 1_000_000 ether;
    uint256 private constant LIQUIDITY_BALANCE = 1_000_000 ether;

    IWrappedNative private deployedWeth;
    MockERC20Permit private launchToken;
    address private pool;

    function setUp() public override {
        if (!vm.envOr("RUN_FORK_TESTS", false)) {
            vm.skip(true, "Set RUN_FORK_TESTS=true to run fork tests");
        }

        vm.createSelectFork(vm.envString("RPC_URL"));
        super.setUp();
        deployedWeth = IWrappedNative(vm.envAddress("WETH"));

        QuoterV2 deployedWethQuoter = new QuoterV2(address(v3Factory), address(deployedWeth));
        GiwaRouter implementation = new GiwaRouter();
        giwaRouter = GiwaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            GiwaRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(deployedWeth),
                                address(v3SwapAdapter),
                                address(deployedWethQuoter)
                            )
                        )
                    )
                ))
        );

        vm.startPrank(admin);
        protocolManager.addQuoteToken(
            address(deployedWeth),
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            defaultDeployFee,
            defaultGraduateFee,
            defaultCurveProtocolFee,
            defaultDexProtocolFee
        );
        protocolManager.setV3QuoteConfig(address(deployedWeth), FEE_TIER, 0);
        protocolManager.setOperatorPermission(
            address(this), address(tokenRegistry), TokenRegistry.registerV3.selector, true
        );
        vm.stopPrank();

        launchToken = new MockERC20Permit("Fork Native Launch", "FNL", 18);
        pool = v3Factory.createPool(address(launchToken), address(deployedWeth), FEE_TIER);
        IUniswapV3Pool(pool).initialize(uint160(1 << 96));

        launchToken.mint(address(this), LIQUIDITY_BALANCE);
        vm.deal(address(this), LIQUIDITY_BALANCE);
        deployedWeth.deposit{value: LIQUIDITY_BALANCE}();
        IUniswapV3Pool(pool).mint(address(this), -600, 600, LIQUIDITY, bytes(""));

        tokenRegistry.registerV3(address(launchToken), pool, address(deployedWeth), FEE_TIER);
        IBondingCurve.Curve memory curve;
        curve.token = address(launchToken);
        curve.quoteToken = address(deployedWeth);
        curve.graduated = true;
        curve.dexType = ITokenRegistry.DexType.UniswapV3;
        curve.pair = pool;
        vm.mockCall(
            address(bondingCurve), abi.encodeCall(IBondingCurve.getCurve, (address(launchToken))), abi.encode(curve)
        );
    }

    function test_nativeGraduatedRoundTrip_usesDeployedWeth() public {
        uint256 nativeIn = 10 ether;
        vm.deal(user1, nativeIn);

        vm.prank(user1);
        uint256 tokenOut = giwaRouter.buyWithNative{value: nativeIn}(
            IGiwaRouter.BuyWithNativeParams({
                amountOutMin: 1, token: address(launchToken), to: user1, deadline: block.timestamp
            })
        );
        assertGt(tokenOut, 0);

        vm.prank(user1);
        launchToken.approve(address(giwaRouter), tokenOut);
        uint256 nativeBefore = user1.balance;
        vm.prank(user1);
        uint256 nativeOut = giwaRouter.sellToNative(
            IGiwaRouter.SellToNativeParams({
                amountIn: tokenOut, amountOutMin: 1, token: address(launchToken), to: user1, deadline: block.timestamp
            })
        );

        assertGt(nativeOut, 0);
        assertEq(user1.balance - nativeBefore, nativeOut);
        assertEq(deployedWeth.balanceOf(address(giwaRouter)), 0);
        assertEq(address(giwaRouter).balance, 0);
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        assertEq(msg.sender, pool);
        IUniswapV3Pool callbackPool = IUniswapV3Pool(msg.sender);
        if (amount0Owed != 0) IERC20(callbackPool.token0()).safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed != 0) IERC20(callbackPool.token1()).safeTransfer(msg.sender, amount1Owed);
    }
}
