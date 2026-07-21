// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBondingCurve} from "./IBondingCurve.sol";
import {ITokenRegistry} from "./ITokenRegistry.sol";

/// @title INadFunRouter
/// @notice Unified router that handles both bonding curve (pre-graduation) and DEX (post-graduation) trading directly.

interface INadFunRouter {
    error ExpiredDeadline();
    error InvalidAmountIn();
    error InvalidAmountOut();
    error InsufficientOutput();
    error ExcessiveInput();
    error TokenNotFound();
    error TokenNotGraduated();
    error InvalidNativeQuoteToken();
    error InvalidLvMonMinter();
    error InsufficientNativeQuoteMinted();
    error InvalidRecipient();
    error InvalidAllowance();
    error NativeTransferFailed();
    error UnexpectedNative();

    event Buy(address indexed buyer, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated);
    event Sell(address indexed seller, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated);
    event Create(address indexed token, address indexed creator);

    struct CreateParams {
        string name;
        string symbol;
        string tokenURI;
        address quoteToken;
        uint16 creatorFeeRate;
        IBondingCurve.VaultAllocation[] vaults;
        bytes32 salt;
        ITokenRegistry.DexType dexType;
        uint256 buyQuoteAmount;
        uint256 deadline;
    }

    struct BuyParams {
        uint256 amountIn;
        uint256 amountOutMin;
        address token;
        address to;
        uint256 deadline;
    }

    struct BuyWithNativeParams {
        uint256 amountOutMin;
        address token;
        address to;
        uint256 deadline;
    }

    struct BuyWithPermitParams {
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 amountAllowance;
        address token;
        address to;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct SellParams {
        uint256 amountIn;
        uint256 amountOutMin;
        address token;
        address to;
        uint256 deadline;
    }

    struct SellToNativeParams {
        uint256 amountIn;
        uint256 amountOutMin;
        address token;
        address to;
        uint256 deadline;
    }

    struct SellWithPermitParams {
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 amountAllowance;
        address token;
        address to;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct SellToNativeWithPermitParams {
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 amountAllowance;
        address token;
        address to;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct ExactOutBuyParams {
        uint256 amountInMax;
        uint256 amountOut;
        address token;
        address to;
        uint256 deadline;
    }

    struct ExactOutBuyWithNativeParams {
        uint256 amountOut;
        address token;
        address to;
        uint256 deadline;
    }

    struct ExactOutSellParams {
        uint256 amountInMax;
        uint256 amountOut;
        address token;
        address to;
        uint256 deadline;
    }

    struct ExactOutSellToNativeParams {
        uint256 amountInMax;
        uint256 amountOut;
        address token;
        address to;
        uint256 deadline;
    }

    function create(CreateParams calldata params) external returns (address token, uint256 tokenOut);
    function createWithNative(CreateParams calldata params) external payable returns (address token, uint256 tokenOut);

    function buy(BuyParams calldata params) external returns (uint256 amountOut);
    function buyWithNative(BuyWithNativeParams calldata params) external payable returns (uint256 amountOut);
    function buyWithPermit(BuyWithPermitParams calldata params) external returns (uint256 amountOut);

    function sell(SellParams calldata params) external returns (uint256 amountOut);
    function sellToNative(SellToNativeParams calldata params) external returns (uint256 amountOut);
    function sellWithPermit(SellWithPermitParams calldata params) external returns (uint256 amountOut);
    function sellToNativeWithPermit(SellToNativeWithPermitParams calldata params) external returns (uint256 amountOut);

    function exactOutBuy(ExactOutBuyParams calldata params) external returns (uint256 amountIn);
    function exactOutBuyWithNative(ExactOutBuyWithNativeParams calldata params)
        external
        payable
        returns (uint256 amountIn);

    function exactOutSell(ExactOutSellParams calldata params) external returns (uint256 amountOut);
    function exactOutSellToNative(ExactOutSellToNativeParams calldata params) external returns (uint256 amountOut);

    function isGraduated(address token) external view returns (bool);

    /// @notice Quote output for a swap that auto-routes by lifecycle phase.
    /// @dev Pre-graduation: BondingCurve quote. Post-graduation: DEX pair quote.
    function getAmountOut(address token, uint256 amountIn, bool isBuy) external view returns (uint256);

    /// @notice Quote input for a swap that auto-routes by lifecycle phase.
    /// @dev Pre-graduation: BondingCurve quote. Post-graduation: DEX pair quote.
    function getAmountIn(address token, uint256 amountOut, bool isBuy) external view returns (uint256);

    function getBondingCurveAmountOut(address token, uint256 amountIn, bool isBuy) external view returns (uint256);
    function getBondingCurveAmountIn(address token, uint256 amountOut, bool isBuy) external view returns (uint256);
    function getDexAmountOut(address token, uint256 amountIn, bool isBuy) external view returns (uint256);
    function getDexAmountIn(address token, uint256 amountOut, bool isBuy) external view returns (uint256);

    function bondingCurve() external view returns (address);
    function tokenRegistry() external view returns (address);
    function wrappedNative() external view returns (address);
    function lvMonMinter() external view returns (address);
}
