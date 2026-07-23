// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {V3LiquidityActor} from "../../src/actors/V3LiquidityActor.sol";
import {IV3LiquidityActor} from "../../src/interfaces/IV3LiquidityActor.sol";
import {ILPManager} from "../../src/interfaces/ILPManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Factory, MockV3Pool, IMockV3MintCallback} from "../mocks/MockV3Pool.sol";

contract CallbackReentrantToken is ERC20 {
    address public actor;
    bytes4 public observedError;

    constructor() ERC20("Reentrant", "REENTER") {}

    function configure(address actor_) external {
        actor = actor_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        try IMockV3MintCallback(actor).uniswapV3MintCallback(1, 0, bytes("reenter")) {}
        catch (bytes memory reason) {
            if (reason.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 0x20))
                }
                observedError = selector;
            }
        }
        return super.transferFrom(from, to, amount);
    }
}

contract RevertingTransferFromToken is ERC20 {
    error PaymentFailed();

    constructor() ERC20("Reverter", "REVERT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert PaymentFailed();
    }
}

contract SelectiveTaxToken is ERC20 {
    address public taxedSender;
    uint16 public taxBps;

    constructor() ERC20("Selective Tax", "TAX") {}

    function configureTax(address taxedSender_, uint16 taxBps_) external {
        taxedSender = taxedSender_;
        taxBps = taxBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == taxedSender && from != address(0) && to != address(0) && taxBps != 0) {
            uint256 tax = amount * taxBps / 10_000;
            super._update(from, to, amount - tax);
            super._update(from, address(0xdead), tax);
        } else {
            super._update(from, to, amount);
        }
    }
}

interface IActorOwnerReentrant {
    function reenter() external;
}

contract OwnerReentrantToken is ERC20 {
    address public actorOwner;
    bool public attempted;

    constructor() ERC20("Owner Reentrant", "OWNER-REENTER") {}

    function configure(address actorOwner_) external {
        actorOwner = actorOwner_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!attempted) {
            attempted = true;
            IActorOwnerReentrant(actorOwner).reenter();
        }
        return super.transferFrom(from, to, amount);
    }
}

contract ActorOwnerReentrant is IActorOwnerReentrant {
    V3LiquidityActor public actor;
    ILPManager.PoolData private _poolData;
    uint256 private _amount0;
    uint256 private _amount1;
    bytes4 public observedError;

    function configure(V3LiquidityActor actor_) external {
        actor = actor_;
    }

    function startMint(ILPManager.PoolData calldata poolData, uint256 amount0, uint256 amount1) external {
        _poolData = poolData;
        _amount0 = amount0;
        _amount1 = amount1;
        actor.mint(poolData, amount0, amount1);
    }

    function reenter() external {
        try actor.mint(_poolData, _amount0, _amount1) {}
        catch (bytes memory reason) {
            if (reason.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 0x20))
                }
                observedError = selector;
            }
        }
    }
}

