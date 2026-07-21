// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {INadFunFactory} from "../dex/interfaces/INadFunFactory.sol";
import {BPS, TOKEN_TOTAL_SUPPLY} from "../libraries/Constants.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title ProtocolManager
/// @notice Global configuration hub for protocol fees, quote token configs, and operator permissions.
/// @dev Ownable authority that also implements selector-scoped operator permissions consumed by
///      AccessManaged modules across the protocol.
contract ProtocolManager is IProtocolManager, UUPSUpgradeable, OwnableUpgradeable {
    uint16 private constant MAX_CREATOR_FEE_RATE = 1000;

    address private _feeReceiver;

    /// @dev Per-block sniping penalty table in BPS. Index = `block.number - createdAtBlock`.
    ///      Empty array disables sniping. Entries past the last index implicitly resolve to 0.
    uint256[] private _snipingPenaltyTable;
    mapping(uint16 => bool) private _allowedCreatorFeeRates;

    mapping(address => QuoteConfig) private _configs;
    mapping(address => mapping(address => mapping(bytes4 => bool))) private _operatorPermissions;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address feeReceiver_) external initializer {
        require(admin != address(0), "Zero admin");
        require(feeReceiver_ != address(0), "Zero fee receiver");
        __Ownable_init(admin);
        _feeReceiver = feeReceiver_;
    }

    function feeReceiver() external view returns (address) {
        return _feeReceiver;
    }

    function curveProtocolFeeRate(address quoteToken) external view returns (uint16) {
        return _configs[quoteToken].curveProtocolFeeRate;
    }

    function dexProtocolFeeRate(address quoteToken) external view returns (uint16) {
        return _configs[quoteToken].dexProtocolFeeRate;
    }

    function deployFee(address quoteToken) external view returns (uint256) {
        return _configs[quoteToken].deployFee;
    }

    function graduateFee(address quoteToken) external view returns (uint256) {
        return _configs[quoteToken].graduateFee;
    }

    function v3FeeTier(address quoteToken) external view returns (uint24) {
        return _configs[quoteToken].v3FeeTier;
    }

    function lpFeeProtocolShareBps(address quoteToken) external view returns (uint16) {
        return _configs[quoteToken].lpFeeProtocolShareBps;
    }

    function setFeeReceiver(address receiver) external onlyOwner {
        require(receiver != address(0), "Zero address");
        _feeReceiver = receiver;
        emit FeeReceiverUpdate(receiver);
    }

    function isCreatorFeeRateAllowed(uint16 rate) external view returns (bool) {
        return _allowedCreatorFeeRates[rate];
    }

    function settlementThreshold(address quoteToken) external view returns (uint256) {
        return _configs[quoteToken].settlementThreshold;
    }

    function setAllowedCreatorFeeRates(uint16[] calldata rates) external onlyOwner {
        for (uint256 i = 0; i < rates.length; i++) {
            require(rates[i] <= MAX_CREATOR_FEE_RATE, "Creator fee too high");
            _allowedCreatorFeeRates[rates[i]] = true;
        }
        emit CreatorFeeRatesUpdate(rates);
    }

    function removeCreatorFeeRate(uint16 rate) external onlyOwner {
        _allowedCreatorFeeRates[rate] = false;
    }

    function setSettlementThreshold(address quoteToken, uint256 threshold) external onlyOwner {
        _configs[quoteToken].settlementThreshold = threshold;
        emit SettlementThresholdUpdate(quoteToken, threshold);
    }

    function setV3QuoteConfig(address quoteToken, uint24 v3FeeTier_, uint16 lpFeeProtocolShareBps_) external onlyOwner {
        require(_configs[quoteToken].active, "Not active");
        if (v3FeeTier_ == 0) revert InvalidFeeTier();
        if (lpFeeProtocolShareBps_ > BPS) revert InvalidLpFeeShare();

        _configs[quoteToken].v3FeeTier = v3FeeTier_;
        _configs[quoteToken].lpFeeProtocolShareBps = lpFeeProtocolShareBps_;

        emit V3QuoteConfigUpdate(quoteToken, v3FeeTier_, lpFeeProtocolShareBps_);
    }

    function snipingPenaltyTable() external view returns (uint256[] memory) {
        return _snipingPenaltyTable;
    }

    function snipingPenaltyAt(uint256 blocksElapsed) external view returns (uint256) {
        if (blocksElapsed >= _snipingPenaltyTable.length) return 0;
        return _snipingPenaltyTable[blocksElapsed];
    }

    function snipingPenaltyTableLength() external view returns (uint256) {
        return _snipingPenaltyTable.length;
    }

    /// @notice Returns the current sniping penalty in BPS for a curve created at `createdAtBlock`.
    /// @dev Lookup is indexed by `block.number - createdAtBlock`. The first table entry applies in
    ///      the creation block itself (elapsed = 0), and the penalty drops to 0 once `elapsed`
    ///      reaches the table length.
    function getSnipingPenalty(uint256 createdAtBlock) external view returns (uint256 penaltyBps) {
        uint256 length = _snipingPenaltyTable.length;
        if (length == 0) return 0;

        // Same-block (or pre-creation, which should not happen) trades fall into index 0
        // so the maximum penalty applies.
        uint256 elapsed = block.number > createdAtBlock ? block.number - createdAtBlock : 0;
        if (elapsed >= length) return 0;
        return _snipingPenaltyTable[elapsed];
    }

    /// @notice Replaces the sniping penalty table.
    /// @dev Each entry must be <= BPS (10000). Pass an empty array to disable sniping entirely.
    function setSnipingPenaltyTable(uint256[] calldata table) external onlyOwner {
        uint256 length = table.length;
        delete _snipingPenaltyTable;
        for (uint256 i = 0; i < length; i++) {
            require(table[i] <= BPS, "Penalty exceeds BPS");
            _snipingPenaltyTable.push(table[i]);
        }
        emit SnipingPenaltyTableUpdate(table);
    }

    function addQuoteToken(
        address quoteToken,
        uint256 virtualReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve,
        uint256 deployFee_,
        uint256 graduateFee_,
        uint16 curveProtocolFeeRate_,
        uint16 dexProtocolFeeRate_,
        uint256 settlementThreshold_
    ) external onlyOwner {
        if (quoteToken == address(0)) revert ZeroAddress();
        if (_configs[quoteToken].active) revert QuoteTokenAlreadyAdded();
        require(curveProtocolFeeRate_ <= 1000, "Protocol fee too high");
        require(dexProtocolFeeRate_ <= 1000, "Dex protocol fee too high");
        require(virtualReserve > 0, "Zero virtual quote reserve");
        require(virtualTokenReserve > 0, "Zero virtual token reserve");
        require(minTokenReserve < virtualTokenReserve, "Invalid min token reserve");
        _validateGraduationSupply(virtualReserve, virtualTokenReserve, minTokenReserve, graduateFee_);

        uint8 decimals = IERC20Metadata(quoteToken).decimals();
        _configs[quoteToken] = QuoteConfig({
            decimals: decimals,
            virtualReserve: virtualReserve,
            virtualTokenReserve: virtualTokenReserve,
            minTokenReserve: minTokenReserve,
            deployFee: deployFee_,
            graduateFee: graduateFee_,
            curveProtocolFeeRate: curveProtocolFeeRate_,
            dexProtocolFeeRate: dexProtocolFeeRate_,
            settlementThreshold: settlementThreshold_,
            v3FeeTier: 0,
            lpFeeProtocolShareBps: 0,
            active: true
        });

        emit QuoteTokenAdd(
            quoteToken,
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            deployFee_,
            graduateFee_,
            curveProtocolFeeRate_,
            dexProtocolFeeRate_,
            settlementThreshold_
        );
    }

    function removeQuoteToken(address quoteToken) external onlyOwner {
        _configs[quoteToken].active = false;
        emit QuoteTokenRemove(quoteToken);
    }

    function updateQuoteToken(
        address quoteToken,
        uint256 virtualReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve,
        uint256 deployFee_,
        uint256 graduateFee_,
        uint16 curveProtocolFeeRate_,
        uint16 dexProtocolFeeRate_,
        uint256 settlementThreshold_
    ) external onlyOwner {
        require(_configs[quoteToken].active, "Not active");
        require(curveProtocolFeeRate_ <= 1000, "Protocol fee too high");
        require(dexProtocolFeeRate_ <= 1000, "Dex protocol fee too high");
        require(virtualReserve > 0, "Zero virtual quote reserve");
        require(virtualTokenReserve > 0, "Zero virtual token reserve");
        require(minTokenReserve < virtualTokenReserve, "Invalid min token reserve");
        _validateGraduationSupply(virtualReserve, virtualTokenReserve, minTokenReserve, graduateFee_);
        _configs[quoteToken].virtualReserve = virtualReserve;
        _configs[quoteToken].virtualTokenReserve = virtualTokenReserve;
        _configs[quoteToken].minTokenReserve = minTokenReserve;
        _configs[quoteToken].deployFee = deployFee_;
        _configs[quoteToken].graduateFee = graduateFee_;
        _configs[quoteToken].curveProtocolFeeRate = curveProtocolFeeRate_;
        _configs[quoteToken].dexProtocolFeeRate = dexProtocolFeeRate_;
        _configs[quoteToken].settlementThreshold = settlementThreshold_;
        emit QuoteTokenUpdate(
            quoteToken,
            virtualReserve,
            virtualTokenReserve,
            minTokenReserve,
            deployFee_,
            graduateFee_,
            curveProtocolFeeRate_,
            dexProtocolFeeRate_,
            settlementThreshold_
        );
    }

    function _validateGraduationSupply(
        uint256 virtualReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve,
        uint256 graduateFee_
    ) private pure {
        require(minTokenReserve > 0 && minTokenReserve < virtualTokenReserve, "Invalid min token reserve");

        uint256 tokensSoldToReachGraduation = virtualTokenReserve - minTokenReserve;
        require(tokensSoldToReachGraduation <= TOKEN_TOTAL_SUPPLY, "Invalid graduation supply");

        uint256 k = virtualReserve * virtualTokenReserve;
        uint256 quoteReserveAtGraduation = FixedPointMathLib.mulDivUp(k, 1, minTokenReserve);
        uint256 quoteRaisedAtGraduation = quoteReserveAtGraduation - virtualReserve;
        require(quoteRaisedAtGraduation > graduateFee_, "Graduate fee too high");

        uint256 quoteForLiquidity = quoteRaisedAtGraduation - graduateFee_;
        uint256 tokenForLiquidity = quoteForLiquidity * minTokenReserve / quoteReserveAtGraduation;

        require(tokensSoldToReachGraduation + tokenForLiquidity <= TOKEN_TOTAL_SUPPLY, "Invalid graduation supply");
    }

    function isAllowed(address quoteToken) external view returns (bool) {
        return _configs[quoteToken].active;
    }

    function getConfig(address quoteToken) external view returns (QuoteConfig memory) {
        return _configs[quoteToken];
    }

    function getVirtualReserve(address quoteToken) external view returns (uint256) {
        return _configs[quoteToken].virtualReserve;
    }

    function getVirtualTokenReserve(address quoteToken) external view returns (uint256) {
        return _configs[quoteToken].virtualTokenReserve;
    }

    function getMinTokenReserve(address quoteToken) external view returns (uint256) {
        return _configs[quoteToken].minTokenReserve;
    }

    function getDecimals(address quoteToken) external view returns (uint8) {
        return _configs[quoteToken].decimals;
    }

    function setFactoryFeeTo(address factory, address feeTo) external onlyOwner {
        INadFunFactory(factory).setFeeTo(feeTo);
    }

    function setFactoryImplementation(address factory, address impl) external onlyOwner {
        INadFunFactory(factory).setImplementation(impl);
    }

    function setOperatorPermission(address operator, address target, bytes4 selector, bool allowed) external onlyOwner {
        require(operator != address(0), "Zero operator");
        require(target != address(0), "Zero target");

        _operatorPermissions[target][operator][selector] = allowed;
        emit OperatorPermissionUpdated(operator, target, selector, allowed);
    }

    function isOperatorAllowed(address operator, address target, bytes4 selector) external view returns (bool) {
        return _operatorPermissions[target][operator][selector];
    }

    function canCall(address caller, address target, bytes4 selector) external view returns (bool, uint32) {
        bool allowed = caller == owner() || _operatorPermissions[target][caller][selector];
        return (allowed, 0);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
