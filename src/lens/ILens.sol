// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILens
/// @notice Lifecycle-aware quote and bonding-curve summary interface for GIWA integrations.
interface ILens {
    error InvalidDependency();
    error TokenNotFound();
    error QuoteTokenNotAllowed();
    error InvalidCurveConfig();

    function getAmountIn(address token, uint256 amountOut, bool isBuy)
        external
        returns (address router, uint256 amountIn);

    function getAmountOut(address token, uint256 amountIn, bool isBuy)
        external
        returns (address router, uint256 amountOut);

    function isGraduated(address token) external view returns (bool graduated);

    function isLocked(address token) external view returns (bool locked);

    function availableBuyTokens(address token)
        external
        view
        returns (uint256 availableBuyToken, uint256 requiredQuoteAmount);

    function getProgress(address token) external view returns (uint256 progress);

    function getInitialBuyAmountOut(address quoteToken, uint256 quoteIn) external view returns (uint256 tokenOut);
}
