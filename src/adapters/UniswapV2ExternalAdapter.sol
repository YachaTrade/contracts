// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UniswapV2ExternalAdapter — IDexAdapter for an external Uniswap V2 pair.
/// @notice Stateless. Push pattern: caller transfers tokenIn to the adapter, adapter forwards to the
///         caller-supplied pair. The pair is admin-fixed in DividendVault, so no factory/getPair here.
///         Used for whitelisted external ERC20 dividend tokens (e.g. USDT/USDC/WNATIVE).
contract UniswapV2ExternalAdapter is IDexAdapter {
    using SafeERC20 for IERC20;

    error NoPair();
    error NotSupported();
    error TokenMismatch();

    /// @inheritdoc IDexAdapter
    function swap(address pair, address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata)
        external
        returns (uint256 amountOut)
    {
        if (pair == address(0)) revert NoPair();

        // Guard against a misconfigured route whose pair does not contain both tokens in the
        // expected direction — otherwise the wrong output token would be swapped out and credited.
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        if (!((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0))) {
            revert TokenMismatch();
        }

        IERC20(tokenIn).safeTransfer(pair, amountIn);
        amountOut = _getAmountOut(pair, tokenIn, amountIn);

        if (tokenIn == token0) {
            IUniswapV2Pair(pair).swap(0, amountOut, to, "");
        } else {
            IUniswapV2Pair(pair).swap(amountOut, 0, to, "");
        }
    }

    /// @inheritdoc IDexAdapter
    function getAmountOut(address pair, address tokenIn, uint256 amountIn) external view returns (uint256) {
        return _getAmountOut(pair, tokenIn, amountIn);
    }

    function _getAmountOut(address pair, address tokenIn, uint256 amountIn) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 reserveIn, uint256 reserveOut) =
            tokenIn == token0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    // ─── Unused IDexAdapter members (DividendVault never calls these) ───

    /// @inheritdoc IDexAdapter
    function getAmountIn(address, address, uint256) external pure returns (uint256) {
        revert NotSupported();
    }

    /// @inheritdoc IDexAdapter
    function addLiquidity(address, address, address, uint256, uint256, address) external pure returns (uint256) {
        revert NotSupported();
    }

    /// @inheritdoc IDexAdapter
    function removeLiquidity(address, uint256, address) external pure returns (uint256, uint256) {
        revert NotSupported();
    }

    /// @inheritdoc IDexAdapter
    function claimableFees(address, uint256) external pure returns (uint256, uint256) {
        revert NotSupported();
    }

    /// @inheritdoc IDexAdapter
    function claimFees(address, uint256, address) external pure returns (uint256, uint256) {
        revert NotSupported();
    }
}
