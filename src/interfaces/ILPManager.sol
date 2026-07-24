// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITokenRegistry} from "./ITokenRegistry.sol";

/// @title ILPManager
/// @notice Liquidity management interface used during graduation and LP accounting.

interface ILPManager {
    struct AllocateParams {
        address token;
        uint256 quoteAmount;
        uint256 tokenAmount;
        uint256 virtualQuoteReserve;
        uint256 virtualTokenReserve;
        uint256 graduateFee;
    }

    /// @notice Canonical V3 pool data passed to the direct liquidity actor.
    struct PoolData {
        address pool;
        address token0;
        address token1;
        address quoteToken;
        uint160 sqrtPrice;
        int24 currentTick;
        int24 tickSpacing;
        int24 alignedTick;
        int24 bondingTick;
        bool quoteIsToken0;
    }
    error LegacyLiquidityDisabled();
    function allocate(AllocateParams calldata params) external;
    function increaseLiquidity(address token, uint256 tokenAmount, uint256 quoteAmount) external;
    function getPositions(address token)
        external
        view
        returns (bytes32, int24, int24, uint128, bytes32, int24, int24, uint128);

    /// @notice Returns exact accumulated V3 fees for a launch token's permanent positions.
    /// @dev The launch-token amount has not yet been swapped into quote.
    /// @param token Launch token whose allocated V3 pool is queried.
    /// @return quoteAmount Accumulated fee denominated in the registered quote token.
    /// @return tokenAmount Accumulated fee denominated in the launch token.
    function callStaticGetAccumulatedFees(address token)
        external
        view
        returns (uint256 quoteAmount, uint256 tokenAmount);

    function setV3LiquidityActor(address actor, address factory) external;

    event Allocate(
        address indexed token, address indexed pool, uint256 quoteAmount, uint256 tokenAmount, uint256 timestamp
    );

    event Collect(address indexed token, address indexed pool, uint256 quoteAmount, uint256 timestamp);

    function addLiquidity(
        address token,
        address quoteToken,
        uint256 tokenIn,
        uint256 quoteIn,
        ITokenRegistry.DexType dexType,
        address pair
    ) external returns (uint256 liquidity);

    function claimFees(address token) external returns (uint256 amount0, uint256 amount1);

    function collect(address[] calldata tokens) external;

    /// @notice Get pair address for a token
    function getPair(address token) external view returns (address);

    /// @notice Get caller's LP amount for a token
    function getLiquidity(address token, address caller) external view returns (uint256);
}
