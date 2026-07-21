// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IV3SwapAdapter {
    error CallbackNotConsumed();
    error ExcessiveCallbackAmount(uint256 amountOwed, uint256 amountInMax);
    error ExpiredDeadline();
    error InsufficientOutput(uint256 amountOut, uint256 amountOutMin);
    error InvalidAmountIn();
    error InvalidAmountOut();
    error InvalidBalanceDelta(address token, address account, uint256 requiredBalance, uint256 currentBalance);
    error InvalidCallback();
    error InvalidFactory();
    error InvalidPool();
    error InvalidPriceLimit();
    error InvalidRecipient();
    error InvalidRegistry();
    error InvalidTokenIn();
    error NoActiveSwap();
    error ReentrantCall();

    struct ExactInputParams {
        address token;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOutMin;
        address recipient;
        uint160 sqrtPriceLimitX96;
        uint256 deadline;
    }

    struct ExactOutputParams {
        address token;
        address tokenIn;
        uint256 amountOut;
        uint256 amountInMax;
        address recipient;
        uint160 sqrtPriceLimitX96;
        uint256 deadline;
    }

    function factory() external view returns (address);
    function tokenRegistry() external view returns (address);

    function exactInput(ExactInputParams calldata params) external returns (uint256 amountIn, uint256 amountOut);
    function exactOutput(ExactOutputParams calldata params) external returns (uint256 amountIn, uint256 amountOut);
}
