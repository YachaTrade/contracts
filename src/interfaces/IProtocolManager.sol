// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IProtocolManager
/// @notice Global protocol configuration interface for fees, quote token configs, and operator permissions.

interface IProtocolManager {
    struct QuoteConfig {
        uint8 decimals;
        uint256 virtualReserve;
        uint256 virtualTokenReserve;
        uint256 minTokenReserve;
        uint256 deployFee;
        uint256 graduateFee;
        uint16 curveProtocolFeeRate;
        uint16 dexProtocolFeeRate;
        uint256 settlementThreshold;
        uint24 v3FeeTier;
        uint16 lpFeeProtocolShareBps;
        bool active;
    }

    event FeeReceiverUpdate(address indexed feeReceiver);
    event CreatorFeeRatesUpdate(uint16[] rates);
    event SettlementThresholdUpdate(address indexed quoteToken, uint256 threshold);
    event V3QuoteConfigUpdate(address indexed quoteToken, uint24 v3FeeTier, uint16 lpFeeProtocolShareBps);
    /// @notice Emitted when the per-block sniping penalty table is updated.
    /// @dev Index `i` of `penaltyTable` is the BPS penalty applied at `block.number == createdAtBlock + i`.
    ///      Length 0 disables sniping. Past the final index the penalty is 0.
    event SnipingPenaltyTableUpdate(uint256[] penaltyTable);
    event QuoteTokenAdd(
        address indexed quoteToken,
        uint256 virtualReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve,
        uint256 deployFee,
        uint256 graduateFee,
        uint16 curveProtocolFeeRate,
        uint16 dexProtocolFeeRate,
        uint256 settlementThreshold
    );
    event QuoteTokenRemove(address indexed quoteToken);
    event QuoteTokenUpdate(
        address indexed quoteToken,
        uint256 virtualReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve,
        uint256 deployFee,
        uint256 graduateFee,
        uint16 curveProtocolFeeRate,
        uint16 dexProtocolFeeRate,
        uint256 settlementThreshold
    );
    event OperatorPermissionUpdated(
        address indexed operator, address indexed target, bytes4 indexed selector, bool allowed
    );

    error QuoteTokenNotAllowed();
    error QuoteTokenAlreadyAdded();
    error InvalidFeeTier();
    error InvalidLpFeeShare();
    error ZeroAddress();

    function setFactoryFeeTo(address factory, address feeTo) external;
    function setFactoryImplementation(address factory, address implementation) external;
    function setOperatorPermission(address operator, address target, bytes4 selector, bool allowed) external;
    function isOperatorAllowed(address operator, address target, bytes4 selector) external view returns (bool);

    function feeReceiver() external view returns (address);
    function curveProtocolFeeRate(address quoteToken) external view returns (uint16);
    function dexProtocolFeeRate(address quoteToken) external view returns (uint16);
    function deployFee(address quoteToken) external view returns (uint256);
    function graduateFee(address quoteToken) external view returns (uint256);
    function v3FeeTier(address quoteToken) external view returns (uint24);
    function lpFeeProtocolShareBps(address quoteToken) external view returns (uint16);

    function setFeeReceiver(address receiver) external;

    function isCreatorFeeRateAllowed(uint16 rate) external view returns (bool);
    function settlementThreshold(address quoteToken) external view returns (uint256);
    function setAllowedCreatorFeeRates(uint16[] calldata rates) external;
    function removeCreatorFeeRate(uint16 rate) external;
    function setSettlementThreshold(address quoteToken, uint256 threshold) external;
    function setV3QuoteConfig(address quoteToken, uint24 v3FeeTier, uint16 lpFeeProtocolShareBps) external;

    /// @notice Returns the full per-block sniping penalty table in BPS.
    function snipingPenaltyTable() external view returns (uint256[] memory);

    /// @notice Returns the BPS penalty for a specific blocks-elapsed index. Returns 0 past the last index.
    function snipingPenaltyAt(uint256 blocksElapsed) external view returns (uint256);

    /// @notice Returns the length of the sniping penalty table (i.e., the size of the sniping window in blocks).
    function snipingPenaltyTableLength() external view returns (uint256);

    /// @notice Returns the current sniping penalty in BPS for a curve created at `createdAtBlock`.
    /// @dev Indexed by `block.number - createdAtBlock`. Returns 0 once elapsed exceeds the table length.
    function getSnipingPenalty(uint256 createdAtBlock) external view returns (uint256 penaltyBps);

    /// @notice Replaces the sniping penalty table.
    /// @dev Each entry must be <= BPS (10000). Pass an empty array to disable sniping entirely.
    function setSnipingPenaltyTable(uint256[] calldata table) external;

    function addQuoteToken(
        address quoteToken,
        uint256 virtualReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve,
        uint256 deployFee,
        uint256 graduateFee,
        uint16 curveProtocolFeeRate,
        uint16 dexProtocolFeeRate,
        uint256 settlementThreshold
    ) external;
    function addV3QuoteToken(
        address quoteToken,
        uint256 virtualReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve,
        uint256 deployFee,
        uint256 graduateFee,
        uint16 curveProtocolFeeRate,
        uint16 dexProtocolFeeRate,
        uint256 settlementThreshold,
        uint24 v3FeeTier,
        uint16 lpFeeProtocolShareBps
    ) external;
    function removeQuoteToken(address quoteToken) external;
    function updateQuoteToken(
        address quoteToken,
        uint256 virtualReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve,
        uint256 deployFee,
        uint256 graduateFee,
        uint16 curveProtocolFeeRate,
        uint16 dexProtocolFeeRate,
        uint256 settlementThreshold
    ) external;
    function updateV3QuoteToken(
        address quoteToken,
        uint256 virtualReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve,
        uint256 deployFee,
        uint256 graduateFee,
        uint16 curveProtocolFeeRate,
        uint16 dexProtocolFeeRate,
        uint256 settlementThreshold,
        uint24 v3FeeTier,
        uint16 lpFeeProtocolShareBps
    ) external;
    function isAllowed(address quoteToken) external view returns (bool);
    function getConfig(address quoteToken) external view returns (QuoteConfig memory);
    function getVirtualReserve(address quoteToken) external view returns (uint256);
    function getVirtualTokenReserve(address quoteToken) external view returns (uint256);
    function getMinTokenReserve(address quoteToken) external view returns (uint256);
    function getDecimals(address quoteToken) external view returns (uint8);
}
