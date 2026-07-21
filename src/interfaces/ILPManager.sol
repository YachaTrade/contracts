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
    function setV3LiquidityActor(address actor, address factory) external;

    event Allocate(
        address indexed token,
        address indexed pair,
        address indexed caller,
        ITokenRegistry.DexType dexType,
        uint256 tokenIn,
        uint256 quoteIn,
        uint256 liquidity
    );
    event ClaimFee(
        address indexed token, address indexed to, ITokenRegistry.DexType dexType, uint256 amount0, uint256 amount1
    );

    function addLiquidity(
        address token,
        address quoteToken,
        uint256 tokenIn,
        uint256 quoteIn,
        ITokenRegistry.DexType dexType,
        address pair
    ) external returns (uint256 liquidity);

    function claimFees(address token) external returns (uint256 amount0, uint256 amount1);

    /// @notice Get pair address for a token
    function getPair(address token) external view returns (address);

    /// @notice Get caller's LP amount for a token
    function getLiquidity(address token, address caller) external view returns (uint256);
}
