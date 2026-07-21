// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INadFunRouter02} from "../interfaces/INadFunRouter02.sol";
import {INadFunFactory} from "../dex/interfaces/INadFunFactory.sol";
import {INadFunPair} from "../dex/interfaces/INadFunPair.sol";
import {IWrappedNative} from "../interfaces/IWrappedNative.sol";
import {NadFunLibrary} from "../libraries/NadFunLibrary.sol";
import {BPS} from "../libraries/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NadFunRouter02
/// @notice UniswapV2Router02-identical periphery (liquidity + fee-aware swap) for graduated
///         NadFunPairs. Standalone from NadFunRouter (bonding-curve lifecycle + trading) so each
///         stays under the EIP-170 contract size limit.
/// @dev Swap amounts delegate per-hop to NadFunPair.getAmountOut/getAmountIn (fee-aware: LP +
///      creator + protocol, buy/sell asymmetric) — NOT vanilla 0.3% constant-fee math, which
///      would revert on the pair K-check. Pairs resolve via factory.getPair (EIP-1167 clones).
///      Pre-graduation safety is enforced by Token.sol (reverts transfers to its pair before
///      graduation), so there is intentionally no router-level graduation guard.
contract NadFunRouter02 is INadFunRouter02, UUPSUpgradeable, AccessManagedUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    INadFunFactory private _factory;
    IWrappedNative private _wrappedNative;

    /// @dev LP fee in BPS, mirrors NadFunPair.LP_FEE_RATE (0.25%).
    uint256 private constant LP_FEE_RATE = 25;

    /// @dev Accepts native only when the wrapped-native contract unwraps back to the router.
    receive() external payable {
        if (msg.sender != address(_wrappedNative)) revert UnexpectedNative();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address protocolManager_, address factory_, address wmon_) external initializer {
        __AccessManaged_init(protocolManager_);
        if (factory_ == address(0) || wmon_ == address(0)) revert InvalidFactory();
        _factory = INadFunFactory(factory_);
        _wrappedNative = IWrappedNative(wmon_);
    }

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredDeadline();
        _;
    }

    // ═══════════════════════════════════════════════
    //  Getters / Admin
    // ═══════════════════════════════════════════════

    function factory() external view returns (address) {
        return address(_factory);
    }

    /// @notice Wrapped native (WMON). Router02 `WETH()` naming kept for tooling compatibility.
    function WETH() external view returns (address) {
        return address(_wrappedNative);
    }

    function setFactory(address factory_) external restricted {
        if (factory_ == address(0)) revert InvalidFactory();
        _factory = INadFunFactory(factory_);
        emit FactoryUpdated(factory_);
    }

    /// @notice Create a pair via the factory (permissionless passthrough, Router02 extra).
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = _factory.createPair(tokenA, tokenB);
    }

    // ═══════════════════════════════════════════════
    //  Add Liquidity
    // ═══════════════════════════════════════════════

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        if (_factory.getPair(tokenA, tokenB) == address(0)) {
            _factory.createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = NadFunLibrary.getReserves(address(_factory), tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = NadFunLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert InsufficientBAmount();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = NadFunLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                if (amountAOptimal < amountAMin) revert InsufficientAAmount();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /// @dev Transfer optimal amounts to the pair and mint. Factored out to avoid stack-too-deep.
    function _transferAndMint(address tokenA, address tokenB, uint256 amountA, uint256 amountB, address to)
        private
        returns (address pair, uint256 liquidity)
    {
        pair = NadFunLibrary.pairFor(address(_factory), tokenA, tokenB);
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = INadFunPair(pair).mint(to);
    }

    /// @inheritdoc INadFunRouter02
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair;
        (pair, liquidity) = _transferAndMint(tokenA, tokenB, amountA, amountB, to);
        emit AddLiquidity(msg.sender, pair, amountA, amountB, liquidity, to);
    }

    /// @inheritdoc INadFunRouter02
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        address weth = address(_wrappedNative);
        (amountToken, amountETH) =
            _addLiquidity(token, weth, amountTokenDesired, msg.value, amountTokenMin, amountETHMin);
        address pair = NadFunLibrary.pairFor(address(_factory), token, weth);
        IERC20(token).safeTransferFrom(msg.sender, pair, amountToken);
        _wrappedNative.deposit{value: amountETH}();
        IERC20(weth).safeTransfer(pair, amountETH);
        liquidity = INadFunPair(pair).mint(to);
        if (msg.value > amountETH) _transferNative(msg.sender, msg.value - amountETH);
        emit AddLiquidity(msg.sender, pair, amountToken, amountETH, liquidity, to);
    }

    // ═══════════════════════════════════════════════
    //  Remove Liquidity
    // ═══════════════════════════════════════════════

    /// @dev Unguarded so guarded public wrappers can reuse it without nonReentrant re-entry.
    function _removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) internal returns (uint256 amountA, uint256 amountB) {
        address pair = NadFunLibrary.pairFor(address(_factory), tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = INadFunPair(pair).burn(to);
        (address token0,) = NadFunLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
        emit RemoveLiquidity(msg.sender, pair, amountA, amountB, to);
    }

    function _removeLiquidityETHCore(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to
    ) private returns (uint256 amountToken, uint256 amountETH) {
        address weth = address(_wrappedNative);
        (amountToken, amountETH) = _removeLiquidity(token, weth, liquidity, amountTokenMin, amountETHMin, address(this));
        IERC20(token).safeTransfer(to, amountToken);
        _wrappedNative.withdraw(amountETH);
        _transferNative(to, amountETH);
    }

    function _permitLP(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) private {
        address pair = NadFunLibrary.pairFor(address(_factory), tokenA, tokenB);
        uint256 value = approveMax ? type(uint256).max : liquidity;
        // Front-run resistant: if a griefer already replayed this signature (nonce consumed but
        // allowance set), skip permit and proceed with the existing allowance instead of reverting.
        if (IERC20(pair).allowance(msg.sender, address(this)) >= value) return;
        IERC20Permit(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
    }

    /// @inheritdoc INadFunRouter02
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        (amountA, amountB) = _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to);
    }

    /// @inheritdoc INadFunRouter02
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = _removeLiquidityETHCore(token, liquidity, amountTokenMin, amountETHMin, to);
    }

    /// @inheritdoc INadFunRouter02
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        _permitLP(tokenA, tokenB, liquidity, deadline, approveMax, v, r, s);
        (amountA, amountB) = _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to);
    }

    /// @inheritdoc INadFunRouter02
    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        _permitLP(token, address(_wrappedNative), liquidity, deadline, approveMax, v, r, s);
        (amountToken, amountETH) = _removeLiquidityETHCore(token, liquidity, amountTokenMin, amountETHMin, to);
    }

    /// @inheritdoc INadFunRouter02
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public nonReentrant ensure(deadline) returns (uint256 amountETH) {
        address weth = address(_wrappedNative);
        (, amountETH) = _removeLiquidity(token, weth, liquidity, amountTokenMin, amountETHMin, address(this));
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
        _wrappedNative.withdraw(amountETH);
        _transferNative(to, amountETH);
    }

    /// @inheritdoc INadFunRouter02
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant ensure(deadline) returns (uint256 amountETH) {
        address weth = address(_wrappedNative);
        _permitLP(token, weth, liquidity, deadline, approveMax, v, r, s);
        (, amountETH) = _removeLiquidity(token, weth, liquidity, amountTokenMin, amountETHMin, address(this));
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
        _wrappedNative.withdraw(amountETH);
        _transferNative(to, amountETH);
    }

    // ═══════════════════════════════════════════════
    //  Swap
    // ═══════════════════════════════════════════════

    /// @dev Execute swaps along `path`; `amounts` precomputed (fee-aware). Mirrors UniswapV2Router02._swap.
    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = NadFunLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? NadFunLibrary.pairFor(address(_factory), output, path[i + 2]) : _to;
            INadFunPair(NadFunLibrary.pairFor(address(_factory), input, output))
                .swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /// @dev Balance-delta swap along `path` (fee-on-transfer safe). Output per hop via pair.getAmountOut.
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = NadFunLibrary.sortTokens(input, output);
            address pairAddr = NadFunLibrary.pairFor(address(_factory), input, output);
            if (pairAddr == address(0)) revert InvalidPath();
            INadFunPair pair = INadFunPair(pairAddr);
            uint256 amountInput;
            uint256 amountOutput;
            {
                (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
                uint256 reserveInput = input == token0 ? uint256(reserve0) : uint256(reserve1);
                amountInput = IERC20(input).balanceOf(address(pair)) - reserveInput;
                amountOutput = pair.getAmountOut(input, amountInput);
            }
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
            address to = i < path.length - 2 ? NadFunLibrary.pairFor(address(_factory), output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /// @inheritdoc INadFunRouter02
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutput();
        IERC20(path[0])
            .safeTransferFrom(msg.sender, NadFunLibrary.pairFor(address(_factory), path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
        emit Swap(msg.sender, to, path, amounts[0], amounts[amounts.length - 1]);
    }

    /// @inheritdoc INadFunRouter02
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsIn(amountOut, path);
        if (amounts[0] > amountInMax) revert ExcessiveInput();
        IERC20(path[0])
            .safeTransferFrom(msg.sender, NadFunLibrary.pairFor(address(_factory), path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
        emit Swap(msg.sender, to, path, amounts[0], amounts[amounts.length - 1]);
    }

    /// @inheritdoc INadFunRouter02
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        if (path[0] != address(_wrappedNative)) revert InvalidPath();
        amounts = getAmountsOut(msg.value, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutput();
        _wrappedNative.deposit{value: amounts[0]}();
        IERC20(path[0]).safeTransfer(NadFunLibrary.pairFor(address(_factory), path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
        emit Swap(msg.sender, to, path, amounts[0], amounts[amounts.length - 1]);
    }

    /// @inheritdoc INadFunRouter02
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        if (path[path.length - 1] != address(_wrappedNative)) revert InvalidPath();
        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutput();
        IERC20(path[0])
            .safeTransferFrom(msg.sender, NadFunLibrary.pairFor(address(_factory), path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        uint256 outAmount = amounts[amounts.length - 1];
        _wrappedNative.withdraw(outAmount);
        _transferNative(to, outAmount);
        emit Swap(msg.sender, to, path, amounts[0], outAmount);
    }

    /// @inheritdoc INadFunRouter02
    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        if (path[path.length - 1] != address(_wrappedNative)) revert InvalidPath();
        amounts = getAmountsIn(amountOut, path);
        if (amounts[0] > amountInMax) revert ExcessiveInput();
        IERC20(path[0])
            .safeTransferFrom(msg.sender, NadFunLibrary.pairFor(address(_factory), path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        uint256 outAmount = amounts[amounts.length - 1];
        _wrappedNative.withdraw(outAmount);
        _transferNative(to, outAmount);
        emit Swap(msg.sender, to, path, amounts[0], outAmount);
    }

    /// @inheritdoc INadFunRouter02
    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        if (path[0] != address(_wrappedNative)) revert InvalidPath();
        amounts = getAmountsIn(amountOut, path);
        if (amounts[0] > msg.value) revert ExcessiveInput();
        _wrappedNative.deposit{value: amounts[0]}();
        IERC20(path[0]).safeTransfer(NadFunLibrary.pairFor(address(_factory), path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
        if (msg.value > amounts[0]) _transferNative(msg.sender, msg.value - amounts[0]);
        emit Swap(msg.sender, to, path, amounts[0], amounts[amounts.length - 1]);
    }

    /// @inheritdoc INadFunRouter02
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) {
        IERC20(path[0])
            .safeTransferFrom(msg.sender, NadFunLibrary.pairFor(address(_factory), path[0], path[1]), amountIn);
        address output = path[path.length - 1];
        uint256 balanceBefore = IERC20(output).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        uint256 amountOut = IERC20(output).balanceOf(to) - balanceBefore;
        if (amountOut < amountOutMin) revert InsufficientOutput();
        emit Swap(msg.sender, to, path, amountIn, amountOut);
    }

    /// @inheritdoc INadFunRouter02
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable nonReentrant ensure(deadline) {
        if (path[0] != address(_wrappedNative)) revert InvalidPath();
        uint256 amountIn = msg.value;
        _wrappedNative.deposit{value: amountIn}();
        IERC20(path[0]).safeTransfer(NadFunLibrary.pairFor(address(_factory), path[0], path[1]), amountIn);
        address output = path[path.length - 1];
        uint256 balanceBefore = IERC20(output).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        uint256 amountOut = IERC20(output).balanceOf(to) - balanceBefore;
        if (amountOut < amountOutMin) revert InsufficientOutput();
        emit Swap(msg.sender, to, path, amountIn, amountOut);
    }

    /// @inheritdoc INadFunRouter02
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) {
        if (path[path.length - 1] != address(_wrappedNative)) revert InvalidPath();
        IERC20(path[0])
            .safeTransferFrom(msg.sender, NadFunLibrary.pairFor(address(_factory), path[0], path[1]), amountIn);
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint256 amountOut = IERC20(address(_wrappedNative)).balanceOf(address(this));
        if (amountOut < amountOutMin) revert InsufficientOutput();
        _wrappedNative.withdraw(amountOut);
        _transferNative(to, amountOut);
        emit Swap(msg.sender, to, path, amountIn, amountOut);
    }

    // ═══════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════

    /// @inheritdoc INadFunRouter02
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB) {
        amountB = NadFunLibrary.quote(amountA, reserveA, reserveB);
    }

    /// @notice LP-fee-only output estimate. Ignores creator/protocol fees — use getAmountsOut(path) for accuracy.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidityError();
        uint256 amountInWithFee = amountIn * (BPS - LP_FEE_RATE);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * BPS + amountInWithFee);
    }

    /// @notice LP-fee-only input estimate. Ignores creator/protocol fees — use getAmountsIn(path) for accuracy.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidityError();
        amountIn = (reserveIn * amountOut * BPS) / ((reserveOut - amountOut) * (BPS - LP_FEE_RATE)) + 1;
    }

    /// @inheritdoc INadFunRouter02
    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            address pair = NadFunLibrary.pairFor(address(_factory), path[i], path[i + 1]);
            if (pair == address(0)) revert InvalidPath();
            amounts[i + 1] = INadFunPair(pair).getAmountOut(path[i], amounts[i]);
        }
    }

    /// @inheritdoc INadFunRouter02
    function getAmountsIn(uint256 amountOut, address[] memory path) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            address pair = NadFunLibrary.pairFor(address(_factory), path[i - 1], path[i]);
            if (pair == address(0)) revert InvalidPath();
            amounts[i - 1] = INadFunPair(pair).getAmountIn(path[i], amounts[i]);
        }
    }

    // ═══════════════════════════════════════════════
    //  Internal
    // ═══════════════════════════════════════════════

    function _transferNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}
}
