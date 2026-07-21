// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "../interfaces/IVault.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IToken} from "../interfaces/IToken.sol";
import {INadFunPair} from "../dex/interfaces/INadFunPair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BPS} from "../libraries/Constants.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

//
//
//
//

/// @notice Receives quoteToken, swaps half to token via IDexAdapter, adds liquidity, burns LP.
///
contract LPVault is IVault, UUPSUpgradeable, AccessManagedUpgradeable {
    using SafeERC20 for IERC20;

    address private constant BURN_ADDRESS = address(0xdead);

    /// @dev Must mirror `NadFunPair.LP_FEE_RATE`. Used by the zap math when splitting the incoming
    ///      quoteToken amount optimally between the swap leg and the addLiquidity leg.
    uint256 private constant LP_FEE_RATE = 25;

    ITokenRegistry public tokenRegistry;
    address public creatorFeeProcessor;

    /// @notice Per-token accumulated quoteToken balance.
    /// @dev LPVault is a singleton shared by many tokens. Tracking balances
    ///      via IERC20.balanceOf(this) would comingle funds across tokens;
    ///      we keep a dedicated counter so each token owns only its portion.
    mapping(address token => uint256) private _accumulatedQuote;

    /// @inheritdoc IVault
    string public metadataURI;

    event AddLiquidity(
        address indexed token, address indexed pair, uint256 quoteUsed, uint256 tokenUsed, uint256 lpBurned
    );

    error NotAuthorized();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address protocolManager_,
        address tokenRegistry_,
        address creatorFeeProcessor_,
        string calldata metadataURI_
    ) external initializer {
        require(tokenRegistry_ != address(0), "Zero tokenRegistry");
        require(creatorFeeProcessor_ != address(0), "Zero creatorFeeProcessor");

        __AccessManaged_init(protocolManager_);

        tokenRegistry = ITokenRegistry(tokenRegistry_);
        creatorFeeProcessor = creatorFeeProcessor_;
        metadataURI = metadataURI_;
    }

    /// @inheritdoc IVault
    //
    function afterDeposit(address token, address quoteToken, uint256 amount) external {
        if (msg.sender != creatorFeeProcessor) revert NotAuthorized();
        if (amount > 0) _accumulatedQuote[token] += amount;

        // Pre-graduation: accumulate per-token and defer processing.
        if (!IToken(token).isGraduated()) {
            return;
        }

        try this.executePendingZap(token, quoteToken) {}
        catch {
            return;
        }
    }

    function executePendingZap(address token, address quoteToken) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        if (!IToken(token).isGraduated()) return;

        // Post-graduation: use the token's tracked accumulation.
        // Never peek at balanceOf(this), otherwise we would drain other tokens' funds held
        // by this singleton.
        uint256 totalQuote = _accumulatedQuote[token];
        if (totalQuote == 0) return;

        ITokenRegistry.TokenInfo memory info = tokenRegistry.getTokenInfo(token);

        // Compute the optimal zap split: swap `swapQuote` of quoteToken for the paired token,
        // leaving `addQuote = totalQuote - swapQuote` to deposit alongside the tokens received.
        // A naive 50/50 split would leave residual dust in the pool (benefiting other LPs) because
        // the swap itself moves the price. The closed-form solution picks `swapQuote` such that
        // post-swap reserves match the (addQuote, tokenReceived) ratio, consuming totalQuote fully.
        uint256 quoteReserve = _getQuoteReserve(info.pair, quoteToken);
        uint256 swapQuote = _computeZapSwap(totalQuote, quoteReserve);
        if (swapQuote == 0 || swapQuote >= totalQuote) {
            // Can't compute a valid zap split (empty reserve or totalQuote too small). Carry
            // the balance over — do NOT reset accumulation or attempt a partial deposit.
            _accumulatedQuote[token] = totalQuote;
            return;
        }

        // Commit to zap: reset accumulation before any external call.
        _accumulatedQuote[token] = 0;
        uint256 addQuote = totalQuote - swapQuote;

        IDexAdapter adapter = tokenRegistry.getAdapter(info.dexType);
        IERC20(quoteToken).safeTransfer(address(adapter), swapQuote);
        uint256 tokenReceived = adapter.swap(info.pair, quoteToken, token, swapQuote, address(this), "");

        if (tokenReceived == 0 || addQuote == 0) return;

        IERC20(token).safeTransfer(address(adapter), tokenReceived);
        IERC20(quoteToken).safeTransfer(address(adapter), addQuote);
        uint256 lpAmount = adapter.addLiquidity(info.pair, token, quoteToken, tokenReceived, addQuote, BURN_ADDRESS);

        emit AddLiquidity(token, info.pair, addQuote, tokenReceived, lpAmount);
    }

    /// @dev Reads the pair's reserve for `quoteToken` directly (not the adapter) since this is
    ///      V2-specific math and we need the raw reserve values.
    function _getQuoteReserve(address pair, address quoteToken) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = INadFunPair(pair).getReserves();
        return quoteToken == INadFunPair(pair).token0() ? uint256(r0) : uint256(r1);
    }

    /// @dev V2 zap math. Solves for the amount `s` of quoteToken to swap such that the remaining
    ///      `totalQuote - s` is exactly the amount of quoteToken that pairs with the received
    ///      tokens at the post-swap reserve ratio. Derived from:
    ///         (Q - s) / tokenOut(s) == (R_q + s) / (R_t - tokenOut(s))
    ///      with `tokenOut(s) = R_t * s * (BPS - f) / (R_q * BPS + s * (BPS - f))` accounting for
    ///      the LP fee `f` charged by NadFunPair. (During settlement the pair waives the creator
    ///      and protocol fees, so only LP fee matters here.) Simplifies to the quadratic:
    ///         (BPS - f) * s^2 + R_q * (2*BPS - f) * s - Q * R_q * BPS == 0
    ///      Positive root:
    ///         s = (sqrt(R_q^2 * (2*BPS - f)^2 + 4 * (BPS - f) * BPS * Q * R_q) - R_q * (2*BPS - f))
    ///             / (2 * (BPS - f))
    function _computeZapSwap(uint256 totalQuote, uint256 quoteReserve) internal pure returns (uint256) {
        if (totalQuote == 0 || quoteReserve == 0) return 0;
        uint256 feeAdj = BPS - LP_FEE_RATE;
        uint256 twoMinusF = (2 * BPS) - LP_FEE_RATE;
        uint256 b = quoteReserve * twoMinusF;
        uint256 discriminant = b * b + 4 * feeAdj * BPS * totalQuote * quoteReserve;
        uint256 sqrtDisc = FixedPointMathLib.sqrt(discriminant);
        return (sqrtDisc - b) / (2 * feeAdj);
    }

    /// @notice Returns the per-token quoteToken amount LPVault has accumulated
    ///         while the token is still in the bonding phase.
    /// @dev Resets to zero once the token graduates and the next afterDeposit
    ///      consumes the accumulated balance.
    function accumulatedQuote(address token) external view returns (uint256) {
        return _accumulatedQuote[token];
    }

    /// @inheritdoc IVault
    function setup(address, bytes calldata) external {}

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
