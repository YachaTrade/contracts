// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IFeeTo} from "../interfaces/IFeeTo.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {INadFunPair} from "../dex/interfaces/INadFunPair.sol";
import {BPS} from "../libraries/Constants.sol";

/// @title FeeTo
/// @notice Singleton recipient for NadFunFactory.feeTo(). Converts accumulated V2
///         LP-dilution into the pair's quote token and forwards the net excess to
///         `ProtocolManager.feeReceiver()`. Caller's principal is refunded.
/// @dev    ERC20-only funding. Caller must `approve` this contract per quote token
///         before calling; FeeTo pulls each entry's principal via `transferFrom`.
///         For native MON, wrap externally to WMON first.
contract FeeTo is IFeeTo, UUPSUpgradeable, AccessManagedUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Mirrors NadFunPair.LP_FEE_RATE (25 BPS). Used by the zap math.
    uint256 private constant LP_FEE_RATE = 25;

    /// @dev Deprecated. Retained only to preserve the UUPS storage slot layout of the
    ///      live proxy. Swaps now execute directly against the NadFunPair; this address
    ///      is no longer read by any logic. Still set in `initialize` for backward compat.
    address public router;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address protocolManager_, address router_) external initializer {
        if (router_ == address(0)) revert InvalidRecipient();
        __AccessManaged_init(protocolManager_);
        router = router_;
    }

    /// @inheritdoc IFeeTo
    function claim(ClaimParams[] calldata params, uint256 deadline)
        external
        restricted
        nonReentrant
        returns (uint256[] memory quoteOuts)
    {
        uint256 n = params.length;
        if (n == 0) revert EmptyBatch();
        if (block.timestamp > deadline) revert ExpiredDeadline();

        quoteOuts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            quoteOuts[i] = _claim(params[i]);
        }
    }

    /// @inheritdoc IFeeTo
    function burn(address[] calldata pairs)
        external
        restricted
        nonReentrant
        returns (uint256[] memory amounts0, uint256[] memory amounts1)
    {
        uint256 n = pairs.length;
        if (n == 0) revert EmptyBatch();

        address feeRecv = IProtocolManager(authority()).feeReceiver();
        amounts0 = new uint256[](n);
        amounts1 = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address pair = pairs[i];
            uint256 lpBal = IERC20(pair).balanceOf(address(this));
            if (lpBal == 0) continue;

            IERC20(pair).safeTransfer(pair, lpBal);
            (amounts0[i], amounts1[i]) = INadFunPair(pair).burn(feeRecv);
            emit Burned(pair, lpBal, amounts0[i], amounts1[i]);
        }
    }

    // ----- Per-entry: pull principal, run ops, settle -----

    function _claim(ClaimParams calldata p) internal returns (uint256 excess) {
        if (p.quoteIn == 0) revert InvalidQuoteIn();
        _verifyPair(p.pair, p.quote, p.token);

        uint256 beforeBal = IERC20(p.quote).balanceOf(address(this));
        IERC20(p.quote).safeTransferFrom(msg.sender, address(this), p.quoteIn);

        uint256 quoteReserve = _quoteReserve(p.pair, p.quote);
        if (quoteReserve == 0) revert EmptyReserve();
        uint256 swapQuote = _computeZapSwap(p.quoteIn, quoteReserve);
        if (swapQuote == 0 || swapQuote >= p.quoteIn) revert ZapSplitFailed();

        uint256 tokenReceived = _swapExactIn(p.pair, p.quote, swapQuote);
        _mintLp(p.pair, p.quote, p.token, p.quoteIn - swapQuote, tokenReceived);
        _burnLp(p.pair);
        _sellToken(p.pair, p.token);

        // Yield from this entry only (delta vs beforeBal preserves residual cleanly).
        uint256 afterBal = IERC20(p.quote).balanceOf(address(this));
        uint256 yield = afterBal > beforeBal ? afterBal - beforeBal : 0;
        uint256 refund = yield >= p.quoteIn ? p.quoteIn : yield;
        excess = yield - refund;

        if (refund > 0) IERC20(p.quote).safeTransfer(msg.sender, refund);
        if (excess > 0) {
            IERC20(p.quote).safeTransfer(IProtocolManager(authority()).feeReceiver(), excess);
        }
        emit Claimed(p.pair, p.token, p.quoteIn, excess);
    }

    // ----- Helpers -----

    function _verifyPair(address pair, address quote, address token) internal view {
        if (quote == token) revert InvalidPair();
        address token0 = INadFunPair(pair).token0();
        address token1 = INadFunPair(pair).token1();
        if (quote != token0 && quote != token1) revert InvalidPair();
        if (token != token0 && token != token1) revert InvalidPair();
    }

    /// @dev Single-pair exact-in swap, mirroring NadSwapAdapter.swap. Transfers `tokenIn`
    ///      straight to the pair (no approval needed) and swaps in the correct direction.
    ///      `getAmountOut` is the pair's canonical quote, consistent with its K-check.
    function _swapExactIn(address pair, address tokenIn, uint256 amountIn) internal returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransfer(pair, amountIn);
        amountOut = INadFunPair(pair).getAmountOut(tokenIn, amountIn);
        if (tokenIn == INadFunPair(pair).token0()) {
            INadFunPair(pair).swap(0, amountOut, address(this), "");
        } else {
            INadFunPair(pair).swap(amountOut, 0, address(this), "");
        }
    }

    function _mintLp(address pair, address quote, address token, uint256 addQuote, uint256 tokenReceived) internal {
        IERC20(quote).safeTransfer(pair, addQuote);
        IERC20(token).safeTransfer(pair, tokenReceived);
        INadFunPair(pair).mint(address(this));
    }

    function _burnLp(address pair) internal {
        uint256 lpBal = IERC20(pair).balanceOf(address(this));
        if (lpBal > 0) {
            IERC20(pair).safeTransfer(pair, lpBal);
            INadFunPair(pair).burn(address(this));
        }
    }

    function _sellToken(address pair, address token) internal {
        uint256 tokenBal = IERC20(token).balanceOf(address(this));
        if (tokenBal > 0) _swapExactIn(pair, token, tokenBal);
    }

    function _quoteReserve(address pair, address quote) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = INadFunPair(pair).getReserves();
        return quote == INadFunPair(pair).token0() ? uint256(r0) : uint256(r1);
    }

    /// @dev Mirrors LPVault._computeZapSwap. LP-fee-only formula; mint-side dust loss accepted.
    function _computeZapSwap(uint256 totalQuote, uint256 quoteReserve) internal pure returns (uint256) {
        if (totalQuote == 0 || quoteReserve == 0) return 0;
        uint256 feeAdj = BPS - LP_FEE_RATE;
        uint256 twoMinusF = (2 * BPS) - LP_FEE_RATE;
        uint256 b = quoteReserve * twoMinusF;
        uint256 discriminant = b * b + 4 * feeAdj * BPS * totalQuote * quoteReserve;
        uint256 sqrtDisc = FixedPointMathLib.sqrt(discriminant);
        return (sqrtDisc - b) / (2 * feeAdj);
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}
}
