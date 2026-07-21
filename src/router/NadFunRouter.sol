// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBondingCurve} from "../interfaces/IBondingCurve.sol";
import {INadFunRouter} from "../interfaces/INadFunRouter.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IWrappedNative} from "../interfaces/IWrappedNative.sol";
import {ILvMonMinter} from "../interfaces/ILvMonMinter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NadFunRouter
/// @notice Unified user-facing router for token creation and trading across both lifecycle phases.
/// @dev Handles bonding curve (pre-graduation) and DEX (post-graduation) trading directly —
///      no intermediate routers. Native wrapping and slippage protection are handled at this
///      single entrypoint.
contract NadFunRouter is INadFunRouter, UUPSUpgradeable, AccessManagedUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IBondingCurve private _bondingCurve;
    ITokenRegistry private _tokenRegistry;
    IWrappedNative private _wrappedNative;
    ILvMonMinter private _lvMonMinter;

    /// @dev Accepts native only when the wrapped-native contract unwraps back to the router
    ///      (e.g. during sellToNative / exactOutBuyWithNative refunds). Direct transfers from
    ///      any other sender are rejected so stray ETH cannot silently accumulate here.
    receive() external payable {
        if (msg.sender != address(_wrappedNative)) revert UnexpectedNative();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address protocolManager_,
        address bondingCurve_,
        address tokenRegistry_,
        address wrappedNative_,
        address lvMonMinter_
    ) external initializer {
        __AccessManaged_init(protocolManager_);
        _bondingCurve = IBondingCurve(bondingCurve_);
        _tokenRegistry = ITokenRegistry(tokenRegistry_);
        _wrappedNative = IWrappedNative(wrappedNative_);
        _setLvMonMinter(lvMonMinter_);
    }

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredDeadline();
        _;
    }

    // ═══════════════════════════════════════════════
    //  Token Creation
    // ═══════════════════════════════════════════════

    /// @inheritdoc INadFunRouter
    function create(CreateParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (address token, uint256 tokenOut)
    {
        uint256 deployFee = IProtocolManager(authority()).deployFee(params.quoteToken);
        uint256 quoteRequired = deployFee + params.buyQuoteAmount;

        IERC20(params.quoteToken).safeTransferFrom(msg.sender, address(_bondingCurve), quoteRequired);

        (token, tokenOut) = _bondingCurve.create(
            IBondingCurve.CreateTokenParams({
                name: params.name,
                symbol: params.symbol,
                tokenURI: params.tokenURI,
                quoteToken: params.quoteToken,
                creatorFeeRate: params.creatorFeeRate,
                vaults: params.vaults,
                salt: params.salt,
                dexType: params.dexType,
                creator: msg.sender,
                buyQuoteAmount: params.buyQuoteAmount
            })
        );

        emit Create(token, msg.sender);
    }

    /// @inheritdoc INadFunRouter
    function createWithNative(CreateParams calldata params)
        external
        payable
        nonReentrant
        ensure(params.deadline)
        returns (address token, uint256 tokenOut)
    {
        address quoteToken = params.quoteToken;
        uint256 deployFee = IProtocolManager(authority()).deployFee(quoteToken);
        uint256 quoteRequired = deployFee + params.buyQuoteAmount;
        require(msg.value >= quoteRequired, "Insufficient native");

        _fundQuoteFromNative(quoteToken, quoteRequired);
        IERC20(quoteToken).safeTransfer(address(_bondingCurve), quoteRequired);

        (token, tokenOut) = _bondingCurve.create(
            IBondingCurve.CreateTokenParams({
                name: params.name,
                symbol: params.symbol,
                tokenURI: params.tokenURI,
                quoteToken: quoteToken,
                creatorFeeRate: params.creatorFeeRate,
                vaults: params.vaults,
                salt: params.salt,
                dexType: params.dexType,
                creator: msg.sender,
                buyQuoteAmount: params.buyQuoteAmount
            })
        );

        uint256 refund = msg.value - quoteRequired;
        if (refund > 0) _transferNative(msg.sender, refund);

        emit Create(token, msg.sender);
    }

    // ═══════════════════════════════════════════════
    //  Buy
    // ═══════════════════════════════════════════════

    /// @inheritdoc INadFunRouter
    function buy(BuyParams calldata params) external nonReentrant ensure(params.deadline) returns (uint256 amountOut) {
        if (params.amountIn == 0) revert InvalidAmountIn();
        if (params.to == address(0)) revert InvalidRecipient();

        bool graduated = _isGraduated(params.token);
        uint256 quoteIn;
        address quoteToken = _getQuoteToken(params.token);

        if (graduated) {
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), params.amountIn);
            amountOut = _dexSwap(params.token, quoteToken, params.amountIn, params.to);
            quoteIn = params.amountIn;
        } else {
            uint256 expectedOut = _bondingCurve.getAmountOut(params.token, params.amountIn, true);
            quoteIn = expectedOut == 0 ? params.amountIn : _bondingCurve.getAmountIn(params.token, expectedOut, true);
            if (quoteIn > params.amountIn) quoteIn = params.amountIn;
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), params.amountIn);
            IERC20(quoteToken).safeTransfer(address(_bondingCurve), quoteIn);
            amountOut = _bondingCurve.buy(params.to, params.token);
        }

        if (amountOut < params.amountOutMin) revert InsufficientOutput();
        uint256 refund = params.amountIn - quoteIn;
        if (refund > 0) IERC20(quoteToken).safeTransfer(msg.sender, refund);
        emit Buy(msg.sender, params.token, quoteIn, amountOut, graduated);
    }

    /// @inheritdoc INadFunRouter
    function buyWithNative(BuyWithNativeParams calldata params)
        external
        payable
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        if (msg.value == 0) revert InvalidAmountIn();
        if (params.to == address(0)) revert InvalidRecipient();

        bool graduated = _isGraduated(params.token);
        uint256 quoteIn;
        uint256 refund;
        address quoteToken = _getQuoteToken(params.token);

        if (graduated) {
            quoteIn = msg.value;
            _fundQuoteFromNative(quoteToken, quoteIn);
            amountOut = _dexSwap(params.token, quoteToken, quoteIn, params.to);
        } else {
            uint256 expectedOut = _bondingCurve.getAmountOut(params.token, msg.value, true);
            quoteIn = expectedOut == 0 ? msg.value : _bondingCurve.getAmountIn(params.token, expectedOut, true);
            if (quoteIn > msg.value) quoteIn = msg.value;
            _fundQuoteFromNative(quoteToken, quoteIn);
            IERC20(quoteToken).safeTransfer(address(_bondingCurve), quoteIn);
            amountOut = _bondingCurve.buy(params.to, params.token);
            refund = msg.value - quoteIn;
        }

        if (amountOut < params.amountOutMin) revert InsufficientOutput();
        if (refund > 0) _transferNative(msg.sender, refund);
        emit Buy(msg.sender, params.token, quoteIn, amountOut, graduated);
    }

    /// @inheritdoc INadFunRouter
    function buyWithPermit(BuyWithPermitParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        if (params.amountIn == 0) revert InvalidAmountIn();
        if (params.to == address(0)) revert InvalidRecipient();
        if (params.amountAllowance < params.amountIn) revert InvalidAllowance();

        address quoteToken = _getQuoteToken(params.token);
        _permit(
            quoteToken, msg.sender, address(this), params.amountAllowance, params.deadline, params.v, params.r, params.s
        );

        bool graduated = _isGraduated(params.token);
        uint256 quoteIn;

        if (graduated) {
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), params.amountIn);
            amountOut = _dexSwap(params.token, quoteToken, params.amountIn, params.to);
            quoteIn = params.amountIn;
        } else {
            uint256 expectedOut = _bondingCurve.getAmountOut(params.token, params.amountIn, true);
            quoteIn = expectedOut == 0 ? params.amountIn : _bondingCurve.getAmountIn(params.token, expectedOut, true);
            if (quoteIn > params.amountIn) quoteIn = params.amountIn;
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), params.amountIn);
            IERC20(quoteToken).safeTransfer(address(_bondingCurve), quoteIn);
            amountOut = _bondingCurve.buy(params.to, params.token);
        }

        if (amountOut < params.amountOutMin) revert InsufficientOutput();
        uint256 refund = params.amountIn - quoteIn;
        if (refund > 0) IERC20(quoteToken).safeTransfer(msg.sender, refund);
        emit Buy(msg.sender, params.token, quoteIn, amountOut, graduated);
    }

    // ═══════════════════════════════════════════════
    //  Sell
    // ═══════════════════════════════════════════════

    /// @inheritdoc INadFunRouter
    function sell(SellParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        if (params.amountIn == 0) revert InvalidAmountIn();
        if (params.to == address(0)) revert InvalidRecipient();

        bool graduated = _isGraduated(params.token);

        if (graduated) {
            IERC20(params.token).safeTransferFrom(msg.sender, address(this), params.amountIn);
            amountOut = _dexSwap(params.token, params.token, params.amountIn, params.to);
        } else {
            IERC20(params.token).safeTransferFrom(msg.sender, address(_bondingCurve), params.amountIn);
            amountOut = _bondingCurve.sell(params.to, params.token);
        }

        if (amountOut < params.amountOutMin) revert InsufficientOutput();
        emit Sell(msg.sender, params.token, params.amountIn, amountOut, graduated);
    }

    /// @inheritdoc INadFunRouter
    function sellToNative(SellToNativeParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        if (params.amountIn == 0) revert InvalidAmountIn();
        if (params.to == address(0)) revert InvalidRecipient();

        bool graduated = _isGraduated(params.token);

        if (graduated) {
            IERC20(params.token).safeTransferFrom(msg.sender, address(this), params.amountIn);
            amountOut = _dexSwap(params.token, params.token, params.amountIn, address(this));
        } else {
            IERC20(params.token).safeTransferFrom(msg.sender, address(_bondingCurve), params.amountIn);
            amountOut = _bondingCurve.sell(address(this), params.token);
        }

        if (amountOut < params.amountOutMin) revert InsufficientOutput();

        _wrappedNative.withdraw(amountOut);
        (bool success,) = params.to.call{value: amountOut}("");
        if (!success) revert NativeTransferFailed();

        emit Sell(msg.sender, params.token, params.amountIn, amountOut, graduated);
    }

    /// @inheritdoc INadFunRouter
    function sellWithPermit(SellWithPermitParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        if (params.amountIn == 0) revert InvalidAmountIn();
        if (params.to == address(0)) revert InvalidRecipient();
        if (params.amountAllowance < params.amountIn) revert InvalidAllowance();
        _permit(
            params.token,
            msg.sender,
            address(this),
            params.amountAllowance,
            params.deadline,
            params.v,
            params.r,
            params.s
        );

        bool graduated = _isGraduated(params.token);

        if (graduated) {
            IERC20(params.token).safeTransferFrom(msg.sender, address(this), params.amountIn);
            amountOut = _dexSwap(params.token, params.token, params.amountIn, params.to);
        } else {
            IERC20(params.token).safeTransferFrom(msg.sender, address(_bondingCurve), params.amountIn);
            amountOut = _bondingCurve.sell(params.to, params.token);
        }

        if (amountOut < params.amountOutMin) revert InsufficientOutput();
        emit Sell(msg.sender, params.token, params.amountIn, amountOut, graduated);
    }

    /// @inheritdoc INadFunRouter
    function sellToNativeWithPermit(SellToNativeWithPermitParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        if (params.amountIn == 0) revert InvalidAmountIn();
        if (params.to == address(0)) revert InvalidRecipient();
        if (params.amountAllowance < params.amountIn) revert InvalidAllowance();
        _permit(
            params.token,
            msg.sender,
            address(this),
            params.amountAllowance,
            params.deadline,
            params.v,
            params.r,
            params.s
        );

        bool graduated = _isGraduated(params.token);

        if (graduated) {
            IERC20(params.token).safeTransferFrom(msg.sender, address(this), params.amountIn);
            amountOut = _dexSwap(params.token, params.token, params.amountIn, address(this));
        } else {
            IERC20(params.token).safeTransferFrom(msg.sender, address(_bondingCurve), params.amountIn);
            amountOut = _bondingCurve.sell(address(this), params.token);
        }

        if (amountOut < params.amountOutMin) revert InsufficientOutput();

        _wrappedNative.withdraw(amountOut);
        (bool success,) = params.to.call{value: amountOut}("");
        if (!success) revert NativeTransferFailed();

        emit Sell(msg.sender, params.token, params.amountIn, amountOut, graduated);
    }

    // ═══════════════════════════════════════════════
    //  Exact Output
    // ═══════════════════════════════════════════════

    /// @inheritdoc INadFunRouter
    function exactOutBuy(ExactOutBuyParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountIn)
    {
        if (params.amountOut == 0) revert InvalidAmountOut();
        if (params.amountInMax == 0) revert InvalidAmountIn();
        if (params.to == address(0)) revert InvalidRecipient();

        bool graduated = _isGraduated(params.token);

        if (graduated) {
            address quoteToken = _getQuoteToken(params.token);
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), params.amountInMax);
            (amountIn,) = _dexSwapExactOut(params.token, quoteToken, params.amountOut, params.to);
            if (amountIn > params.amountInMax) revert ExcessiveInput();
            uint256 refund = params.amountInMax - amountIn;
            if (refund > 0) IERC20(quoteToken).safeTransfer(msg.sender, refund);
        } else {
            address quoteToken = _getQuoteToken(params.token);
            amountIn = _bondingCurve.getAmountIn(params.token, params.amountOut, true);
            if (amountIn > params.amountInMax) revert ExcessiveInput();
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), params.amountInMax);
            IERC20(quoteToken).safeTransfer(address(_bondingCurve), amountIn);
            uint256 actualOut = _bondingCurve.buy(params.to, params.token);
            if (actualOut < params.amountOut) revert InsufficientOutput();
            uint256 refund = params.amountInMax - amountIn;
            if (refund > 0) IERC20(quoteToken).safeTransfer(msg.sender, refund);
        }

        emit Buy(msg.sender, params.token, amountIn, params.amountOut, graduated);
    }

    /// @inheritdoc INadFunRouter
    function exactOutBuyWithNative(ExactOutBuyWithNativeParams calldata params)
        external
        payable
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountIn)
    {
        if (params.amountOut == 0) revert InvalidAmountOut();
        if (msg.value == 0) revert InvalidAmountIn();
        if (params.to == address(0)) revert InvalidRecipient();

        bool graduated = _isGraduated(params.token);
        address quoteToken = _getQuoteToken(params.token);

        if (graduated) {
            amountIn = _dexAmountIn(params.token, params.amountOut, true);
            if (amountIn > msg.value) revert ExcessiveInput();
            _fundQuoteFromNative(quoteToken, amountIn);
            (amountIn,) = _dexSwapExactOut(params.token, quoteToken, params.amountOut, params.to);
        } else {
            amountIn = _bondingCurve.getAmountIn(params.token, params.amountOut, true);
            if (amountIn > msg.value) revert ExcessiveInput();
            _fundQuoteFromNative(quoteToken, amountIn);
            IERC20(quoteToken).safeTransfer(address(_bondingCurve), amountIn);
            uint256 actualOut = _bondingCurve.buy(params.to, params.token);
            if (actualOut < params.amountOut) revert InsufficientOutput();
        }

        uint256 refund = msg.value - amountIn;
        if (refund > 0) _transferNative(msg.sender, refund);

        emit Buy(msg.sender, params.token, amountIn, params.amountOut, graduated);
    }

    /// @inheritdoc INadFunRouter
    function exactOutSell(ExactOutSellParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 quoteOut)
    {
        if (params.amountInMax == 0) revert InvalidAmountIn();
        if (params.amountOut == 0) revert InvalidAmountOut();
        if (params.to == address(0)) revert InvalidRecipient();

        bool graduated = _isGraduated(params.token);

        uint256 tokenUsed;
        if (graduated) {
            IERC20(params.token).safeTransferFrom(msg.sender, address(this), params.amountInMax);
            (tokenUsed, quoteOut) = _dexSwapExactOut(params.token, params.token, params.amountOut, params.to);
            if (tokenUsed > params.amountInMax) revert ExcessiveInput();
            uint256 tokenRefund = params.amountInMax - tokenUsed;
            if (tokenRefund > 0) IERC20(params.token).safeTransfer(msg.sender, tokenRefund);
        } else {
            tokenUsed = _bondingCurve.getAmountIn(params.token, params.amountOut, false);
            if (tokenUsed > params.amountInMax) revert ExcessiveInput();
            IERC20(params.token).safeTransferFrom(msg.sender, address(_bondingCurve), tokenUsed);
            quoteOut = _bondingCurve.sell(params.to, params.token);
            if (quoteOut < params.amountOut) revert InsufficientOutput();
        }

        emit Sell(msg.sender, params.token, tokenUsed, quoteOut, graduated);
    }

    /// @inheritdoc INadFunRouter
    function exactOutSellToNative(ExactOutSellToNativeParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 nativeOut)
    {
        if (params.amountInMax == 0) revert InvalidAmountIn();
        if (params.amountOut == 0) revert InvalidAmountOut();
        if (params.to == address(0)) revert InvalidRecipient();

        bool graduated = _isGraduated(params.token);

        uint256 tokenUsed;
        if (graduated) {
            IERC20(params.token).safeTransferFrom(msg.sender, address(this), params.amountInMax);
            (tokenUsed, nativeOut) = _dexSwapExactOut(params.token, params.token, params.amountOut, address(this));
            if (tokenUsed > params.amountInMax) revert ExcessiveInput();
            uint256 tokenRefund = params.amountInMax - tokenUsed;
            if (tokenRefund > 0) IERC20(params.token).safeTransfer(msg.sender, tokenRefund);
        } else {
            tokenUsed = _bondingCurve.getAmountIn(params.token, params.amountOut, false);
            if (tokenUsed > params.amountInMax) revert ExcessiveInput();
            IERC20(params.token).safeTransferFrom(msg.sender, address(_bondingCurve), tokenUsed);
            nativeOut = _bondingCurve.sell(address(this), params.token);
            if (nativeOut < params.amountOut) revert InsufficientOutput();
        }

        _wrappedNative.withdraw(nativeOut);
        (bool success,) = params.to.call{value: nativeOut}("");
        if (!success) revert NativeTransferFailed();

        emit Sell(msg.sender, params.token, tokenUsed, nativeOut, graduated);
    }

    // ═══════════════════════════════════════════════
    //  View Functions
    // ═══════════════════════════════════════════════

    /// @notice Check if a token has graduated to DEX
    function isGraduated(address token) external view returns (bool) {
        return _isGraduated(token);
    }

    /// @inheritdoc INadFunRouter
    function getAmountOut(address token, uint256 amountIn, bool isBuy) external view returns (uint256) {
        return _isGraduated(token)
            ? _dexAmountOut(token, amountIn, isBuy)
            : _bondingCurve.getAmountOut(token, amountIn, isBuy);
    }

    /// @inheritdoc INadFunRouter
    function getAmountIn(address token, uint256 amountOut, bool isBuy) external view returns (uint256) {
        return _isGraduated(token)
            ? _dexAmountIn(token, amountOut, isBuy)
            : _bondingCurve.getAmountIn(token, amountOut, isBuy);
    }

    /// @notice Get bonding curve getAmountOut (pre-graduation only, includes all fees)
    function getBondingCurveAmountOut(address token, uint256 amountIn, bool isBuy) external view returns (uint256) {
        return _bondingCurve.getAmountOut(token, amountIn, isBuy);
    }

    /// @notice Get bonding curve getAmountIn (pre-graduation only, includes all fees)
    function getBondingCurveAmountIn(address token, uint256 amountOut, bool isBuy) external view returns (uint256) {
        return _bondingCurve.getAmountIn(token, amountOut, isBuy);
    }

    /// @inheritdoc INadFunRouter
    function getDexAmountOut(address token, uint256 amountIn, bool isBuy) external view returns (uint256 amountOut) {
        amountOut = _dexAmountOut(token, amountIn, isBuy);
    }

    /// @inheritdoc INadFunRouter
    function getDexAmountIn(address token, uint256 amountOut, bool isBuy) external view returns (uint256 amountIn) {
        amountIn = _dexAmountIn(token, amountOut, isBuy);
    }

    function _dexAmountOut(address token, uint256 amountIn, bool isBuy) internal view returns (uint256) {
        ITokenRegistry.TokenInfo memory info = _tokenRegistry.getTokenInfo(token);
        if (info.pair == address(0)) revert TokenNotGraduated();
        IDexAdapter adapter = _tokenRegistry.getAdapter(info.dexType);
        address tokenIn = isBuy ? info.quoteToken : token;
        return adapter.getAmountOut(info.pair, tokenIn, amountIn);
    }

    function _dexAmountIn(address token, uint256 amountOut, bool isBuy) internal view returns (uint256) {
        ITokenRegistry.TokenInfo memory info = _tokenRegistry.getTokenInfo(token);
        if (info.pair == address(0)) revert TokenNotGraduated();
        IDexAdapter adapter = _tokenRegistry.getAdapter(info.dexType);
        address tokenOut = isBuy ? token : info.quoteToken;
        return adapter.getAmountIn(info.pair, tokenOut, amountOut);
    }

    function bondingCurve() external view returns (address) {
        return address(_bondingCurve);
    }

    function tokenRegistry() external view returns (address) {
        return address(_tokenRegistry);
    }

    function wrappedNative() external view returns (address) {
        return address(_wrappedNative);
    }

    function lvMonMinter() external view returns (address) {
        return address(_lvMonMinter);
    }

    // authority() is inherited from AccessManagedUpgradeable (= ProtocolManager address)

    // ═══════════════════════════════════════════════
    //  DEX Swap Helpers
    // ═══════════════════════════════════════════════

    /// @dev Route swap through IDexAdapter. Transfers tokenIn to adapter, adapter handles pair interaction.
    function _dexSwap(address token, address tokenIn, uint256 amountIn, address to)
        internal
        returns (uint256 amountOut)
    {
        ITokenRegistry.TokenInfo memory info = _tokenRegistry.getTokenInfo(token);
        if (info.pair == address(0)) revert TokenNotGraduated();

        IDexAdapter adapter = _tokenRegistry.getAdapter(info.dexType);
        address tokenOut = tokenIn == token ? info.quoteToken : token;

        IERC20(tokenIn).safeTransfer(address(adapter), amountIn);
        amountOut = adapter.swap(info.pair, tokenIn, tokenOut, amountIn, to, "");
    }

    /// @dev Get required input for exact output via adapter, then execute swap.
    function _dexSwapExactOut(address token, address tokenIn, uint256 amountOut, address to)
        internal
        returns (uint256 amountIn, uint256 actualOut)
    {
        ITokenRegistry.TokenInfo memory info = _tokenRegistry.getTokenInfo(token);
        if (info.pair == address(0)) revert TokenNotGraduated();

        IDexAdapter adapter = _tokenRegistry.getAdapter(info.dexType);
        address tokenOut = tokenIn == token ? info.quoteToken : token;

        amountIn = adapter.getAmountIn(info.pair, tokenOut, amountOut);
        IERC20(tokenIn).safeTransfer(address(adapter), amountIn);

        actualOut = adapter.swap(info.pair, tokenIn, tokenOut, amountIn, to, "");
        if (actualOut < amountOut) revert InsufficientOutput();
    }

    // ═══════════════════════════════════════════════
    //  Common Helpers
    // ═══════════════════════════════════════════════

    function _isGraduated(address token) internal view returns (bool) {
        IBondingCurve.Curve memory curve = _bondingCurve.getCurve(token);
        if (curve.token == address(0)) revert TokenNotFound();
        return curve.graduated;
    }

    /// @dev Quote token is registered when the bonding curve token is created.
    function _getQuoteToken(address token) internal view returns (address quoteToken) {
        quoteToken = _tokenRegistry.getQuoteToken(token);
        if (quoteToken == address(0)) revert TokenNotFound();
    }

    /// @dev Native funding only supports WMON or the LV_MON token exposed by the configured minter.
    ///      Keeps exactly quoteIn on the router; any LVMon over-mint is returned as quote token.
    function _fundQuoteFromNative(address quoteToken, uint256 quoteIn) internal {
        address wmon = address(_wrappedNative);
        ILvMonMinter lvMonMinter_ = _lvMonMinter;
        address lvmon = address(lvMonMinter_) == address(0) ? address(0) : address(lvMonMinter_.lvmon());

        if (quoteToken == wmon) {
            _wrappedNative.deposit{value: quoteIn}();
        } else if (quoteToken == lvmon && lvmon != address(0)) {
            uint256 quoteBalanceBefore = IERC20(lvmon).balanceOf(address(this));
            lvMonMinter_.mint{value: quoteIn}(quoteIn);
            uint256 quoteMinted = IERC20(lvmon).balanceOf(address(this)) - quoteBalanceBefore;
            if (quoteMinted < quoteIn) revert InsufficientNativeQuoteMinted();

            uint256 quoteRefund = quoteMinted - quoteIn;
            if (quoteRefund > 0) IERC20(lvmon).safeTransfer(msg.sender, quoteRefund);
        } else {
            revert InvalidNativeQuoteToken();
        }
    }

    function _setLvMonMinter(address lvMonMinter_) internal {
        if (lvMonMinter_ != address(0)) {
            ILvMonMinter minter = ILvMonMinter(lvMonMinter_);
            if (address(minter.lvmon()) == address(0)) revert InvalidLvMonMinter();
        }
        _lvMonMinter = ILvMonMinter(lvMonMinter_);
    }

    function _transferNative(address to, uint256 nativeOut) internal {
        (bool success,) = to.call{value: nativeOut}("");
        if (!success) revert NativeTransferFailed();
    }

    /// @dev Short-circuits when the spender already has sufficient allowance. If an attacker
    ///      front-runs the same permit signature, the nonce is consumed but the allowance is
    ///      set, so we can proceed with transferFrom without re-invoking permit.
    function _permit(
        address token,
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        if (IERC20(token).allowance(owner_, spender) >= value) return;
        IERC20Permit(token).permit(owner_, spender, value, deadline, v, r, s);
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}
}
