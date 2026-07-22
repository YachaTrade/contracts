// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBondingCurve} from "../interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../interfaces/IGiwaRouter.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IWrappedNative} from "../interfaces/IWrappedNative.sol";
import {IV3SwapAdapter} from "../interfaces/IV3SwapAdapter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {IPeripheryImmutableState} from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GiwaRouter
/// @notice Unified user-facing router for token creation and lifecycle-aware trading.
/// @dev Preserves bonding-curve execution and routes graduated trades through the canonical V3SwapAdapter.
contract GiwaRouter is IGiwaRouter, UUPSUpgradeable, AccessManagedUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    struct V3ExactInputRequest {
        address payer;
        address token;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 deadline;
    }

    struct V3ExactOutputRequest {
        address payer;
        address token;
        address recipient;
        uint256 amountInMax;
        uint256 amountOut;
        uint256 deadline;
    }

    IBondingCurve private _bondingCurve;
    ITokenRegistry private _tokenRegistry;
    IWrappedNative private _wrappedNative;
    IV3SwapAdapter private _v3SwapAdapter;
    IQuoterV2 private _quoterV2;

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
        address v3SwapAdapter_,
        address quoterV2_
    ) external initializer {
        if (
            protocolManager_.code.length == 0 || bondingCurve_.code.length == 0 || tokenRegistry_.code.length == 0
                || wrappedNative_.code.length == 0 || v3SwapAdapter_.code.length == 0 || quoterV2_.code.length == 0
        ) revert InvalidDependency();

        IV3SwapAdapter swapAdapter = IV3SwapAdapter(v3SwapAdapter_);
        address v3Factory = swapAdapter.factory();
        if (
            swapAdapter.tokenRegistry() != tokenRegistry_ || v3Factory.code.length == 0
                || IPeripheryImmutableState(quoterV2_).factory() != v3Factory
        ) revert InvalidDependency();

        __AccessManaged_init(protocolManager_);
        _bondingCurve = IBondingCurve(bondingCurve_);
        _tokenRegistry = ITokenRegistry(tokenRegistry_);
        _wrappedNative = IWrappedNative(wrappedNative_);
        _v3SwapAdapter = swapAdapter;
        _quoterV2 = IQuoterV2(quoterV2_);
    }

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredDeadline();
        _;
    }

    // ═══════════════════════════════════════════════
    //  Token Creation
    // ═══════════════════════════════════════════════

    /// @inheritdoc IGiwaRouter
    function create(CreateParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (address token, uint256 tokenOut)
    {
        uint256 deployFee = IProtocolManager(authority()).deployFee(params.quoteToken);
        uint256 quoteRequired = deployFee + params.buyQuoteAmount;
        IERC20 quoteToken = IERC20(params.quoteToken);
        uint256 routerBalanceBefore = quoteToken.balanceOf(address(this));

        _pullExact(quoteToken, msg.sender, quoteRequired);
        (token, tokenOut) = _createOnCurve(params, quoteToken, quoteRequired);
        _requireBalanceEquals(quoteToken, address(this), routerBalanceBefore);

        emit Create(token, msg.sender);
    }

    /// @inheritdoc IGiwaRouter
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
        IERC20 quote = IERC20(quoteToken);
        uint256 routerBalanceBefore = quote.balanceOf(address(this));

        _fundQuoteFromNative(quoteToken, quoteRequired);
        (token, tokenOut) = _createOnCurve(params, quote, quoteRequired);
        _requireBalanceEquals(quote, address(this), routerBalanceBefore);

        uint256 refund = msg.value - quoteRequired;
        if (refund > 0) _transferNative(msg.sender, refund);

        emit Create(token, msg.sender);
    }

    // ═══════════════════════════════════════════════
    //  Buy
    // ═══════════════════════════════════════════════

    /// @inheritdoc IGiwaRouter
    function buy(BuyParams calldata params) external nonReentrant ensure(params.deadline) returns (uint256 amountOut) {
        _validateExactInput(params.amountIn, params.to);
        amountOut = _buyErc20(
            V3ExactInputRequest({
                payer: msg.sender,
                token: params.token,
                recipient: params.to,
                amountIn: params.amountIn,
                amountOutMin: params.amountOutMin,
                deadline: params.deadline
            })
        );
    }

    /// @inheritdoc IGiwaRouter
    function buyWithNative(BuyWithNativeParams calldata params)
        external
        payable
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        _validateExactInput(msg.value, params.to);
        _requireNativeQuoteToken(params.token);

        bool graduated = _isGraduated(params.token);
        uint256 quoteIn;
        uint256 refund;

        if (graduated) {
            _wrappedNative.deposit{value: msg.value}();
            (quoteIn, amountOut) = _buyV3(
                V3ExactInputRequest({
                    payer: address(this),
                    token: params.token,
                    recipient: params.to,
                    amountIn: msg.value,
                    amountOutMin: params.amountOutMin,
                    deadline: params.deadline
                })
            );
            refund = msg.value - quoteIn;
        } else {
            IERC20 quoteToken = IERC20(address(_wrappedNative));
            uint256 routerBalanceBefore = quoteToken.balanceOf(address(this));
            uint256 tokenOut = _bondingCurve.getAmountOut(params.token, msg.value, true);
            quoteIn = tokenOut == 0 ? msg.value : _bondingCurve.getAmountIn(params.token, tokenOut, true);
            if (quoteIn > msg.value) quoteIn = msg.value;
            _wrappedNative.deposit{value: quoteIn}();
            amountOut = _buyOnCurve(params.token, params.to, quoteToken, quoteIn);
            _requireBalanceEquals(quoteToken, address(this), routerBalanceBefore);
            refund = msg.value - quoteIn;
        }

        if (amountOut < params.amountOutMin) revert InsufficientOutput();
        _refundNative(msg.sender, refund, graduated);
        emit Buy(msg.sender, params.token, quoteIn, amountOut, graduated);
    }

    /// @inheritdoc IGiwaRouter
    function buyWithPermit(BuyWithPermitParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        _validateExactInput(params.amountIn, params.to);
        if (params.amountAllowance < params.amountIn) revert InvalidAllowance();

        address quoteToken = _getQuoteToken(params.token);
        _permit(
            quoteToken, msg.sender, address(this), params.amountAllowance, params.deadline, params.v, params.r, params.s
        );

        amountOut = _buyErc20(
            V3ExactInputRequest({
                payer: msg.sender,
                token: params.token,
                recipient: params.to,
                amountIn: params.amountIn,
                amountOutMin: params.amountOutMin,
                deadline: params.deadline
            })
        );
    }

    // ═══════════════════════════════════════════════
    //  Sell
    // ═══════════════════════════════════════════════

    /// @inheritdoc IGiwaRouter
    function sell(SellParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        _validateExactInput(params.amountIn, params.to);

        amountOut = _sell(
            V3ExactInputRequest({
                payer: msg.sender,
                token: params.token,
                recipient: params.to,
                amountIn: params.amountIn,
                amountOutMin: params.amountOutMin,
                deadline: params.deadline
            }),
            false
        );
    }

    /// @inheritdoc IGiwaRouter
    function sellToNative(SellToNativeParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        _validateExactInput(params.amountIn, params.to);
        _requireNativeQuoteToken(params.token);
        amountOut = _sell(
            V3ExactInputRequest({
                payer: msg.sender,
                token: params.token,
                recipient: params.to,
                amountIn: params.amountIn,
                amountOutMin: params.amountOutMin,
                deadline: params.deadline
            }),
            true
        );
    }

    /// @inheritdoc IGiwaRouter
    function sellWithPermit(SellWithPermitParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        _validateExactInput(params.amountIn, params.to);
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

        amountOut = _sell(
            V3ExactInputRequest({
                payer: msg.sender,
                token: params.token,
                recipient: params.to,
                amountIn: params.amountIn,
                amountOutMin: params.amountOutMin,
                deadline: params.deadline
            }),
            false
        );
    }

    /// @inheritdoc IGiwaRouter
    function sellToNativeWithPermit(SellToNativeWithPermitParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        _validateExactInput(params.amountIn, params.to);
        if (params.amountAllowance < params.amountIn) revert InvalidAllowance();
        _requireNativeQuoteToken(params.token);
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
        amountOut = _sell(
            V3ExactInputRequest({
                payer: msg.sender,
                token: params.token,
                recipient: params.to,
                amountIn: params.amountIn,
                amountOutMin: params.amountOutMin,
                deadline: params.deadline
            }),
            true
        );
    }

    // ═══════════════════════════════════════════════
    //  Exact Output
    // ═══════════════════════════════════════════════

    /// @inheritdoc IGiwaRouter
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
            amountIn = _exactOutBuyV3(
                V3ExactOutputRequest({
                    payer: msg.sender,
                    token: params.token,
                    recipient: params.to,
                    amountInMax: params.amountInMax,
                    amountOut: params.amountOut,
                    deadline: params.deadline
                })
            );
        } else {
            address quoteToken = _getQuoteToken(params.token);
            IERC20 quote = IERC20(quoteToken);
            uint256 routerBalanceBefore = quote.balanceOf(address(this));
            amountIn = _bondingCurve.getAmountIn(params.token, params.amountOut, true);
            if (amountIn > params.amountInMax) revert ExcessiveInput();
            _pullExact(quote, msg.sender, params.amountInMax);
            uint256 tokenOut = _buyOnCurve(params.token, params.to, quote, amountIn);
            if (tokenOut < params.amountOut) revert InsufficientOutput();
            uint256 refund = params.amountInMax - amountIn;
            _pushExact(quote, msg.sender, refund);
            _requireBalanceEquals(quote, address(this), routerBalanceBefore);
        }

        emit Buy(msg.sender, params.token, amountIn, params.amountOut, graduated);
    }

    /// @inheritdoc IGiwaRouter
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
        _requireNativeQuoteToken(params.token);

        bool graduated = _isGraduated(params.token);

        if (graduated) {
            _wrappedNative.deposit{value: msg.value}();
            amountIn = _exactOutBuyV3(
                V3ExactOutputRequest({
                    payer: address(this),
                    token: params.token,
                    recipient: params.to,
                    amountInMax: msg.value,
                    amountOut: params.amountOut,
                    deadline: params.deadline
                })
            );
        } else {
            IERC20 quoteToken = IERC20(address(_wrappedNative));
            uint256 routerBalanceBefore = quoteToken.balanceOf(address(this));
            amountIn = _bondingCurve.getAmountIn(params.token, params.amountOut, true);
            if (amountIn > msg.value) revert ExcessiveInput();
            _wrappedNative.deposit{value: amountIn}();
            uint256 tokenOut = _buyOnCurve(params.token, params.to, quoteToken, amountIn);
            _requireBalanceEquals(quoteToken, address(this), routerBalanceBefore);
            if (tokenOut < params.amountOut) revert InsufficientOutput();
        }

        uint256 refund = msg.value - amountIn;
        _refundNative(msg.sender, refund, graduated);

        emit Buy(msg.sender, params.token, amountIn, params.amountOut, graduated);
    }

    /// @inheritdoc IGiwaRouter
    function exactOutSell(ExactOutSellParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 tokenIn)
    {
        if (params.amountInMax == 0) revert InvalidAmountIn();
        if (params.amountOut == 0) revert InvalidAmountOut();
        if (params.to == address(0)) revert InvalidRecipient();

        tokenIn = _exactOutSell(
            V3ExactOutputRequest({
                payer: msg.sender,
                token: params.token,
                recipient: params.to,
                amountInMax: params.amountInMax,
                amountOut: params.amountOut,
                deadline: params.deadline
            }),
            false
        );
    }

    /// @inheritdoc IGiwaRouter
    function exactOutSellToNative(ExactOutSellToNativeParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 tokenIn)
    {
        if (params.amountInMax == 0) revert InvalidAmountIn();
        if (params.amountOut == 0) revert InvalidAmountOut();
        if (params.to == address(0)) revert InvalidRecipient();
        _requireNativeQuoteToken(params.token);

        tokenIn = _exactOutSell(
            V3ExactOutputRequest({
                payer: msg.sender,
                token: params.token,
                recipient: params.to,
                amountInMax: params.amountInMax,
                amountOut: params.amountOut,
                deadline: params.deadline
            }),
            true
        );
    }

    // ═══════════════════════════════════════════════
    //  Quote and View Functions
    // ═══════════════════════════════════════════════

    /// @notice Check if a token has graduated to DEX
    function isGraduated(address token) external view returns (bool) {
        return _isGraduated(token);
    }

    /// @inheritdoc IGiwaRouter
    function getAmountOut(address token, uint256 amountIn, bool isBuy) external returns (uint256) {
        return _isGraduated(token)
            ? _dexAmountOut(token, amountIn, isBuy)
            : _bondingCurve.getAmountOut(token, amountIn, isBuy);
    }

    /// @inheritdoc IGiwaRouter
    function getAmountIn(address token, uint256 amountOut, bool isBuy) external returns (uint256) {
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

    /// @inheritdoc IGiwaRouter
    function getDexAmountOut(address token, uint256 amountIn, bool isBuy) external returns (uint256 amountOut) {
        amountOut = _dexAmountOut(token, amountIn, isBuy);
    }

    /// @inheritdoc IGiwaRouter
    function getDexAmountIn(address token, uint256 amountOut, bool isBuy) external returns (uint256 amountIn) {
        amountIn = _dexAmountIn(token, amountOut, isBuy);
    }

    function _dexAmountOut(address token, uint256 amountIn, bool isBuy) private returns (uint256 amountOut) {
        if (amountIn == 0) revert InvalidAmountIn();
        ITokenRegistry.TokenInfo memory info = _v3Info(token);
        uint256 protocolFeeRate = _dexProtocolFeeRate(info.quoteToken);
        address tokenIn = isBuy ? info.quoteToken : token;
        address tokenOut = isBuy ? token : info.quoteToken;
        uint256 poolAmountIn = isBuy ? amountIn - _protocolFee(amountIn, protocolFeeRate) : amountIn;
        if (poolAmountIn == 0) revert InvalidAmountIn();
        (amountOut,,,) = _quoterV2.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: poolAmountIn,
                fee: info.feeTier,
                sqrtPriceLimitX96: _priceLimit(tokenIn, tokenOut)
            })
        );
        if (!isBuy) amountOut -= _protocolFee(amountOut, protocolFeeRate);
    }

    function _dexAmountIn(address token, uint256 amountOut, bool isBuy) private returns (uint256 amountIn) {
        if (amountOut == 0) revert InvalidAmountOut();
        ITokenRegistry.TokenInfo memory info = _v3Info(token);
        uint256 protocolFeeRate = _dexProtocolFeeRate(info.quoteToken);
        address tokenIn = isBuy ? info.quoteToken : token;
        address tokenOut = isBuy ? token : info.quoteToken;
        uint256 poolAmountOut = isBuy ? amountOut : _grossUp(amountOut, protocolFeeRate);
        (amountIn,,,) = _quoterV2.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, amount: poolAmountOut, fee: info.feeTier, sqrtPriceLimitX96: 0
            })
        );
        if (isBuy) amountIn = _grossUp(amountIn, protocolFeeRate);
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

    function v3SwapAdapter() external view returns (address) {
        return address(_v3SwapAdapter);
    }

    function quoterV2() external view returns (address) {
        return address(_quoterV2);
    }

    // authority() is inherited from AccessManagedUpgradeable (= ProtocolManager address)

    // ═══════════════════════════════════════════════
    //  Common Helpers
    // ═══════════════════════════════════════════════

    function _createOnCurve(CreateParams calldata params, IERC20 quoteToken, uint256 quoteRequired)
        private
        returns (address token, uint256 tokenOut)
    {
        quoteToken.forceApprove(address(_bondingCurve), quoteRequired);
        (token, tokenOut) = _bondingCurve.create(
            IBondingCurve.CreateTokenParams({
                name: params.name,
                symbol: params.symbol,
                tokenURI: params.tokenURI,
                quoteToken: params.quoteToken,
                vaults: params.vaults,
                salt: params.salt,
                dexType: params.dexType,
                creator: msg.sender,
                buyQuoteAmount: params.buyQuoteAmount
            })
        );
        quoteToken.forceApprove(address(_bondingCurve), 0);
    }

    function _validateExactInput(uint256 amountIn, address recipient) private pure {
        if (amountIn == 0) revert InvalidAmountIn();
        if (recipient == address(0)) revert InvalidRecipient();
    }

    function _buyOnCurve(address token, address recipient, IERC20 quoteToken, uint256 quoteIn)
        private
        returns (uint256 tokenOut)
    {
        quoteToken.forceApprove(address(_bondingCurve), quoteIn);
        tokenOut = _bondingCurve.buy(recipient, token, quoteIn);
        quoteToken.forceApprove(address(_bondingCurve), 0);
    }

    function _sellOnCurve(address token, address recipient, IERC20 launchToken, uint256 tokenIn)
        private
        returns (uint256 quoteOut)
    {
        launchToken.forceApprove(address(_bondingCurve), tokenIn);
        quoteOut = _bondingCurve.sell(recipient, token, tokenIn);
        launchToken.forceApprove(address(_bondingCurve), 0);
    }

    function _buyErc20(V3ExactInputRequest memory request) private returns (uint256 tokenOut) {
        bool graduated = _isGraduated(request.token);
        uint256 quoteIn;

        if (graduated) {
            (quoteIn, tokenOut) = _buyV3(request);
        } else {
            address quoteToken = _getQuoteToken(request.token);
            IERC20 quote = IERC20(quoteToken);
            uint256 routerBalanceBefore = quote.balanceOf(address(this));
            uint256 tokenOutFromCurve = _bondingCurve.getAmountOut(request.token, request.amountIn, true);
            quoteIn = tokenOutFromCurve == 0
                ? request.amountIn
                : _bondingCurve.getAmountIn(request.token, tokenOutFromCurve, true);
            if (quoteIn > request.amountIn) quoteIn = request.amountIn;
            _pullExact(quote, request.payer, request.amountIn);
            tokenOut = _buyOnCurve(request.token, request.recipient, quote, quoteIn);
            if (tokenOut < request.amountOutMin) revert InsufficientOutput();
            uint256 quoteRefund = request.amountIn - quoteIn;
            _pushExact(quote, request.payer, quoteRefund);
            _requireBalanceEquals(quote, address(this), routerBalanceBefore);
        }

        emit Buy(request.payer, request.token, quoteIn, tokenOut, graduated);
    }

    function _sell(V3ExactInputRequest memory request, bool native) private returns (uint256 quoteOut) {
        bool graduated = _isGraduated(request.token);
        uint256 tokenIn = request.amountIn;
        address recipient = request.recipient;
        IERC20 nativeQuoteToken;
        uint256 nativeQuoteBalanceBefore;
        if (native && !graduated) {
            nativeQuoteToken = IERC20(_getQuoteToken(request.token));
            nativeQuoteBalanceBefore = nativeQuoteToken.balanceOf(address(this));
        }
        if (native) request.recipient = address(this);

        if (graduated) {
            (tokenIn, quoteOut) = _sellV3(request);
        } else {
            IERC20 launchToken = IERC20(request.token);
            uint256 routerTokenBalanceBefore = launchToken.balanceOf(address(this));
            _pullExact(launchToken, request.payer, request.amountIn);
            quoteOut = _sellOnCurve(request.token, request.recipient, launchToken, request.amountIn);
            _requireBalanceEquals(launchToken, address(this), routerTokenBalanceBefore);
        }

        if (quoteOut < request.amountOutMin) revert InsufficientOutput();
        if (native) {
            _unwrapAndTransferNative(recipient, quoteOut);
            if (!graduated) _requireBalanceEquals(nativeQuoteToken, address(this), nativeQuoteBalanceBefore);
        }
        emit Sell(request.payer, request.token, tokenIn, quoteOut, graduated);
    }

    function _exactOutSell(V3ExactOutputRequest memory request, bool native) private returns (uint256 tokenIn) {
        bool graduated = _isGraduated(request.token);
        uint256 quoteOut;
        address recipient = request.recipient;
        IERC20 nativeQuoteToken;
        uint256 nativeQuoteBalanceBefore;
        if (native && !graduated) {
            nativeQuoteToken = IERC20(_getQuoteToken(request.token));
            nativeQuoteBalanceBefore = nativeQuoteToken.balanceOf(address(this));
        }
        if (native) request.recipient = address(this);

        if (graduated) {
            (tokenIn, quoteOut) = _exactOutSellV3(request);
        } else {
            tokenIn = _bondingCurve.getAmountIn(request.token, request.amountOut, false);
            if (tokenIn > request.amountInMax) revert ExcessiveInput();
            IERC20 launchToken = IERC20(request.token);
            uint256 routerTokenBalanceBefore = launchToken.balanceOf(address(this));
            _pullExact(launchToken, request.payer, tokenIn);
            quoteOut = _sellOnCurve(request.token, request.recipient, launchToken, tokenIn);
            _requireBalanceEquals(launchToken, address(this), routerTokenBalanceBefore);
            if (quoteOut < request.amountOut) revert InsufficientOutput();
        }

        if (native) {
            _unwrapAndTransferNative(recipient, quoteOut);
            if (!graduated) _requireBalanceEquals(nativeQuoteToken, address(this), nativeQuoteBalanceBefore);
        }
        emit Sell(request.payer, request.token, tokenIn, quoteOut, graduated);
    }

    function _buyV3(V3ExactInputRequest memory request)
        private
        returns (uint256 quoteInWithProtocolFee, uint256 tokenOut)
    {
        ITokenRegistry.TokenInfo memory info = _v3Info(request.token);
        uint256 protocolFeeRate = _dexProtocolFeeRate(info.quoteToken);
        uint256 protocolFeeMax = _protocolFee(request.amountIn, protocolFeeRate);
        uint256 poolQuoteInMax = request.amountIn - protocolFeeMax;
        if (poolQuoteInMax == 0) revert InvalidAmountIn();

        IERC20 quoteToken = IERC20(info.quoteToken);
        _pullExact(quoteToken, request.payer, request.amountIn);
        quoteToken.forceApprove(address(_v3SwapAdapter), poolQuoteInMax);
        (uint256 quoteIn, uint256 tokenOutFromPool) =
            _exactInputV3(request.token, info.quoteToken, poolQuoteInMax, request.recipient, request.deadline);
        quoteToken.forceApprove(address(_v3SwapAdapter), 0);

        tokenOut = tokenOutFromPool;
        if (tokenOut < request.amountOutMin) revert InsufficientOutput();
        uint256 protocolFee =
            protocolFeeMax == 0 ? 0 : FullMath.mulDivRoundingUp(protocolFeeMax, quoteIn, poolQuoteInMax);
        quoteInWithProtocolFee = quoteIn + protocolFee;

        _payProtocolFee(quoteToken, protocolFee);
        uint256 quoteRefund = request.amountIn - quoteInWithProtocolFee;
        _pushExact(quoteToken, request.payer, quoteRefund);
    }

    function _sellV3(V3ExactInputRequest memory request) private returns (uint256 tokenIn, uint256 quoteOut) {
        ITokenRegistry.TokenInfo memory info = _v3Info(request.token);
        uint256 protocolFeeRate = _dexProtocolFeeRate(info.quoteToken);
        IERC20 launchToken = IERC20(request.token);

        _pullExact(launchToken, request.payer, request.amountIn);
        launchToken.forceApprove(address(_v3SwapAdapter), request.amountIn);
        uint256 quoteOutBeforeProtocolFee;
        (tokenIn, quoteOutBeforeProtocolFee) =
            _exactInputV3(request.token, request.token, request.amountIn, address(this), request.deadline);
        launchToken.forceApprove(address(_v3SwapAdapter), 0);

        uint256 tokenRefund = request.amountIn - tokenIn;
        _pushExact(launchToken, request.payer, tokenRefund);

        uint256 protocolFee = _protocolFee(quoteOutBeforeProtocolFee, protocolFeeRate);
        quoteOut = quoteOutBeforeProtocolFee - protocolFee;
        if (quoteOut < request.amountOutMin) revert InsufficientOutput();

        IERC20 quoteToken = IERC20(info.quoteToken);
        _payProtocolFee(quoteToken, protocolFee);
        _pushExact(quoteToken, request.recipient, quoteOut);
    }

    function _exactOutBuyV3(V3ExactOutputRequest memory request) private returns (uint256 quoteInWithProtocolFee) {
        ITokenRegistry.TokenInfo memory info = _v3Info(request.token);
        uint256 protocolFeeRate = _dexProtocolFeeRate(info.quoteToken);
        uint256 protocolFeeMax = _protocolFee(request.amountInMax, protocolFeeRate);
        uint256 poolQuoteInMax = request.amountInMax - protocolFeeMax;
        if (poolQuoteInMax == 0) revert InvalidAmountIn();

        IERC20 quoteToken = IERC20(info.quoteToken);
        _pullExact(quoteToken, request.payer, request.amountInMax);
        quoteToken.forceApprove(address(_v3SwapAdapter), poolQuoteInMax);
        (uint256 poolQuoteIn, uint256 tokenOut) = _exactOutputV3(
            request.token, info.quoteToken, request.amountOut, poolQuoteInMax, request.recipient, request.deadline
        );
        quoteToken.forceApprove(address(_v3SwapAdapter), 0);
        if (tokenOut != request.amountOut) revert InsufficientOutput();

        quoteInWithProtocolFee = _grossUp(poolQuoteIn, protocolFeeRate);
        if (quoteInWithProtocolFee > request.amountInMax) revert ExcessiveInput();
        uint256 protocolFee = quoteInWithProtocolFee - poolQuoteIn;
        _payProtocolFee(quoteToken, protocolFee);
        _pushExact(quoteToken, request.payer, request.amountInMax - quoteInWithProtocolFee);
    }

    function _exactOutSellV3(V3ExactOutputRequest memory request) private returns (uint256 tokenIn, uint256 quoteOut) {
        ITokenRegistry.TokenInfo memory info = _v3Info(request.token);
        uint256 protocolFeeRate = _dexProtocolFeeRate(info.quoteToken);
        uint256 quoteOutBeforeProtocolFee = _grossUp(request.amountOut, protocolFeeRate);
        IERC20 launchToken = IERC20(request.token);

        _pullExact(launchToken, request.payer, request.amountInMax);
        launchToken.forceApprove(address(_v3SwapAdapter), request.amountInMax);
        uint256 quoteOutFromPool;
        (tokenIn, quoteOutFromPool) = _exactOutputV3(
            request.token,
            request.token,
            quoteOutBeforeProtocolFee,
            request.amountInMax,
            address(this),
            request.deadline
        );
        launchToken.forceApprove(address(_v3SwapAdapter), 0);
        if (quoteOutFromPool != quoteOutBeforeProtocolFee) revert InsufficientOutput();

        _pushExact(launchToken, request.payer, request.amountInMax - tokenIn);
        quoteOut = request.amountOut;
        IERC20 quoteToken = IERC20(info.quoteToken);
        _payProtocolFee(quoteToken, quoteOutBeforeProtocolFee - quoteOut);
        _pushExact(quoteToken, request.recipient, quoteOut);
    }

    function _exactInputV3(address token, address tokenIn, uint256 amountIn, address recipient, uint256 deadline)
        private
        returns (uint256 amountInUsed, uint256 amountOut)
    {
        address tokenOut = tokenIn == token ? _tokenRegistry.getQuoteToken(token) : token;
        return _v3SwapAdapter.exactInput(
            IV3SwapAdapter.ExactInputParams({
                token: token,
                tokenIn: tokenIn,
                amountIn: amountIn,
                amountOutMin: 0,
                recipient: recipient,
                sqrtPriceLimitX96: _priceLimit(tokenIn, tokenOut),
                deadline: deadline
            })
        );
    }

    function _exactOutputV3(
        address token,
        address tokenIn,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        uint256 deadline
    ) private returns (uint256 amountIn, uint256 amountOutFromPool) {
        address tokenOut = tokenIn == token ? _tokenRegistry.getQuoteToken(token) : token;
        IV3SwapAdapter.ExactOutputParams memory params = IV3SwapAdapter.ExactOutputParams({
            token: token,
            tokenIn: tokenIn,
            amountOut: amountOut,
            amountInMax: amountInMax,
            recipient: recipient,
            sqrtPriceLimitX96: _priceLimit(tokenIn, tokenOut),
            deadline: deadline
        });
        try _v3SwapAdapter.exactOutput(params) returns (uint256 amountIn_, uint256 amountOut_) {
            amountIn = amountIn_;
            amountOutFromPool = amountOut_;
        } catch (bytes memory reason) {
            bytes4 selector;
            if (reason.length == 68) {
                assembly ("memory-safe") {
                    selector := mload(add(reason, 0x20))
                }
                if (selector == IV3SwapAdapter.ExcessiveCallbackAmount.selector) revert ExcessiveInput();
            }
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function _v3Info(address token) private view returns (ITokenRegistry.TokenInfo memory info) {
        info = _tokenRegistry.getTokenInfo(token);
        if (
            info.pool == address(0) || info.pool != info.pair || info.pool.code.length == 0
                || info.quoteToken == address(0) || info.dexType != ITokenRegistry.DexType.UniswapV3
                || info.feeTier == 0 || _tokenRegistry.getTokenByPool(info.pool) != token
        ) revert InvalidV3Pool();
        if (!IProtocolManager(authority()).isAllowed(info.quoteToken)) revert InvalidV3Quote();

        if (IUniswapV3Factory(_v3SwapAdapter.factory()).getPool(token, info.quoteToken, info.feeTier) != info.pool) {
            revert InvalidV3Pool();
        }
    }

    function _dexProtocolFeeRate(address quoteToken) private view returns (uint256 protocolFeeRate) {
        protocolFeeRate = IProtocolManager(authority()).dexProtocolFeeRate(quoteToken);
        if (protocolFeeRate >= BPS) revert InvalidDexFeeRate();
    }

    function _protocolFee(uint256 quoteAmount, uint256 protocolFeeRate) private pure returns (uint256) {
        return protocolFeeRate == 0 ? 0 : FullMath.mulDivRoundingUp(quoteAmount, protocolFeeRate, BPS);
    }

    function _grossUp(uint256 quoteAmount, uint256 protocolFeeRate) private pure returns (uint256) {
        if (protocolFeeRate >= BPS) revert InvalidDexFeeRate();
        return protocolFeeRate == 0 ? quoteAmount : FullMath.mulDivRoundingUp(quoteAmount, BPS, BPS - protocolFeeRate);
    }

    function _payProtocolFee(IERC20 quoteToken, uint256 protocolFee) private {
        if (protocolFee == 0) return;
        address feeReceiver = IProtocolManager(authority()).feeReceiver();
        if (feeReceiver == address(0) || feeReceiver == address(this)) revert InvalidRecipient();
        _pushExact(quoteToken, feeReceiver, protocolFee);
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private {
        if (amount == 0 || from == address(this)) return;
        uint256 senderBalanceBefore = token.balanceOf(from);
        uint256 routerBalanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        _requireBalanceDecrease(token, from, senderBalanceBefore, amount);
        _requireBalanceIncrease(token, address(this), routerBalanceBefore, amount);
    }

    function _pushExact(IERC20 token, address to, uint256 amount) private {
        if (amount == 0 || to == address(this)) return;
        uint256 routerBalanceBefore = token.balanceOf(address(this));
        uint256 recipientBalanceBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        _requireBalanceDecrease(token, address(this), routerBalanceBefore, amount);
        _requireBalanceIncrease(token, to, recipientBalanceBefore, amount);
    }

    function _requireBalanceDecrease(IERC20 token, address account, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        uint256 currentBalance = token.balanceOf(account);
        uint256 requiredBalance = balanceBefore >= amount ? balanceBefore - amount : 0;
        if (balanceBefore < amount || currentBalance != requiredBalance) {
            revert InvalidBalanceDelta(address(token), account, requiredBalance, currentBalance);
        }
    }

    function _requireBalanceIncrease(IERC20 token, address account, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        if (amount > type(uint256).max - balanceBefore) {
            revert InvalidBalanceDelta(address(token), account, type(uint256).max, token.balanceOf(account));
        }
        uint256 requiredBalance = balanceBefore + amount;
        uint256 currentBalance = token.balanceOf(account);
        if (currentBalance != requiredBalance) {
            revert InvalidBalanceDelta(address(token), account, requiredBalance, currentBalance);
        }
    }

    function _requireBalanceEquals(IERC20 token, address account, uint256 requiredBalance) private view {
        uint256 currentBalance = token.balanceOf(account);
        if (currentBalance != requiredBalance) {
            revert InvalidBalanceDelta(address(token), account, requiredBalance, currentBalance);
        }
    }

    function _priceLimit(address tokenIn, address tokenOut) private pure returns (uint160) {
        return tokenIn < tokenOut ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
    }

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

    function _fundQuoteFromNative(address quoteToken, uint256 quoteIn) private {
        if (quoteToken != address(_wrappedNative)) revert InvalidNativeQuoteToken();
        _wrappedNative.deposit{value: quoteIn}();
    }

    function _requireNativeQuoteToken(address token) private view {
        if (_getQuoteToken(token) != address(_wrappedNative)) revert InvalidNativeQuoteToken();
    }

    function _refundNative(address recipient, uint256 nativeRefund, bool unwrap) private {
        if (nativeRefund == 0) return;
        if (unwrap) _wrappedNative.withdraw(nativeRefund);
        _transferNative(recipient, nativeRefund);
    }

    function _unwrapAndTransferNative(address recipient, uint256 nativeOut) private {
        _wrappedNative.withdraw(nativeOut);
        _transferNative(recipient, nativeOut);
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