contract V3LiquidityActorTest is Test {
    struct PositionSnapshot {
        bytes32 key;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
    }

    uint24 internal constant FEE = 3_000;
    int24 internal constant SPACING = 60;
    uint160 internal constant SQRT_PRICE_X96 = uint160(1 << 96);
    uint256 internal constant AMOUNT = 1_000_000 ether;
    address internal constant ATTACKER = address(0xbad);

    UniswapV3Factory internal realFactory;

    function setUp() public {
        realFactory = new UniswapV3Factory();
    }

    function test_mint_quoteIsToken0_usesContractV3Ranges() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData) = _realPoolData(true);

        (uint256 mint0, uint256 mint1) = actor.mint(poolData, AMOUNT, AMOUNT);

        (bytes32 quoteKey, int24 quoteLower, int24 quoteUpper, uint128 quoteLiquidity) =
            actor.quoteLiquidityPositions(poolData.pool);
        (bytes32 tokenKey, int24 tokenLower, int24 tokenUpper, uint128 tokenLiquidity) =
            actor.tokenLiquidityPositions(poolData.pool);
        assertEq(quoteLower, 60);
        assertEq(quoteUpper, 600);
        assertEq(tokenLower, (TickMath.MIN_TICK / SPACING) * SPACING);
        assertEq(tokenUpper, -60);
        assertEq(quoteKey, keccak256(abi.encodePacked(address(actor), quoteLower, quoteUpper)));
        assertEq(tokenKey, keccak256(abi.encodePacked(address(actor), tokenLower, tokenUpper)));
        assertGt(quoteLiquidity, 0);
        assertGt(tokenLiquidity, 0);
        assertEq(_poolLiquidity(poolData.pool, quoteKey), quoteLiquidity);
        assertEq(_poolLiquidity(poolData.pool, tokenKey), tokenLiquidity);
        assertGt(mint0, 0);
        assertGt(mint1, 0);
        assertLe(mint0, AMOUNT);
        assertLe(mint1, AMOUNT);
    }

    function test_mint_quoteIsToken1_usesContractV3Ranges() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData) = _realPoolData(false);

        (uint256 mint0, uint256 mint1) = actor.mint(poolData, AMOUNT, AMOUNT);

        (bytes32 quoteKey, int24 quoteLower, int24 quoteUpper, uint128 quoteLiquidity) =
            actor.quoteLiquidityPositions(poolData.pool);
        (bytes32 tokenKey, int24 tokenLower, int24 tokenUpper, uint128 tokenLiquidity) =
            actor.tokenLiquidityPositions(poolData.pool);
        assertEq(quoteLower, -600);
        assertEq(quoteUpper, -60);
        assertEq(tokenLower, 60);
        assertEq(tokenUpper, (TickMath.MAX_TICK / SPACING) * SPACING);
        assertEq(quoteKey, keccak256(abi.encodePacked(address(actor), quoteLower, quoteUpper)));
        assertEq(tokenKey, keccak256(abi.encodePacked(address(actor), tokenLower, tokenUpper)));
        assertGt(quoteLiquidity, 0);
        assertGt(tokenLiquidity, 0);
        assertEq(_poolLiquidity(poolData.pool, quoteKey), quoteLiquidity);
        assertEq(_poolLiquidity(poolData.pool, tokenKey), tokenLiquidity);
        assertGt(mint0, 0);
        assertGt(mint1, 0);
    }

    function test_mint_revertsWhenPositionAlreadyExists() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData) = _realPoolData(true);
        actor.mint(poolData, AMOUNT, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IV3LiquidityActor.ExistingPositionFound.selector, poolData.pool));
        actor.mint(poolData, AMOUNT, AMOUNT);
    }

    function test_mintCallback_revertsForUnexpectedPool() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(true);
        MockV3Pool wrongCaller =
            new MockV3Pool(pool.factory(), poolData.token0, poolData.token1, FEE, SPACING, SQRT_PRICE_X96, 0);
        pool.setAttack(MockV3Pool.MintAttack.WrongCaller, address(wrongCaller));

        vm.expectRevert(
            abi.encodeWithSelector(
                IV3LiquidityActor.UnexpectedCallbackPool.selector, address(wrongCaller), address(pool)
            )
        );
        actor.mint(poolData, AMOUNT, AMOUNT);
    }

    function test_mintCallback_revertsForExcessiveAmount() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(true);
        pool.setAttack(MockV3Pool.MintAttack.ExcessiveAmount, address(0));

        vm.expectPartialRevert(IV3LiquidityActor.ExcessiveCallbackAmount.selector);
        actor.mint(poolData, AMOUNT, AMOUNT);
    }

    function test_mintCallback_revertsWhenAmount1ExceedsIndependentMaximum() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(false);
        pool.setAttack(MockV3Pool.MintAttack.ExcessiveAmount, address(0));

        vm.expectPartialRevert(IV3LiquidityActor.ExcessiveCallbackAmount.selector);
        actor.mint(poolData, AMOUNT, AMOUNT);
    }

    function test_collectFees_pokesAndCollectsBothPositions() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(true);
        actor.mint(poolData, AMOUNT, AMOUNT);
        (, int24 quoteLower, int24 quoteUpper,) = actor.quoteLiquidityPositions(poolData.pool);
        (, int24 tokenLower, int24 tokenUpper,) = actor.tokenLiquidityPositions(poolData.pool);
        pool.setActorCollection(address(actor), quoteLower, quoteUpper, 7, 11);
        pool.setActorCollection(address(actor), tokenLower, tokenUpper, 13, 17);
        MockERC20(poolData.token0).mint(address(pool), 20);
        MockERC20(poolData.token1).mint(address(pool), 28);
        MockERC20(poolData.token0).mint(address(actor), 101);
        MockERC20(poolData.token1).mint(address(actor), 103);
        uint256 balance0Before = MockERC20(poolData.token0).balanceOf(address(this));
        uint256 balance1Before = MockERC20(poolData.token1).balanceOf(address(this));

        (uint256 amount0, uint256 amount1) = actor.collectFees(poolData.pool);

        assertEq(amount0, 20);
        assertEq(amount1, 28);
        assertEq(pool.burnCalls(), 2);
        assertEq(pool.collectCalls(), 2);
        assertEq(MockERC20(poolData.token0).balanceOf(address(this)) - balance0Before, amount0);
        assertEq(MockERC20(poolData.token1).balanceOf(address(this)) - balance1Before, amount1);
        assertEq(MockERC20(poolData.token0).balanceOf(address(actor)), 101);
        assertEq(MockERC20(poolData.token1).balanceOf(address(actor)), 103);
    }

    function test_collectFees_revertsAndRollsBackWhenPoolShortCreditsActor() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool, SelectiveTaxToken taxToken) =
            _selectiveTaxPoolData();
        _setTaxCollection(actor, poolData, pool, address(taxToken), 100);
        taxToken.mint(address(pool), 100);
        taxToken.mint(address(actor), 200);
        taxToken.configureTax(address(pool), 1_000);
        uint256 ownerBalanceBefore = taxToken.balanceOf(address(this));
        uint256 poolBalanceBefore = taxToken.balanceOf(address(pool));

        (bool success, bytes memory revertData) =
            address(actor).call(abi.encodeWithSelector(actor.collectFees.selector, poolData.pool));

        assertFalse(success);
        assertEq(
            revertData,
            abi.encodeWithSelector(
                IV3LiquidityActor.InvalidBalanceDelta.selector,
                address(taxToken),
                address(actor),
                uint256(300),
                uint256(290)
            )
        );
        assertEq(taxToken.balanceOf(address(actor)), 200);
        assertEq(taxToken.balanceOf(address(this)), ownerBalanceBefore);
        assertEq(taxToken.balanceOf(address(pool)), poolBalanceBefore);
        assertEq(pool.burnCalls(), 0);
        assertEq(pool.collectCalls(), 0);

        taxToken.configureTax(address(0), 0);
        (uint256 amount0, uint256 amount1) = actor.collectFees(poolData.pool);
        assertEq(address(taxToken) == poolData.token0 ? amount0 : amount1, 100);
    }

    function test_collectFees_revertsAndRollsBackWhenOwnerReceivesTaxedAmount() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool, SelectiveTaxToken taxToken) =
            _selectiveTaxPoolData();
        _setTaxCollection(actor, poolData, pool, address(taxToken), 100);
        taxToken.mint(address(pool), 100);
        taxToken.mint(address(actor), 200);
        taxToken.configureTax(address(actor), 1_000);
        uint256 ownerBalanceBefore = taxToken.balanceOf(address(this));
        uint256 poolBalanceBefore = taxToken.balanceOf(address(pool));

        (bool success, bytes memory revertData) =
            address(actor).call(abi.encodeWithSelector(actor.collectFees.selector, poolData.pool));

        assertFalse(success);
        assertEq(
            revertData,
            abi.encodeWithSelector(
                IV3LiquidityActor.InvalidBalanceDelta.selector,
                address(taxToken),
                address(this),
                ownerBalanceBefore + 100,
                ownerBalanceBefore + 90
            )
        );
        assertEq(taxToken.balanceOf(address(actor)), 200);
        assertEq(taxToken.balanceOf(address(this)), ownerBalanceBefore);
        assertEq(taxToken.balanceOf(address(pool)), poolBalanceBefore);
        assertEq(pool.burnCalls(), 0);
        assertEq(pool.collectCalls(), 0);

        taxToken.configureTax(address(0), 0);
        (uint256 amount0, uint256 amount1) = actor.collectFees(poolData.pool);
        assertEq(address(taxToken) == poolData.token0 ? amount0 : amount1, 100);
    }

    function test_collectFees_zeroFeesPreservesBalances() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(true);
        actor.mint(poolData, AMOUNT, AMOUNT);
        MockERC20(poolData.token0).mint(address(actor), 101);
        MockERC20(poolData.token1).mint(address(actor), 103);
        uint256 ownerBalance0Before = MockERC20(poolData.token0).balanceOf(address(this));
        uint256 ownerBalance1Before = MockERC20(poolData.token1).balanceOf(address(this));

        (uint256 amount0, uint256 amount1) = actor.collectFees(poolData.pool);

        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(MockERC20(poolData.token0).balanceOf(address(actor)), 101);
        assertEq(MockERC20(poolData.token1).balanceOf(address(actor)), 103);
        assertEq(MockERC20(poolData.token0).balanceOf(address(this)), ownerBalance0Before);
        assertEq(MockERC20(poolData.token1).balanceOf(address(this)), ownerBalance1Before);
        assertEq(pool.burnCalls(), 2);
        assertEq(pool.collectCalls(), 2);
    }

    function test_increase_addsLiquidityWithoutChangingRanges() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData) = _realPoolData(false);
        actor.mint(poolData, AMOUNT, AMOUNT);
        PositionSnapshot memory quoteBefore = _quotePosition(actor, poolData.pool);
        PositionSnapshot memory tokenBefore = _tokenPosition(actor, poolData.pool);

        actor.increase(poolData, AMOUNT, AMOUNT);

        PositionSnapshot memory quoteAfter = _quotePosition(actor, poolData.pool);
        PositionSnapshot memory tokenAfter = _tokenPosition(actor, poolData.pool);
        assertEq(quoteAfter.key, quoteBefore.key);
        assertEq(quoteAfter.lowerTick, quoteBefore.lowerTick);
        assertEq(quoteAfter.upperTick, quoteBefore.upperTick);
        assertGt(quoteAfter.liquidity, quoteBefore.liquidity);
        assertEq(tokenAfter.key, tokenBefore.key);
        assertEq(tokenAfter.lowerTick, tokenBefore.lowerTick);
        assertEq(tokenAfter.upperTick, tokenBefore.upperTick);
        assertGt(tokenAfter.liquidity, tokenBefore.liquidity);
    }

    function test_actorExposesNoPrincipalRemovalSelector() public {
        (V3LiquidityActor actor,) = _realPoolData(true);
        bytes4[5] memory forbidden = [
            bytes4(keccak256("burn(address,uint128)")),
            bytes4(keccak256("decrease(address,uint128)")),
            bytes4(keccak256("decreaseLiquidity(address,uint128)")),
            bytes4(keccak256("withdrawPrincipal(address)")),
            bytes4(keccak256("changeRanges(address,int24,int24)"))
        ];

        for (uint256 i; i < forbidden.length; ++i) {
            (bool success,) = address(actor).call(abi.encodeWithSelector(forbidden[i]));
            assertFalse(success);
        }
    }

    function test_constructor_rejectsZeroOrCodeLessOwner() public {
        vm.expectRevert(IV3LiquidityActor.InvalidOwner.selector);
        new V3LiquidityActor(address(0), address(realFactory));
        vm.expectRevert(IV3LiquidityActor.InvalidOwner.selector);
        new V3LiquidityActor(address(0x1234), address(realFactory));
    }

    function test_constructor_rejectsZeroOrCodeLessFactory() public {
        vm.expectRevert(IV3LiquidityActor.InvalidFactory.selector);
        new V3LiquidityActor(address(this), address(0));
        vm.expectRevert(IV3LiquidityActor.InvalidFactory.selector);
        new V3LiquidityActor(address(this), address(0x1234));
    }

    function test_onlyOwner_revertsForMintIncreaseAndCollect() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData) = _realPoolData(true);

        vm.startPrank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IV3LiquidityActor.Unauthorized.selector, ATTACKER));
        actor.mint(poolData, AMOUNT, AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IV3LiquidityActor.Unauthorized.selector, ATTACKER));
        actor.increase(poolData, AMOUNT, AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IV3LiquidityActor.Unauthorized.selector, ATTACKER));
        actor.collectFees(poolData.pool);
        vm.stopPrank();
    }

    function test_mint_revertsForZeroLiquidity() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData,,) = _mockPoolData(true);

        vm.expectRevert(IV3LiquidityActor.ZeroLiquidity.selector);
        actor.mint(poolData, 0, 0);
    }

    function test_mint_revertsForInvalidQuoteRange() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData,,) = _mockPoolData(true);
        poolData.bondingTick = SPACING;

        vm.expectRevert(abi.encodeWithSelector(IV3LiquidityActor.InvalidRange.selector, SPACING, SPACING));
        actor.mint(poolData, AMOUNT, AMOUNT);
    }

    function test_increaseAndFeeFunctions_revertForMissingPositions() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData,,) = _mockPoolData(true);

        vm.expectRevert(abi.encodeWithSelector(IV3LiquidityActor.PositionNotFound.selector, poolData.pool));
        actor.increase(poolData, AMOUNT, AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IV3LiquidityActor.PositionNotFound.selector, poolData.pool));
        actor.collectFees(poolData.pool);
        vm.expectRevert(abi.encodeWithSelector(IV3LiquidityActor.PositionNotFound.selector, poolData.pool));
        actor.viewFees(poolData.pool);
    }

    function test_mintCallback_revertsWithoutActiveContext() public {
        (V3LiquidityActor actor,,,) = _mockPoolData(true);

        vm.expectRevert(IV3LiquidityActor.NoActiveMint.selector);
        actor.uniswapV3MintCallback(1, 0, bytes("forged"));
    }

    function test_mintCallback_revertsForWrongFactoryFeeTokenOrderAndCanonicalPool() public {
        MockV3Pool.MintAttack[4] memory attacks = [
            MockV3Pool.MintAttack.WrongFactory,
            MockV3Pool.MintAttack.WrongFee,
            MockV3Pool.MintAttack.WrongTokenOrder,
            MockV3Pool.MintAttack.WrongCanonicalPool
        ];
        for (uint256 i; i < attacks.length; ++i) {
            (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(true);
            pool.setAttack(attacks[i], address(0));
            vm.expectRevert(IV3LiquidityActor.InvalidCallbackPool.selector);
            actor.mint(poolData, AMOUNT, AMOUNT);
        }
    }

    function test_mintCallback_revertsForForgedData() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(true);
        pool.setAttack(MockV3Pool.MintAttack.ForgedData, address(0));

        vm.expectRevert(IV3LiquidityActor.InvalidCallbackData.selector);
        actor.mint(poolData, AMOUNT, AMOUNT);
    }

    function test_mintCallback_revertsForUnexpectedNonzeroSide() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(true);
        pool.setAttack(MockV3Pool.MintAttack.UnexpectedSide, address(0));

        vm.expectPartialRevert(IV3LiquidityActor.UnexpectedCallbackAmount.selector);
        actor.mint(poolData, AMOUNT, AMOUNT);
    }

    function test_mintCallback_replayRevertsAndRollsBackPayment() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(true);
        pool.setAttack(MockV3Pool.MintAttack.Replay, address(0));
        uint256 ownerBalanceBefore = MockERC20(poolData.token0).balanceOf(address(this));

        vm.expectRevert(IV3LiquidityActor.NoActiveMint.selector);
        actor.mint(poolData, AMOUNT, AMOUNT);

        assertEq(MockERC20(poolData.token0).balanceOf(address(this)), ownerBalanceBefore);
        (bytes32 quoteKey,,,) = actor.quoteLiquidityPositions(poolData.pool);
        assertEq(quoteKey, bytes32(0));
    }

    function test_tokenInducedReentrancySeesDeletedContext() public {
        MockV3Factory mockFactory = new MockV3Factory();
        CallbackReentrantToken reentrant = new CallbackReentrantToken();
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        (address token0, address token1) = address(reentrant) < address(other)
            ? (address(reentrant), address(other))
            : (address(other), address(reentrant));
        MockV3Pool pool = new MockV3Pool(address(mockFactory), token0, token1, FEE, SPACING, SQRT_PRICE_X96, 0);
        mockFactory.setPool(token0, token1, FEE, address(pool));
        V3LiquidityActor actor = new V3LiquidityActor(address(this), address(mockFactory));
        reentrant.configure(address(actor));
        reentrant.mint(address(this), AMOUNT);
        other.mint(address(this), AMOUNT);
        reentrant.approve(address(actor), type(uint256).max);
        other.approve(address(actor), type(uint256).max);
        ILPManager.PoolData memory poolData = _poolData(address(pool), token0, token1, token0, true, 600);

        actor.mint(poolData, AMOUNT, AMOUNT);

        assertEq(reentrant.observedError(), IV3LiquidityActor.NoActiveMint.selector);
    }

    function test_tokenCannotReenterOwnerMintWhilePaymentIsInProgress() public {
        MockV3Factory mockFactory = new MockV3Factory();
        OwnerReentrantToken reentrant = new OwnerReentrantToken();
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        (address token0, address token1) = address(reentrant) < address(other)
            ? (address(reentrant), address(other))
            : (address(other), address(reentrant));
        MockV3Pool pool = new MockV3Pool(address(mockFactory), token0, token1, FEE, SPACING, SQRT_PRICE_X96, 0);
        mockFactory.setPool(token0, token1, FEE, address(pool));
        ActorOwnerReentrant actorOwner = new ActorOwnerReentrant();
        V3LiquidityActor actor = new V3LiquidityActor(address(actorOwner), address(mockFactory));
        actorOwner.configure(actor);
        reentrant.configure(address(actorOwner));
        reentrant.mint(address(actorOwner), AMOUNT);
        other.mint(address(actorOwner), AMOUNT);
        vm.startPrank(address(actorOwner));
        reentrant.approve(address(actor), type(uint256).max);
        other.approve(address(actor), type(uint256).max);
        vm.stopPrank();
        bool quoteIsToken0 = token0 == address(reentrant);
        ILPManager.PoolData memory poolData = _poolData(
            address(pool), token0, token1, address(reentrant), quoteIsToken0, quoteIsToken0 ? int24(600) : int24(-600)
        );

        actorOwner.startMint(poolData, AMOUNT, AMOUNT);

        assertEq(actorOwner.observedError(), bytes4(keccak256("ReentrantCall()")));
    }

    function test_failedPaymentRollsBackContextAndPositions() public {
        MockV3Factory mockFactory = new MockV3Factory();
        RevertingTransferFromToken reverter = new RevertingTransferFromToken();
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        (address token0, address token1) = address(reverter) < address(other)
            ? (address(reverter), address(other))
            : (address(other), address(reverter));
        MockV3Pool pool = new MockV3Pool(address(mockFactory), token0, token1, FEE, SPACING, SQRT_PRICE_X96, 0);
        mockFactory.setPool(token0, token1, FEE, address(pool));
        V3LiquidityActor actor = new V3LiquidityActor(address(this), address(mockFactory));
        reverter.mint(address(this), AMOUNT);
        other.mint(address(this), AMOUNT);
        reverter.approve(address(actor), type(uint256).max);
        other.approve(address(actor), type(uint256).max);
        bool quoteIsToken0 = token0 == address(reverter);
        ILPManager.PoolData memory poolData = _poolData(
            address(pool), token0, token1, address(reverter), quoteIsToken0, quoteIsToken0 ? int24(600) : int24(-600)
        );

        vm.expectRevert(RevertingTransferFromToken.PaymentFailed.selector);
        actor.mint(poolData, AMOUNT, AMOUNT);

        (bytes32 quoteKey,,,) = actor.quoteLiquidityPositions(address(pool));
        (bytes32 tokenKey,,,) = actor.tokenLiquidityPositions(address(pool));
        assertEq(quoteKey, bytes32(0));
        assertEq(tokenKey, bytes32(0));
        vm.expectRevert(IV3LiquidityActor.NoActiveMint.selector);
        actor.uniswapV3MintCallback(1, 0, bytes("after failure"));
    }

    function test_increase_revertsOnUint128LiquidityOverflow() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData,,) = _mockPoolData(true);
        uint256 largeQuote = uint256(type(uint128).max) / 64;
        actor.mint(poolData, largeQuote, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IV3LiquidityActor.LiquidityOverflow.selector, poolData.pool));
        actor.increase(poolData, largeQuote, AMOUNT);
    }

    function test_viewFees_sumsTokensOwedAndFeeGrowthForBothPositionsWithoutMutation() public {
        (V3LiquidityActor actor, ILPManager.PoolData memory poolData, MockV3Pool pool,) = _mockPoolData(true);
        actor.mint(poolData, AMOUNT, AMOUNT);
        PositionSnapshot memory quotePosition = _quotePosition(actor, poolData.pool);
        PositionSnapshot memory tokenPosition = _tokenPosition(actor, poolData.pool);

        pool.setPositionFees(quotePosition.key, 3, 5);
        pool.setPositionFees(tokenPosition.key, 7, 11);

        uint256 q128 = uint256(1) << 128;
        pool.setTickFeeGrowthOutside(quotePosition.lowerTick, q128, 2 * q128);
        pool.setTickFeeGrowthOutside(quotePosition.upperTick, 0, 0);
        pool.setTickFeeGrowthOutside(tokenPosition.lowerTick, 0, 0);
        pool.setTickFeeGrowthOutside(tokenPosition.upperTick, 3 * q128, 4 * q128);

        (uint256 amount0, uint256 amount1) = actor.viewFees(poolData.pool);

        assertEq(amount0, 10 + uint256(quotePosition.liquidity) + 3 * uint256(tokenPosition.liquidity));
        assertEq(amount1, 16 + 2 * uint256(quotePosition.liquidity) + 4 * uint256(tokenPosition.liquidity));
        assertEq(pool.burnCalls(), 0);
        assertEq(pool.collectCalls(), 0);

        (uint256 secondAmount0, uint256 secondAmount1) = actor.viewFees(poolData.pool);
        assertEq(secondAmount0, amount0);
        assertEq(secondAmount1, amount1);
        assertEq(pool.burnCalls(), 0);
        assertEq(pool.collectCalls(), 0);
    }

    function _realPoolData(bool quoteIsToken0)
        internal
        returns (V3LiquidityActor actor, ILPManager.PoolData memory poolData)
    {
        MockERC20 first = new MockERC20("First", "FIRST", 18);
        MockERC20 second = new MockERC20("Second", "SECOND", 18);
        (address token0, address token1) =
            address(first) < address(second) ? (address(first), address(second)) : (address(second), address(first));
        address quoteToken = quoteIsToken0 ? token0 : token1;
        address pool = realFactory.createPool(token0, token1, FEE);
        IUniswapV3Pool(pool).initialize(SQRT_PRICE_X96);
        actor = new V3LiquidityActor(address(this), address(realFactory));
        MockERC20(token0).mint(address(this), AMOUNT * 4);
        MockERC20(token1).mint(address(this), AMOUNT * 4);
        MockERC20(token0).approve(address(actor), type(uint256).max);
        MockERC20(token1).approve(address(actor), type(uint256).max);
        poolData = _poolData(pool, token0, token1, quoteToken, quoteIsToken0, quoteIsToken0 ? int24(600) : int24(-600));
    }

    function _mockPoolData(bool quoteIsToken0)
        internal
        returns (
            V3LiquidityActor actor,
            ILPManager.PoolData memory poolData,
            MockV3Pool pool,
            MockV3Factory mockFactory
        )
    {
        MockERC20 first = new MockERC20("First", "FIRST", 18);
        MockERC20 second = new MockERC20("Second", "SECOND", 18);
        (address token0, address token1) =
            address(first) < address(second) ? (address(first), address(second)) : (address(second), address(first));
        mockFactory = new MockV3Factory();
        pool = new MockV3Pool(address(mockFactory), token0, token1, FEE, SPACING, SQRT_PRICE_X96, 0);
        mockFactory.setPool(token0, token1, FEE, address(pool));
        actor = new V3LiquidityActor(address(this), address(mockFactory));
        MockERC20(token0).mint(address(this), type(uint128).max);
        MockERC20(token1).mint(address(this), type(uint128).max);
        MockERC20(token0).approve(address(actor), type(uint256).max);
        MockERC20(token1).approve(address(actor), type(uint256).max);
        address quoteToken = quoteIsToken0 ? token0 : token1;
        poolData = _poolData(
            address(pool), token0, token1, quoteToken, quoteIsToken0, quoteIsToken0 ? int24(600) : int24(-600)
        );
    }

    function _selectiveTaxPoolData()
        internal
        returns (
            V3LiquidityActor actor,
            ILPManager.PoolData memory poolData,
            MockV3Pool pool,
            SelectiveTaxToken taxToken
        )
    {
        MockV3Factory mockFactory = new MockV3Factory();
        taxToken = new SelectiveTaxToken();
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        (address token0, address token1) = address(taxToken) < address(other)
            ? (address(taxToken), address(other))
            : (address(other), address(taxToken));
        pool = new MockV3Pool(address(mockFactory), token0, token1, FEE, SPACING, SQRT_PRICE_X96, 0);
        mockFactory.setPool(token0, token1, FEE, address(pool));
        actor = new V3LiquidityActor(address(this), address(mockFactory));
        taxToken.mint(address(this), AMOUNT);
        other.mint(address(this), AMOUNT);
        taxToken.approve(address(actor), type(uint256).max);
        other.approve(address(actor), type(uint256).max);
        poolData = _poolData(address(pool), token0, token1, token0, true, 600);
        actor.mint(poolData, AMOUNT, AMOUNT);
    }

    function _setTaxCollection(
        V3LiquidityActor actor,
        ILPManager.PoolData memory poolData,
        MockV3Pool pool,
        address taxToken,
        uint128 amount
    ) internal {
        (, int24 quoteLower, int24 quoteUpper,) = actor.quoteLiquidityPositions(poolData.pool);
        pool.setActorCollection(
            address(actor),
            quoteLower,
            quoteUpper,
            taxToken == poolData.token0 ? amount : 0,
            taxToken == poolData.token1 ? amount : 0
        );
    }

    function _poolData(
        address pool,
        address token0,
        address token1,
        address quoteToken,
        bool quoteIsToken0,
        int24 bondingTick
    ) internal pure returns (ILPManager.PoolData memory poolData) {
        poolData = ILPManager.PoolData({
            pool: pool,
            token0: token0,
            token1: token1,
            quoteToken: quoteToken,
            sqrtPrice: SQRT_PRICE_X96,
            currentTick: 0,
            tickSpacing: SPACING,
            alignedTick: 0,
            bondingTick: bondingTick,
            quoteIsToken0: quoteIsToken0
        });
    }

    function _poolLiquidity(address pool, bytes32 key) internal view returns (uint128 liquidity) {
        (liquidity,,,,) = IUniswapV3Pool(pool).positions(key);
    }

    function _quotePosition(V3LiquidityActor actor, address pool)
        internal
        view
        returns (PositionSnapshot memory position)
    {
        (position.key, position.lowerTick, position.upperTick, position.liquidity) = actor.quoteLiquidityPositions(pool);
    }

    function _tokenPosition(V3LiquidityActor actor, address pool)
        internal
        view
        returns (PositionSnapshot memory position)
    {
        (position.key, position.lowerTick, position.upperTick, position.liquidity) = actor.tokenLiquidityPositions(pool);
    }
}
