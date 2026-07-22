// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test suite for BondingCurveAttack.

import {console} from "forge-std/Test.sol";
import {SetUp} from "../SetUp.t.sol";
import {BondingCurve} from "../../src/core/BondingCurve.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {ILPManager} from "../../src/interfaces/ILPManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ReentrantLPManager is ILPManager {
    using SafeERC20 for IERC20;

    BondingCurve public target;
    address public attackToken;
    address public quoteToken;
    bool public attacked;

    constructor(address _target) {
        target = BondingCurve(payable(_target));
    }

    function setAttack(address _attackToken, address _quoteToken) external {
        attackToken = _attackToken;
        quoteToken = _quoteToken;
    }

    function addLiquidity(address, address, uint256, uint256, ITokenRegistry.DexType, address)
        external
        override
        returns (uint256)
    {
        if (!attacked && attackToken != address(0)) {
            attacked = true;
            // Attempt reentrancy: try to buy during graduation
            uint256 balance = IERC20(quoteToken).balanceOf(address(this));
            if (balance > 0) {
                IERC20(quoteToken).forceApprove(address(target), balance);
                try target.buy(address(this), attackToken, balance) {} catch {}
            }
        }
        return 1 ether;
    }

    function claimFees(address) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function collect(address[] calldata) external pure override {}

    function getPair(address) external pure override returns (address) {
        return address(0);
    }

    function getLiquidity(address, address) external pure override returns (uint256) {
        return 0;
    }
    function allocate(AllocateParams calldata) external pure override {}
    function increaseLiquidity(address, uint256, uint256) external pure override {}

    function getPositions(address)
        external
        pure
        override
        returns (bytes32, int24, int24, uint128, bytes32, int24, int24, uint128)
    {
        return (bytes32(0), 0, 0, 0, bytes32(0), 0, 0, 0);
    }
    function setV3LiquidityActor(address, address) external pure override {}

    receive() external payable {}
}

contract BondingCurveAttackTest is SetUp {
    address attacker;
    address vault;
    address token;

    // setUp(): Use default SetUp curve parameters
    function setUp() public override {
        super.setUp();
        attacker = makeAddr("attacker");
        vault = makeAddr("vault");

        vm.startPrank(admin);
        // Grant ROUTER_ROLE to test contract for direct bondingCurve.create() calls
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));
        vm.stopPrank();

        quoteToken.mint(address(this), defaultDeployFee);
        quoteToken.approve(address(bondingCurve), defaultDeployFee);
        (token,) = bondingCurve.create(_params("AttackTestToken", "ATT", keccak256("attackSalt")));

        // Skip anti-sniping period
        vm.warp(block.timestamp + 100 minutes);
        vm.roll(block.number + 10);
    }

    function test_attack_directBuyWithoutTransfer_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        bondingCurve.buy(attacker, token, 1 ether);

        assertEq(IERC20(token).balanceOf(attacker), 0, "Attacker should have zero tokens");
    }

    function test_attack_flashLoanGraduation_penaltyMakesUnprofitable() public {
        address flashAttacker = makeAddr("flashAttacker");

        quoteToken.mint(address(this), defaultDeployFee);
        quoteToken.approve(address(bondingCurve), defaultDeployFee);
        (address freshToken,) = bondingCurve.create(_params("FlashTarget", "FT", keccak256("flashSalt")));

        // Same-block flash buy → max sniping penalty (table[0] = 8000 BPS = 80%).
        IBondingCurve.Curve memory freshCurve = bondingCurve.getCurve(freshToken);
        vm.roll(uint256(freshCurve.createdAtBlock));
        uint256 penalty = bondingCurve.getSnipingPenalty(freshToken);
        assertEq(penalty, 8000, "Penalty should be 80% at creation block");

        // Buy still succeeds (totalFeeRate < BPS), but ~80% of the deposit is captured as
        // sniping fee, making any single-block graduation attempt grossly unprofitable.
        uint256 buyAmount = 700_000 ether;
        quoteToken.mint(flashAttacker, buyAmount);
        vm.prank(flashAttacker);
        quoteToken.approve(address(giwaRouter), buyAmount);
        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);

        vm.prank(flashAttacker);
        uint256 tokenOut = giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 1, token: freshToken, to: flashAttacker, deadline: block.timestamp
            })
        );

        uint256 snipingFee = buyAmount * 8000 / 10000;
        uint256 protocolFee = buyAmount * defaultCurveProtocolFee / 10000;

        assertGt(tokenOut, 0, "buy succeeds even at max sniping penalty");
        assertEq(IERC20(freshToken).balanceOf(flashAttacker), tokenOut, "flash attacker token balance");
        assertEq(quoteToken.balanceOf(feeReceiver), feeReceiverBefore + snipingFee + protocolFee, "fee receiver");

        console.log("Flash loan attack neutered - >=80% of deposit drained to sniping fee");
    }

    function test_attack_lpManagerRebinding_reverts() public {
        ReentrantLPManager reentrantLP = new ReentrantLPManager(address(bondingCurve));
        bytes32 moduleId = keccak256("LP_MANAGER");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IBondingCurve.ModuleAlreadySet.selector, moduleId));
        bondingCurve.setModule(moduleId, address(reentrantLP));
    }

    function test_attack_buyAfterGraduation_reverts() public {
        _graduateTokenLocal(token);

        IBondingCurve.Curve memory info = bondingCurve.getCurve(token);
        assertTrue(info.graduated, "Precondition: token should be graduated");

        quoteToken.mint(address(this), 1 ether);
        quoteToken.approve(address(bondingCurve), 1 ether);
        vm.expectRevert(IBondingCurve.AlreadyGraduated.selector);
        bondingCurve.buy(attacker, token, 1 ether);

        vm.expectRevert(IBondingCurve.AlreadyGraduated.selector);
        bondingCurve.sell(attacker, token, 1 ether);
    }

    function _graduateTokenLocal(address _token) internal {
        uint256 buyAmount = 700_000 ether;
        _mintAndApprove(user1, address(giwaRouter), buyAmount);
        vm.prank(user1);
        giwaRouter.buy(
            IGiwaRouter.BuyParams({
                amountIn: buyAmount, amountOutMin: 1, token: _token, to: user1, deadline: block.timestamp
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
