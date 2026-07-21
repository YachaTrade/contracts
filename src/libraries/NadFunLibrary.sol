// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INadFunFactory} from "../dex/interfaces/INadFunFactory.sol";
import {INadFunPair} from "../dex/interfaces/INadFunPair.sol";

/// @title NadFunLibrary
/// @notice UniswapV2Library equivalent for NadFun. Resolves pairs via `factory.getPair`
///         because NadFunFactory deploys EIP-1167 clones (the CREATE2 init-code-hash
///         `pairFor` trick from UniswapV2Library is invalid here).
library NadFunLibrary {
    error IdenticalAddresses();
    error ZeroAddress();
    error InsufficientAmount();
    error InsufficientLiquidity();

    /// @notice Sort tokens ascending; reverts on identical or zero token0.
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    /// @notice Pair address for (tokenA, tokenB) — storage read, NOT CREATE2 computation.
    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        pair = INadFunFactory(factory).getPair(tokenA, tokenB);
    }

    /// @notice Reserves ordered to match (tokenA, tokenB) call order.
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        address pair = INadFunFactory(factory).getPair(tokenA, tokenB);
        (uint112 reserve0, uint112 reserve1,) = INadFunPair(pair).getReserves();
        (reserveA, reserveB) =
            tokenA == token0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
    }

    /// @notice Optimal counterpart amount given reserves: amountB = amountA * reserveB / reserveA.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = amountA * reserveB / reserveA;
    }
}
