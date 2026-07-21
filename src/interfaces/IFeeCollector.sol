// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFeeCollector {
    struct FeeConfig {
        address baseToken;
        address quoteToken;
        uint16 creatorFeeRate; // creator fee rate (BPS)
        uint16 curveProtocolFeeRate; // bonding curve protocol fee rate (BPS)
        uint16 dexProtocolFeeRate; // dex protocol fee rate (BPS)
    }

    event Setup(
        address indexed token,
        address indexed pair,
        uint16 creatorFeeRate,
        uint16 curveProtocolFeeRate,
        uint16 dexProtocolFeeRate
    );
    event Collect(address indexed token, address indexed pair, uint256 amount);
    event Settle(address indexed token, address indexed pair, uint256 totalFee, uint256 creatorFee);
    event CurveProtocolFeeRateUpdate(address indexed pair, uint16 oldRate, uint16 newRate);
    event DexProtocolFeeRateUpdate(address indexed pair, uint16 oldRate, uint16 newRate);

    error AlreadyConfigured();
    error NotConfigured();
    error ZeroAddress();
    error InvalidRates();
    error InvalidFeeAmount();
    error BelowThreshold();
    error NotAuthorized();
    error PairLocked();
    error InsufficientOutput();

    function setup(
        address pair,
        address baseToken,
        address quoteToken,
        uint16 creatorFeeRate,
        uint16 curveProtocolFeeRate,
        uint16 dexProtocolFeeRate
    ) external;
    function getFeeConfig(address pair) external view returns (FeeConfig memory);

    function collectFee(address pair, uint256 protocolFee, uint256 creatorFee) external;

    function settle(address pair, uint256 minAmountOut) external;

    // Views
    function accumulatedFee(address pair) external view returns (uint256);
    function router() external view returns (address);
    function settlementThreshold(address pair) external view returns (uint256);
    function isSettleable(address pair) external view returns (bool);
    function isSettling(address pair) external view returns (bool);

    // Admin
    function setCurveProtocolFeeRate(address pair, uint16 rate) external;
    function setDexProtocolFeeRate(address pair, uint16 rate) external;
}
