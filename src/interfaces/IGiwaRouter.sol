// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBondingCurve} from "./IBondingCurve.sol";
import {ITokenRegistry} from "./ITokenRegistry.sol";

/// @title IGiwaRouter
/// @notice Unified router that handles both bonding curve (pre-graduation) and DEX (post-graduation) trading directly.

interface IGiwaRouter {
    error ExpiredDeadline();
    error InvalidAmountIn();
    error InvalidAmountOut();
    error InsufficientOutput();
    error ExcessiveInput();
    error TokenNotFound();
    error TokenNotGraduated();
    error InvalidNativeQuoteToken();
    error InvalidRecipient();
    error InvalidAllowance();
    error InvalidBalanceDelta(address token, address account, uint256 requiredBalance, uint256 currentBalance);
    error NativeTransferFailed();
    error UnexpectedNative();
    error InvalidDependency();
    error InvalidDexFeeRate();
    error InvalidV3Pool();
    error InvalidV3Quote();

    /// @dev For graduated buys, `amountIn` is the quote input used including protocol fee.
    event Buy(address indexed buyer, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated);
    /// @dev For graduated sells, `amountIn` is launch-token input used and `amountOut` is quote output after protocol fee.
    event Sell(address indexed seller, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated);
    event Create(address indexed token, address indexed creator);

    struct CreateParams {
        string name;
        string symbol;
        string tokenURI;
        address quoteToken;
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

    /// @return amountIn Quote-token input used, including the graduated-trade protocol fee.
    function exactOutBuy(ExactOutBuyParams calldata params) external returns (uint256 amountIn);
    function exactOutBuyWithNative(ExactOutBuyWithNativeParams calldata params)
        external
        payable
        returns (uint256 amountIn);

    /// @return tokenIn Launch-token input used to deliver the requested quote-token output.
    function exactOutSell(ExactOutSellParams calldata params) external returns (uint256 tokenIn);
    /// @return tokenIn Launch-token input used to deliver the requested native output.
    function exactOutSellToNative(ExactOutSellToNativeParams calldata params) external returns (uint256 tokenIn);

    function isGraduated(address token) external view returns (bool);

    /// @notice Quote output for a swap that auto-routes by lifecycle phase.
    /// @dev Pre-graduation: BondingCurve quote. Post-graduation: DEX pair quote.
    function getAmountOut(address token, uint256 amountIn, bool isBuy) external returns (uint256);

    /// @notice Quote input for a swap that auto-routes by lifecycle phase.
    /// @dev Pre-graduation: BondingCurve quote. Post-graduation: DEX pair quote.
    function getAmountIn(address token, uint256 amountOut, bool isBuy) external returns (uint256);

    function getBondingCurveAmountOut(address token, uint256 amountIn, bool isBuy) external view returns (uint256);
    function getBondingCurveAmountIn(address token, uint256 amountOut, bool isBuy) external view returns (uint256);
    function getDexAmountOut(address token, uint256 amountIn, bool isBuy) external returns (uint256);
    function getDexAmountIn(address token, uint256 amountOut, bool isBuy) external returns (uint256);

    function bondingCurve() external view returns (address);
    function tokenRegistry() external view returns (address);
    function wrappedNative() external view returns (address);
    function v3SwapAdapter() external view returns (address);
    function quoterV2() external view returns (address);
}
