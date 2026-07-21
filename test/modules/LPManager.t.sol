// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for LPManager.

import {SetUp} from "../SetUp.t.sol";
import {console} from "forge-std/Test.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

contract LPManagerTest is SetUp {
    MockERC20 token;
    address pair;
    address bondingCurveAddr;

    uint256 constant TOKEN_AMOUNT = 100_000 ether;
    uint256 constant QUOTE_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        bondingCurveAddr = address(bondingCurve);

        // Create a mock token for LP tests (separate from bonding curve tokens)
        token = new MockERC20("Graduated Token", "GRAD", 18);

        // Deploy pair via NadFunFactory
        pair = nadFunFactory.createPair(address(token), address(quoteToken));

        // Register the token in TokenRegistry so getDexType works
        vm.prank(admin);
        protocolManager.setOperatorPermission(
            address(this), address(tokenRegistry), ITokenRegistry.register.selector, true
        );
        tokenRegistry.register(address(token), pair, address(quoteToken), ITokenRegistry.DexType.UniswapV2);
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    function test_addLiquidityV2() public {
        // liquidity = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
        uint256 expectedLiquidity = _sqrt(TOKEN_AMOUNT * QUOTE_AMOUNT) - 1000;

        uint256 liquidity = _addLiquidity();

        assertEq(liquidity, expectedLiquidity, "Liquidity should match V2 formula: sqrt(a*b) - MINIMUM_LIQUIDITY");

        address storedPair = lpManager.getPair(address(token));
        assertEq(storedPair, pair, "Stored pair should match");

        uint256 storedLiquidity = lpManager.getLiquidity(address(token), bondingCurveAddr);
        assertEq(storedLiquidity, expectedLiquidity, "Stored liquidity should match expected");

        console.log("Liquidity minted:", liquidity);
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    function test_addLiquidity_lpHeldByManager() public {
        uint256 expectedLiquidity = _sqrt(TOKEN_AMOUNT * QUOTE_AMOUNT) - 1000;

        _addLiquidity();

        uint256 lpManagerBalance = IERC20(pair).balanceOf(address(lpManager));

        assertEq(lpManagerBalance, expectedLiquidity, "LPManager should hold exact expected LP tokens");

        console.log("LP held by LPManager:", lpManagerBalance);
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    function test_addLiquidity_revertsUnauthorized() public {
        address attacker = makeAddr("attacker");

        // Transfer tokens to LPManager
        token.mint(address(lpManager), TOKEN_AMOUNT);
        quoteToken.mint(address(lpManager), QUOTE_AMOUNT);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        lpManager.addLiquidity(
            address(token), address(quoteToken), TOKEN_AMOUNT, QUOTE_AMOUNT, ITokenRegistry.DexType.UniswapV2, pair
        );
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    function test_addLiquidity_accumulatesLiquidity() public {
        _addLiquidity();

        uint256 firstLiquidity = lpManager.getLiquidity(address(token), bondingCurveAddr);

        // Add more liquidity
        token.mint(address(lpManager), TOKEN_AMOUNT);
        quoteToken.mint(address(lpManager), QUOTE_AMOUNT);

        vm.prank(bondingCurveAddr);
        uint256 secondLiquidity = lpManager.addLiquidity(
            address(token), address(quoteToken), TOKEN_AMOUNT, QUOTE_AMOUNT, ITokenRegistry.DexType.UniswapV2, pair
        );

        uint256 totalLiquidity = lpManager.getLiquidity(address(token), bondingCurveAddr);
        assertEq(totalLiquidity, firstLiquidity + secondLiquidity, "Liquidity should accumulate");
    }

    // -------------------------------------------------------
    // getPair / getLiquidity
    // -------------------------------------------------------

    function test_getPair() public {
        _addLiquidity();

        address storedPair = lpManager.getPair(address(token));
        assertEq(storedPair, pair, "pair should match");
    }

    function test_getPair_uninitialized() public view {
        address storedPair = lpManager.getPair(address(0x1234));
        assertEq(storedPair, address(0), "Uninitialized pair should be zero");
    }

    function test_getLiquidity() public {
        uint256 expectedLiquidity = _sqrt(TOKEN_AMOUNT * QUOTE_AMOUNT) - 1000;

        _addLiquidity();

        uint256 liquidity = lpManager.getLiquidity(address(token), bondingCurveAddr);
        assertEq(liquidity, expectedLiquidity, "Liquidity should match V2 formula for bondingCurve");

        uint256 otherLiquidity = lpManager.getLiquidity(address(token), address(0x1234));
        assertEq(otherLiquidity, 0, "Liquidity for other address should be zero");
    }

    // -------------------------------------------------------
    // Helper
    // -------------------------------------------------------

    function _addLiquidity() internal returns (uint256 liquidity) {
        // Simulate BondingCurve transferring tokens and quote to LPManager
        token.mint(address(lpManager), TOKEN_AMOUNT);
        quoteToken.mint(address(lpManager), QUOTE_AMOUNT);

        vm.prank(bondingCurveAddr);
        liquidity = lpManager.addLiquidity(
            address(token), address(quoteToken), TOKEN_AMOUNT, QUOTE_AMOUNT, ITokenRegistry.DexType.UniswapV2, pair
        );
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    receive() external payable {}
}
