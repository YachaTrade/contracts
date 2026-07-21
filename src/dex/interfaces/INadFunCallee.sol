// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface INadFunCallee {
    function nadFunCall(address sender, uint256 amount0Out, uint256 amount1Out, bytes calldata data) external;
}
