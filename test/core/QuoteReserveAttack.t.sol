// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for QuoteReserveAttack.

import {console} from "forge-std/Test.sol";
import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract QuoteReserveAttackTest is SetUp {
    address victim;
    address attacker;
    address vault;

    address tokenA; // victim's curve
    address tokenB; // attacker's target curve

    function setUp() public override {
        super.setUp();
        victim = makeAddr("victim");
        attacker = makeAddr("attacker");
        vault = makeAddr("vault");

        // Grant ROUTER_ROLE to test contract for direct bondingCurve.create() calls
        bytes32 routerRole = bondingCurve.ROUTER_ROLE();
        vm.prank(admin);
        bondingCurve.grantRole(routerRole, address(this));

        quoteToken.mint(address(this), defaultDeployFee);
        quoteToken.approve(address(bondingCurve), defaultDeployFee);
        (tokenA,) = bondingCurve.create(_params("VictimToken", "VT", keccak256("victimSalt")));
        quoteToken.mint(address(this), defaultDeployFee);
        quoteToken.approve(address(bondingCurve), defaultDeployFee);
        (tokenB,) = bondingCurve.create(_params("AttackerTarget", "AT", keccak256("attackerSalt")));

        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    function test_attack_stealFromOtherCurve_blocked() public {
        uint256 depositAmount = 10_000 ether;
        _buyOnCurve(victim, tokenA, depositAmount);

        uint256 bcBalance = quoteToken.balanceOf(address(bondingCurve));
        assertGt(bcBalance, 0, "BondingCurve should hold quote from CurveA");
        console.log("BondingCurve quote balance after victim buy:", bcBalance);

        vm.prank(attacker);
        vm.expectRevert();
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: 1 ether, amountOutMin: 1, token: tokenB, to: attacker, deadline: block.timestamp
            })
        );

        assertEq(IERC20(tokenB).balanceOf(attacker), 0, "Attacker should have zero tokens");

        uint256 bcBalanceAfter = quoteToken.balanceOf(address(bondingCurve));
        assertEq(bcBalanceAfter, bcBalance, "BondingCurve balance should be unchanged");
    }

    function test_legitimate_buy_still_works() public {
        _buyOnCurve(victim, tokenA, 10 ether);

        uint256 buyAmount = 5_000 ether;
        uint256 tokensOut = _buyOnCurve(attacker, tokenB, buyAmount);

        assertGt(tokensOut, 0, "Legitimate buyer should receive tokens");
        assertGt(IERC20(tokenB).balanceOf(attacker), 0, "Buyer should have token balance");
    }

    function test_attack_partialDeposit_blocked() public {
        _buyOnCurve(victim, tokenA, 10 ether);

        quoteToken.mint(attacker, 1_000 ether);
        vm.prank(attacker);
        quoteToken.transfer(address(bondingCurve), 1_000 ether);

        uint256 expectedFromOneMon = bondingCurve.getAmountOut(tokenB, 1_000 ether, true);
        uint256 tokensOut = _buyOnCurve(attacker, tokenB, 1_000 ether);

        assertEq(tokensOut, expectedFromOneMon, "Donation must not increase the declared buy input");
        assertGt(tokensOut, 0, "Attacker should get some tokens for legitimate deposit");
    }

    function test_sell_maintains_reserve_integrity() public {
        uint256 tokensOut = _buyOnCurve(victim, tokenA, 10_000 ether);

        uint256 sellAmount = tokensOut / 2;
        _sellOnCurve(victim, tokenA, sellAmount);

        uint256 bcBalance = quoteToken.balanceOf(address(bondingCurve));
        vm.prank(attacker);
        vm.expectRevert();
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: 1 ether, amountOutMin: 1, token: tokenB, to: attacker, deadline: block.timestamp
            })
        );
        assertEq(quoteToken.balanceOf(address(bondingCurve)), bcBalance, "failed cross-curve buy changes reserves");
    }

    function test_multiple_curves_isolation() public {
        _buyOnCurve(victim, tokenA, 5_000 ether);

        _buyOnCurve(attacker, tokenB, 3_000 ether);

        address thief = makeAddr("thief");
        quoteToken.mint(address(this), defaultDeployFee);
        quoteToken.approve(address(bondingCurve), defaultDeployFee);
        (address tokenC,) = bondingCurve.create(_params("ThiefToken", "TH", keccak256("thiefSalt")));
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);

        vm.prank(thief);
        vm.expectRevert();
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: 1 ether, amountOutMin: 1, token: tokenC, to: thief, deadline: block.timestamp
            })
        );
    }

    function _params(string memory name, string memory symbol, bytes32 salt)
        internal
        view
        returns (IBondingCurve.CreateTokenParams memory params)
    {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] =
            IBondingCurve.VaultAllocation({vault: address(creatorFeeVault), bps: 10000, setupData: abi.encode(vault)});
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
}
