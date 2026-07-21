// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILPManager} from "./ILPManager.sol";

/// @notice Direct canonical-Uniswap-V3 actor for permanent launch liquidity.
interface IV3LiquidityActor {
    error ExistingPositionFound(address pool);
    error ExcessiveCallbackAmount(uint256 amount0Owed, uint256 amount1Owed, uint256 amount0Max, uint256 amount1Max);
    error InvalidCallbackData();
    error InvalidCallbackPool();
    error InvalidBalanceDelta(address token, address account, uint256 expectedBalance, uint256 actualBalance);
    error InvalidFactory();
    error InvalidOwner();
    error InvalidPool(address pool);
    error InvalidPoolData();
    error InvalidRange(int24 lowerTick, int24 upperTick);
    error LiquidityOverflow(address pool);
    error MintCallbackNotConsumed();
    error NoActiveMint();
    error PositionNotFound(address pool);
    error ReentrantCall();
    error Unauthorized(address caller);
    error UnexpectedCallbackAmount(uint256 amount0Owed, uint256 amount1Owed);
    error UnexpectedCallbackPool(address caller, address expectedPool);
    error UninitializedTick(int24 tick);
    error ZeroLiquidity();

    function owner() external view returns (address);
    function factory() external view returns (address);

    function quoteLiquidityPositions(address pool)
        external
        view
        returns (bytes32 key, int24 lowerTick, int24 upperTick, uint128 liquidity);

    function tokenLiquidityPositions(address pool)
        external
        view
        returns (bytes32 key, int24 lowerTick, int24 upperTick, uint128 liquidity);

    function mint(ILPManager.PoolData calldata poolData, uint256 amount0, uint256 amount1)
        external
        returns (uint256 mint0, uint256 mint1);

    function increase(ILPManager.PoolData calldata poolData, uint256 amount0, uint256 amount1)
        external
        returns (uint256 mint0, uint256 mint1);

    function collectFees(address pool) external returns (uint256 amount0, uint256 amount1);
    function viewFees(address pool) external view returns (uint256 fee0, uint256 fee1);
}
