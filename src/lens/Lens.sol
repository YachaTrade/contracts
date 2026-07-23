// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILens} from "./ILens.sol";
import {IBondingCurve} from "../interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../interfaces/IGiwaRouter.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {BondingCurveLibrary} from "../libraries/BondingCurveLibrary.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title Lens
/// @notice Stateless lifecycle-aware integration lens for GIWA curve and canonical V3 quotes.
contract Lens is ILens {
    uint256 private constant BPS = 10_000;

    IGiwaRouter public immutable giwaRouter;

    constructor(address giwaRouter_) {
        if (giwaRouter_.code.length == 0) revert InvalidDependency();
        giwaRouter = IGiwaRouter(giwaRouter_);

        address bondingCurve_ = giwaRouter.bondingCurve();
        address tokenRegistry_ = giwaRouter.tokenRegistry();
        address protocolManager_ = IAccessManaged(giwaRouter_).authority();
        if (bondingCurve_.code.length == 0 || tokenRegistry_.code.length == 0 || protocolManager_.code.length == 0) {
            revert InvalidDependency();
        }
    }

    function curve() public view returns (address) {
        return giwaRouter.bondingCurve();
    }

    function curveRouter() external view returns (address) {
        return address(giwaRouter);
    }

    function dexRouter() external view returns (address) {
        return address(giwaRouter);
    }

    function tokenRegistry() external view returns (address) {
        return giwaRouter.tokenRegistry();
    }

    function isGraduated(address token) external view returns (bool graduated) {
        return _getCurve(token).graduated;
    }

    function isLocked(address token) external view returns (bool locked) {
        return _getCurve(token).graduated;
    }

    function getAmountIn(address token, uint256 amountOut, bool isBuy)
        external
        returns (address router, uint256 amountIn)
    {
        _getCurve(token);
        router = address(giwaRouter);
        amountIn = giwaRouter.getAmountIn(token, amountOut, isBuy);
    }

    function getAmountOut(address token, uint256 amountIn, bool isBuy)
        external
        returns (address router, uint256 amountOut)
    {
        _getCurve(token);
        router = address(giwaRouter);
        amountOut = giwaRouter.getAmountOut(token, amountIn, isBuy);
    }

    function availableBuyTokens(address token)
        external
        view
        returns (uint256 availableBuyToken, uint256 requiredQuoteAmount)
    {
        IBondingCurve.Curve memory curve_ = _getCurve(token);
        if (curve_.graduated) return (0, 0);
        if (curve_.virtualTokenReserve < curve_.minTokenReserve) revert InvalidCurveConfig();

        availableBuyToken = curve_.virtualTokenReserve - curve_.minTokenReserve;
        if (availableBuyToken > 0) {
            requiredQuoteAmount = IBondingCurve(curve()).getAmountIn(token, availableBuyToken, true);
        }
    }

    function getProgress(address token) external view returns (uint256 progress) {
        IBondingCurve.Curve memory curve_ = _getCurve(token);
        if (curve_.graduated) return BPS;
        if (
            curve_.initialTokenReserve <= curve_.minTokenReserve
                || curve_.virtualTokenReserve > curve_.initialTokenReserve
                || curve_.virtualTokenReserve < curve_.minTokenReserve
        ) revert InvalidCurveConfig();

        uint256 sellableTokenAmount = curve_.initialTokenReserve - curve_.minTokenReserve;
        uint256 soldTokenAmount = curve_.initialTokenReserve - curve_.virtualTokenReserve;
        progress = FixedPointMathLib.mulDiv(soldTokenAmount, BPS, sellableTokenAmount);
        if (progress > BPS) progress = BPS;
    }

    function getInitialBuyAmountOut(address quoteToken, uint256 quoteIn) external view returns (uint256 tokenOut) {
        address manager = IAccessManaged(address(giwaRouter)).authority();
        IProtocolManager.QuoteConfig memory config = IProtocolManager(manager).getConfig(quoteToken);
        if (!config.active) revert QuoteTokenNotAllowed();
        if (
            config.virtualReserve == 0 || config.virtualTokenReserve <= config.minTokenReserve
                || config.virtualReserve > type(uint256).max / config.virtualTokenReserve
        ) revert InvalidCurveConfig();
        if (quoteIn == 0) return 0;

        uint256 protocolFeeRate = config.curveProtocolFeeRate;
        uint256 protocolFee =
            protocolFeeRate >= BPS ? quoteIn : FixedPointMathLib.mulDivUp(quoteIn, protocolFeeRate, BPS);

        uint256 quoteInAfterProtocolFee = quoteIn - protocolFee;
        uint256 k = config.virtualReserve * config.virtualTokenReserve;
        tokenOut = BondingCurveLibrary.getAmountOut(
            quoteInAfterProtocolFee, k, config.virtualReserve, config.virtualTokenReserve
        );

        uint256 availableBuyToken = config.virtualTokenReserve - config.minTokenReserve;
        if (tokenOut > availableBuyToken) tokenOut = availableBuyToken;
    }

    function _getCurve(address token) private view returns (IBondingCurve.Curve memory curve_) {
        curve_ = IBondingCurve(curve()).getCurve(token);
        if (curve_.token == address(0)) revert TokenNotFound();
    }
}
