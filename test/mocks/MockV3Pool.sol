// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMockV3MintCallback {
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

contract MockV3Factory {
    mapping(bytes32 key => address pool) private _pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool) {
        pool = _pools[_key(tokenA, tokenB, fee)];
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

contract MockV3Pool {
    enum MintAttack {
        None,
        WrongFactory,
        WrongFee,
        WrongTokenOrder,
        WrongCanonicalPool,
        ForgedData,
        ExcessiveAmount,
        UnexpectedSide,
        Replay,
        WrongCaller
    }

    struct PositionState {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    struct Collection {
        uint128 amount0;
        uint128 amount1;
    }

    address public factory;
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint160 public sqrtPriceX96;
    int24 public currentTick;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    MintAttack public attack;
    address public alternateCaller;
    uint256 public burnCalls;
    uint256 public collectCalls;

    mapping(bytes32 key => PositionState state) private _positions;
    mapping(bytes32 key => Collection amounts) private _collections;
    mapping(int24 tick => bool initialized) private _initializedTicks;

    constructor(
        address factory_,
        address token0_,
        address token1_,
        uint24 fee_,
        int24 tickSpacing_,
        uint160 sqrtPriceX96_,
        int24 currentTick_
    ) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        sqrtPriceX96 = sqrtPriceX96_;
        currentTick = currentTick_;
    }

    function setAttack(MintAttack attack_, address alternateCaller_) external {
        attack = attack_;
        alternateCaller = alternateCaller_;
    }

    function setCollection(int24 lowerTick, int24 upperTick, uint128 amount0, uint128 amount1) external {
        _collections[_positionKey(msg.sender, lowerTick, upperTick)] = Collection(amount0, amount1);
    }

    function setActorCollection(address actor, int24 lowerTick, int24 upperTick, uint128 amount0, uint128 amount1)
        external
    {
        _collections[_positionKey(actor, lowerTick, upperTick)] = Collection(amount0, amount1);
    }

    function setPositionFees(bytes32 key, uint128 amount0, uint128 amount1) external {
        _positions[key].tokensOwed0 = amount0;
        _positions[key].tokensOwed1 = amount1;
    }

    function setFeeGrowth(uint256 feeGrowth0X128, uint256 feeGrowth1X128) external {
        feeGrowthGlobal0X128 = feeGrowth0X128;
        feeGrowthGlobal1X128 = feeGrowth1X128;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, currentTick, 0, 1, 1, 0, true);
    }

    function mint(address recipient, int24 lowerTick, int24 upperTick, uint128 liquidity, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        bytes memory callbackData = data;
        bool token0Side = lowerTick > currentTick;
        amount0 = token0Side ? 1 : 0;
        amount1 = token0Side ? 0 : 1;

        if (attack == MintAttack.WrongFactory) {
            factory = address(0xdead);
        } else if (attack == MintAttack.WrongFee) {
            ++fee;
        } else if (attack == MintAttack.WrongTokenOrder) {
            (token0, token1) = (token1, token0);
        } else if (attack == MintAttack.WrongCanonicalPool) {
            MockV3Factory(factory).setPool(token0, token1, fee, address(0xdead));
        } else if (attack == MintAttack.ForgedData) {
            callbackData = abi.encode(address(0xdead));
        } else if (attack == MintAttack.ExcessiveAmount) {
            amount0 = token0Side ? type(uint256).max : 0;
            amount1 = token0Side ? 0 : type(uint256).max;
        } else if (attack == MintAttack.UnexpectedSide) {
            amount1 = token0Side ? 1 : amount1;
            amount0 = token0Side ? amount0 : 1;
        }

        if (attack == MintAttack.WrongCaller) {
            MockV3Pool(alternateCaller).invokeCallback(recipient, amount0, amount1, callbackData);
        } else {
            IMockV3MintCallback(recipient).uniswapV3MintCallback(amount0, amount1, callbackData);
        }

        if (attack == MintAttack.Replay) {
            IMockV3MintCallback(recipient).uniswapV3MintCallback(amount0, amount1, callbackData);
        }

        bytes32 key = _positionKey(recipient, lowerTick, upperTick);
        _positions[key].liquidity += liquidity;
        _initializedTicks[lowerTick] = true;
        _initializedTicks[upperTick] = true;
    }

    function invokeCallback(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external {
        IMockV3MintCallback(recipient).uniswapV3MintCallback(amount0, amount1, data);
    }

    function burn(int24, int24, uint128 liquidity) external returns (uint256 amount0, uint256 amount1) {
        require(liquidity == 0, "positive burn forbidden in actor test");
        ++burnCalls;
    }

    function collect(address recipient, int24 lowerTick, int24 upperTick, uint128, uint128)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        ++collectCalls;
        bytes32 key = _positionKey(msg.sender, lowerTick, upperTick);
        Collection memory amounts = _collections[key];
        delete _collections[key];
        amount0 = amounts.amount0;
        amount1 = amounts.amount1;
        if (amount0 != 0) IERC20(token0).transfer(recipient, amount0);
        if (amount1 != 0) IERC20(token1).transfer(recipient, amount1);
    }

    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        PositionState memory state = _positions[key];
        return (
            state.liquidity,
            state.feeGrowthInside0LastX128,
            state.feeGrowthInside1LastX128,
            state.tokensOwed0,
            state.tokensOwed1
        );
    }

    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        )
    {
        initialized = _initializedTicks[tick];
    }

    function _positionKey(address positionOwner, int24 lowerTick, int24 upperTick) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(positionOwner, lowerTick, upperTick));
    }
}
