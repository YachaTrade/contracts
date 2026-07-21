// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3MintCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import {ILPManager} from "../interfaces/ILPManager.sol";
import {IV3LiquidityActor} from "../interfaces/IV3LiquidityActor.sol";

/// @notice Owns the protocol's two permanent, one-sided positions in each launch pool.
contract V3LiquidityActor is IV3LiquidityActor, IUniswapV3MintCallback {
    using SafeERC20 for IERC20;

    struct Position {
        bytes32 key;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
    }

    struct ActiveMint {
        address pool;
        address token0;
        address token1;
        uint24 fee;
        uint256 amount0Max;
        uint256 amount1Max;
        bytes32 dataHash;
    }

    struct MintCallbackData {
        address pool;
        address token0;
        address token1;
        uint24 fee;
        uint256 nonce;
    }

    struct RangeMint {
        uint256 amount0Max;
        uint256 amount1Max;
        uint128 liquidity;
    }

    struct CollectSnapshot {
        address token0;
        address token1;
        uint256 actorBalance0;
        uint256 actorBalance1;
        uint256 ownerBalance0;
        uint256 ownerBalance1;
    }

    address public immutable override owner;
    address public immutable override factory;

    mapping(address pool => Position) public override quoteLiquidityPositions;
    mapping(address pool => Position) public override tokenLiquidityPositions;

    ActiveMint private _activeMint;
    uint256 private _mintNonce;
    bool private _entered;

    constructor(address owner_, address factory_) {
        if (owner_ == address(0) || owner_.code.length == 0) revert InvalidOwner();
        if (factory_ == address(0) || factory_.code.length == 0) revert InvalidFactory();
        owner = owner_;
        factory = factory_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    /// @inheritdoc IV3LiquidityActor
    function mint(ILPManager.PoolData calldata poolData, uint256 amount0, uint256 amount1)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256 mint0, uint256 mint1)
    {
        uint24 poolFee = _validatePoolData(poolData);
        if (
            quoteLiquidityPositions[poolData.pool].key != bytes32(0)
                || tokenLiquidityPositions[poolData.pool].key != bytes32(0)
        ) revert ExistingPositionFound(poolData.pool);

        // Quote Liquidity Position - provides quote liquidity (users buy token with quote).
        {
            int24 quoteLower =
                poolData.quoteIsToken0 ? poolData.alignedTick + poolData.tickSpacing : poolData.bondingTick;
            int24 quoteUpper =
                poolData.quoteIsToken0 ? poolData.bondingTick : poolData.alignedTick - poolData.tickSpacing;
            _validateRange(quoteLower, quoteUpper, poolData.tickSpacing);

            uint256 quoteAmount0 = poolData.quoteIsToken0 ? amount0 : 0;
            uint256 quoteAmount1 = poolData.quoteIsToken0 ? 0 : amount1;
            uint128 liquidity =
                _liquidityForRange(poolData.sqrtPrice, quoteLower, quoteUpper, quoteAmount0, quoteAmount1);

            (mint0, mint1) =
                _mintForRange(poolData, poolFee, quoteLower, quoteUpper, liquidity, quoteAmount0, quoteAmount1);
            quoteLiquidityPositions[poolData.pool] = Position({
                key: keccak256(abi.encodePacked(address(this), quoteLower, quoteUpper)),
                lowerTick: quoteLower,
                upperTick: quoteUpper,
                liquidity: liquidity
            });
        }

        // Token Liquidity Position - provides token liquidity (users sell token for quote).
        {
            int24 tokenLower = poolData.quoteIsToken0
                ? (TickMath.MIN_TICK / poolData.tickSpacing) * poolData.tickSpacing
                : poolData.alignedTick + poolData.tickSpacing;
            int24 tokenUpper = poolData.quoteIsToken0
                ? poolData.alignedTick - poolData.tickSpacing
                : (TickMath.MAX_TICK / poolData.tickSpacing) * poolData.tickSpacing;
            _validateRange(tokenLower, tokenUpper, poolData.tickSpacing);

            uint256 tokenAmount0 = poolData.quoteIsToken0 ? 0 : amount0;
            uint256 tokenAmount1 = poolData.quoteIsToken0 ? amount1 : 0;
            uint128 liquidity =
                _liquidityForRange(poolData.sqrtPrice, tokenLower, tokenUpper, tokenAmount0, tokenAmount1);

            (uint256 mintedAmount0, uint256 mintedAmount1) =
                _mintForRange(poolData, poolFee, tokenLower, tokenUpper, liquidity, tokenAmount0, tokenAmount1);
            mint0 += mintedAmount0;
            mint1 += mintedAmount1;
            tokenLiquidityPositions[poolData.pool] = Position({
                key: keccak256(abi.encodePacked(address(this), tokenLower, tokenUpper)),
                lowerTick: tokenLower,
                upperTick: tokenUpper,
                liquidity: liquidity
            });
        }
    }

    /// @inheritdoc IV3LiquidityActor
    function increase(ILPManager.PoolData calldata poolData, uint256 amount0, uint256 amount1)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256 mint0, uint256 mint1)
    {
        uint24 poolFee = _validatePoolData(poolData);
        Position storage quotePosition = quoteLiquidityPositions[poolData.pool];
        Position storage tokenPosition = tokenLiquidityPositions[poolData.pool];
        _requirePositions(poolData.pool, quotePosition, tokenPosition);

        RangeMint memory quoteMint = _rangeMint(poolData, quotePosition, true, amount0, amount1);
        RangeMint memory tokenMint = _rangeMint(poolData, tokenPosition, false, amount0, amount1);
        if (
            quoteMint.liquidity > type(uint128).max - quotePosition.liquidity
                || tokenMint.liquidity > type(uint128).max - tokenPosition.liquidity
        ) revert LiquidityOverflow(poolData.pool);

        (mint0, mint1) = _increasePosition(poolData, poolFee, quotePosition, quoteMint);
        (uint256 mintedAmount0, uint256 mintedAmount1) = _increasePosition(poolData, poolFee, tokenPosition, tokenMint);
        mint0 += mintedAmount0;
        mint1 += mintedAmount1;
    }

    /// @inheritdoc IV3LiquidityActor
    function collectFees(address pool)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage quotePosition = quoteLiquidityPositions[pool];
        Position storage tokenPosition = tokenLiquidityPositions[pool];
        _requirePositions(pool, quotePosition, tokenPosition);
        CollectSnapshot memory snapshot = _collectSnapshot(pool);

        (amount0, amount1) = _collectForPosition(pool, quotePosition);
        (uint256 collected0, uint256 collected1) = _collectForPosition(pool, tokenPosition);
        amount0 += collected0;
        amount1 += collected1;

        _requireBalanceIncrease(snapshot.token0, address(this), snapshot.actorBalance0, amount0);
        _requireBalanceIncrease(snapshot.token1, address(this), snapshot.actorBalance1, amount1);

        if (amount0 != 0) IERC20(snapshot.token0).safeTransfer(owner, amount0);
        if (amount1 != 0) IERC20(snapshot.token1).safeTransfer(owner, amount1);

        _requireExactBalance(snapshot.token0, address(this), snapshot.actorBalance0);
        _requireExactBalance(snapshot.token1, address(this), snapshot.actorBalance1);
        _requireBalanceIncrease(snapshot.token0, owner, snapshot.ownerBalance0, amount0);
        _requireBalanceIncrease(snapshot.token1, owner, snapshot.ownerBalance1, amount1);
    }

    /// @inheritdoc IV3LiquidityActor
    function viewFees(address pool) external view override returns (uint256 fee0, uint256 fee1) {
        Position storage quotePosition = quoteLiquidityPositions[pool];
        Position storage tokenPosition = tokenLiquidityPositions[pool];
        _requirePositions(pool, quotePosition, tokenPosition);

        (uint256 quoteAmount0, uint256 quoteAmount1) = _viewForPosition(pool, quotePosition);
        (uint256 tokenAmount0, uint256 tokenAmount1) = _viewForPosition(pool, tokenPosition);
        unchecked {
            fee0 = quoteAmount0 + tokenAmount0;
            fee1 = quoteAmount1 + tokenAmount1;
        }
    }

    /// @inheritdoc IUniswapV3MintCallback
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        ActiveMint memory activeMint = _activeMint;
        if (activeMint.pool == address(0)) revert NoActiveMint();
        if (msg.sender != activeMint.pool) revert UnexpectedCallbackPool(msg.sender, activeMint.pool);
        if (keccak256(data) != activeMint.dataHash) revert InvalidCallbackData();

        MintCallbackData memory callbackData = abi.decode(data, (MintCallbackData));
        if (
            callbackData.pool != activeMint.pool || callbackData.token0 != activeMint.token0
                || callbackData.token1 != activeMint.token1 || callbackData.fee != activeMint.fee
        ) revert InvalidCallbackData();

        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        if (
            pool.factory() != factory || pool.token0() != activeMint.token0 || pool.token1() != activeMint.token1
                || pool.fee() != activeMint.fee
                || IUniswapV3Factory(factory).getPool(activeMint.token0, activeMint.token1, activeMint.fee)
                    != msg.sender
        ) revert InvalidCallbackPool();

        if (
            (activeMint.amount0Max == 0 && amount0Owed != 0) || (activeMint.amount1Max == 0 && amount1Owed != 0)
                || (activeMint.amount0Max != 0 && amount0Owed == 0) || (activeMint.amount1Max != 0 && amount1Owed == 0)
        ) revert UnexpectedCallbackAmount(amount0Owed, amount1Owed);
        if (amount0Owed > activeMint.amount0Max || amount1Owed > activeMint.amount1Max) {
            revert ExcessiveCallbackAmount(amount0Owed, amount1Owed, activeMint.amount0Max, activeMint.amount1Max);
        }

        delete _activeMint;

        if (amount0Owed != 0) IERC20(activeMint.token0).safeTransferFrom(owner, msg.sender, amount0Owed);
        if (amount1Owed != 0) IERC20(activeMint.token1).safeTransferFrom(owner, msg.sender, amount1Owed);
    }

    function _validatePoolData(ILPManager.PoolData calldata poolData) private view returns (uint24 poolFee) {
        if (
            poolData.pool == address(0) || poolData.pool.code.length == 0 || poolData.token0 == address(0)
                || poolData.token1 == address(0) || poolData.token0 >= poolData.token1
                || poolData.token0.code.length == 0 || poolData.token1.code.length == 0
        ) revert InvalidPool(poolData.pool);
        if (poolData.tickSpacing <= 0) revert InvalidPoolData();

        IUniswapV3Pool pool = IUniswapV3Pool(poolData.pool);
        poolFee = pool.fee();
        if (
            pool.factory() != factory || pool.token0() != poolData.token0 || pool.token1() != poolData.token1
                || pool.tickSpacing() != poolData.tickSpacing
                || IUniswapV3Factory(factory).getPool(poolData.token0, poolData.token1, poolFee) != poolData.pool
        ) revert InvalidPool(poolData.pool);

        (uint160 sqrtPrice, int24 currentTick,,,,,) = pool.slot0();
        if (
            sqrtPrice != poolData.sqrtPrice || currentTick != poolData.currentTick
                || sqrtPrice <= TickMath.MIN_SQRT_RATIO || sqrtPrice >= TickMath.MAX_SQRT_RATIO
                || poolData.alignedTick != (currentTick / poolData.tickSpacing) * poolData.tickSpacing
                || (poolData.quoteToken != poolData.token0 && poolData.quoteToken != poolData.token1)
                || poolData.quoteIsToken0 != (poolData.quoteToken == poolData.token0)
        ) revert InvalidPoolData();
    }

    function _validateRange(int24 lowerTick, int24 upperTick, int24 tickSpacing) private pure {
        if (
            lowerTick >= upperTick || lowerTick < TickMath.MIN_TICK || upperTick > TickMath.MAX_TICK
                || lowerTick % tickSpacing != 0 || upperTick % tickSpacing != 0
        ) revert InvalidRange(lowerTick, upperTick);
    }

    function _requirePositions(address pool, Position storage quotePosition, Position storage tokenPosition)
        private
        view
    {
        if (quotePosition.key == bytes32(0) || tokenPosition.key == bytes32(0)) revert PositionNotFound(pool);
    }

    function _liquidityForRange(uint160 sqrtPrice, int24 lowerTick, int24 upperTick, uint256 amount0, uint256 amount1)
        private
        pure
        returns (uint128 liquidity)
    {
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtRatioAtTick(lowerTick), TickMath.getSqrtRatioAtTick(upperTick), amount0, amount1
        );
        if (liquidity == 0) revert ZeroLiquidity();
    }

    function _rangeMint(
        ILPManager.PoolData calldata poolData,
        Position storage position,
        bool quotePosition,
        uint256 amount0,
        uint256 amount1
    ) private view returns (RangeMint memory rangeMint) {
        rangeMint.amount0Max = poolData.quoteIsToken0 == quotePosition ? amount0 : 0;
        rangeMint.amount1Max = poolData.quoteIsToken0 == quotePosition ? 0 : amount1;
        rangeMint.liquidity = _liquidityForRange(
            poolData.sqrtPrice, position.lowerTick, position.upperTick, rangeMint.amount0Max, rangeMint.amount1Max
        );
    }

    function _increasePosition(
        ILPManager.PoolData calldata poolData,
        uint24 poolFee,
        Position storage position,
        RangeMint memory rangeMint
    ) private returns (uint256 mint0, uint256 mint1) {
        (mint0, mint1) = _mintForRange(
            poolData,
            poolFee,
            position.lowerTick,
            position.upperTick,
            rangeMint.liquidity,
            rangeMint.amount0Max,
            rangeMint.amount1Max
        );
        position.liquidity += rangeMint.liquidity;
    }

    function _mintForRange(
        ILPManager.PoolData calldata poolData,
        uint24 poolFee,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) private returns (uint256 mint0, uint256 mint1) {
        MintCallbackData memory callbackData = MintCallbackData({
            pool: poolData.pool, token0: poolData.token0, token1: poolData.token1, fee: poolFee, nonce: ++_mintNonce
        });
        bytes memory data = abi.encode(callbackData);
        _activeMint = ActiveMint({
            pool: poolData.pool,
            token0: poolData.token0,
            token1: poolData.token1,
            fee: poolFee,
            amount0Max: amount0Max,
            amount1Max: amount1Max,
            dataHash: keccak256(data)
        });

        (mint0, mint1) = IUniswapV3Pool(poolData.pool).mint(address(this), lowerTick, upperTick, liquidity, data);
        if (_activeMint.pool != address(0)) revert MintCallbackNotConsumed();
        if (mint0 > amount0Max || mint1 > amount1Max) {
            revert ExcessiveCallbackAmount(mint0, mint1, amount0Max, amount1Max);
        }
        if (
            (amount0Max == 0 && mint0 != 0) || (amount1Max == 0 && mint1 != 0) || (amount0Max != 0 && mint0 == 0)
                || (amount1Max != 0 && mint1 == 0)
        ) revert UnexpectedCallbackAmount(mint0, mint1);
    }

    function _collectForPosition(address pool, Position storage position)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        IUniswapV3Pool(pool).burn(position.lowerTick, position.upperTick, 0);
        (amount0, amount1) = IUniswapV3Pool(pool)
            .collect(address(this), position.lowerTick, position.upperTick, type(uint128).max, type(uint128).max);
    }

    function _collectSnapshot(address pool) private view returns (CollectSnapshot memory snapshot) {
        if (pool == address(0) || pool.code.length == 0) revert InvalidPool(pool);
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        snapshot.token0 = v3Pool.token0();
        snapshot.token1 = v3Pool.token1();
        uint24 poolFee = v3Pool.fee();
        if (
            v3Pool.factory() != factory || snapshot.token0 == address(0) || snapshot.token1 == address(0)
                || snapshot.token0 >= snapshot.token1 || snapshot.token0.code.length == 0
                || snapshot.token1.code.length == 0
                || IUniswapV3Factory(factory).getPool(snapshot.token0, snapshot.token1, poolFee) != pool
        ) revert InvalidPool(pool);

        snapshot.actorBalance0 = IERC20(snapshot.token0).balanceOf(address(this));
        snapshot.actorBalance1 = IERC20(snapshot.token1).balanceOf(address(this));
        snapshot.ownerBalance0 = IERC20(snapshot.token0).balanceOf(owner);
        snapshot.ownerBalance1 = IERC20(snapshot.token1).balanceOf(owner);
    }

    function _requireBalanceIncrease(address token, address account, uint256 balanceBefore, uint256 expectedIncrease)
        private
        view
    {
        uint256 actualBalance = IERC20(token).balanceOf(account);
        if (expectedIncrease > type(uint256).max - balanceBefore) {
            revert InvalidBalanceDelta(token, account, type(uint256).max, actualBalance);
        }
        uint256 expectedBalance = balanceBefore + expectedIncrease;
        if (actualBalance != expectedBalance) {
            revert InvalidBalanceDelta(token, account, expectedBalance, actualBalance);
        }
    }

    function _requireExactBalance(address token, address account, uint256 expectedBalance) private view {
        uint256 actualBalance = IERC20(token).balanceOf(account);
        if (actualBalance != expectedBalance) {
            revert InvalidBalanceDelta(token, account, expectedBalance, actualBalance);
        }
    }

    function _viewForPosition(address pool, Position storage position) private view returns (uint256, uint256) {
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        ) = IUniswapV3Pool(pool).positions(position.key);
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            _getFeeGrowthInside(pool, position.lowerTick, position.upperTick);
        unchecked {
            tokensOwed0 += _mulX128(liquidity, feeGrowthInside0X128 - feeGrowthInside0LastX128, false);
            tokensOwed1 += _mulX128(liquidity, feeGrowthInside1X128 - feeGrowthInside1LastX128, false);
        }
        return (tokensOwed0, tokensOwed1);
    }

    function _getFeeGrowthInside(address pool, int24 lowerTick, int24 upperTick)
        private
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        (, int24 currentTick,,,,,) = v3Pool.slot0();
        uint256 feeGrowthGlobal0X128 = v3Pool.feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1X128 = v3Pool.feeGrowthGlobal1X128();
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,, bool lowerInitialized) =
            v3Pool.ticks(lowerTick);
        if (!lowerInitialized) revert UninitializedTick(lowerTick);
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,, bool upperInitialized) =
            v3Pool.ticks(upperTick);
        if (!upperInitialized) revert UninitializedTick(upperTick);

        unchecked {
            if (currentTick < lowerTick) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (currentTick >= upperTick) {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        }
    }

    function _mulX128(uint128 a, uint256 b, bool roundUp) private pure returns (uint256 result) {
        (uint256 bottom, uint256 top) = _mul512(a, b);
        uint256 modmax = 1 << 128;
        assembly {
            result := add(add(shr(128, bottom), shl(128, top)), and(roundUp, gt(mod(bottom, modmax), 0)))
        }
    }

    function _mul512(uint256 a, uint256 b) private pure returns (uint256 result0, uint256 result1) {
        assembly {
            let mm := mulmod(a, b, not(0))
            result0 := mul(a, b)
            result1 := sub(sub(mm, result0), lt(mm, result0))
        }
    }
}
