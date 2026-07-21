// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFeeTo
/// @notice Singleton recipient for NadFunFactory.feeTo() that converts accumulated
///         V2 LP-dilution into the pair's quote token and forwards the net excess to
///         `ProtocolManager.feeReceiver()`. The caller's `quoteIn` principal is refunded.
interface IFeeTo {
    struct ClaimParams {
        address pair;
        address token;
        address quote;
        uint256 quoteIn;
    }

    event Claimed(address indexed pair, address indexed token, uint256 quoteIn, uint256 quoteOut);
    event Burned(address indexed pair, uint256 lp, uint256 amount0, uint256 amount1);

    error EmptyBatch();
    error InvalidPair();
    error InvalidQuoteIn();
    error InvalidRecipient();
    error EmptyReserve();
    error ZapSplitFailed();
    error ExpiredDeadline();

    function router() external view returns (address);

    /// @notice Batch-claim accumulated LP-dilution fee from N pairs and forward the
    ///         per-quote excess to feeReceiver. The caller's `quoteIn` principal per
    ///         quote token is refunded back to msg.sender.
    /// @dev    Caller must `approve` this contract for the summed principal per quote
    ///         token before calling; FeeTo pulls via `transferFrom` on entry.
    /// @param params Per-pair claim parameters
    /// @param deadline Router call deadline applied to every entry
    /// @return quoteOuts Per-entry recovered quote (raw balance delta around each entry;
    ///                   may be 0 if swap fees exceeded that entry's dilution share)
    function claim(ClaimParams[] calldata params, uint256 deadline) external returns (uint256[] memory quoteOuts);

    /// @notice Burn the FeeTo contract's accumulated LP tokens for one or more pairs
    ///         and forward the underlying token0/token1 directly to feeReceiver. Useful
    ///         for pairs with organic LP activity, where dilution LP accumulates on this
    ///         contract via natural mint/burn calls without operator intervention.
    /// @param pairs Pair addresses whose LP balance held by this contract should be burned
    /// @return amounts0 Per-pair token0 amount sent to feeReceiver
    /// @return amounts1 Per-pair token1 amount sent to feeReceiver
    function burn(address[] calldata pairs) external returns (uint256[] memory amounts0, uint256[] memory amounts1);
}
