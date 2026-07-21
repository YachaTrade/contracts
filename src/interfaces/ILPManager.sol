// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITokenRegistry} from "./ITokenRegistry.sol";

/// @title ILPManager
/// @notice Liquidity management interface used during graduation and LP accounting.

interface ILPManager {
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
