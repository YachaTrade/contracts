// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {INadFunRouter} from "../interfaces/INadFunRouter.sol";
import {INadFunPair} from "../dex/interfaces/INadFunPair.sol";

interface ICreatorFeeProcessorV2 {
    function processCreatorFee(address token, address quoteToken, uint256 amount) external;
}

/// @title FeeCollector
/// @notice Stores pair-level fee configuration and tracks creator fee accumulation.
/// @dev Protocol fees are forwarded immediately to the configured receiver, while creator fees
///      accumulate per pair and are settled into CreatorFeeProcessor once the threshold is met.
contract FeeCollector is IFeeCollector, UUPSUpgradeable, AccessManagedUpgradeable {
    using SafeERC20 for IERC20;

    ICreatorFeeProcessorV2 private _creatorFeeProcessor;
    address private _bondingCurve;
    INadFunRouter private _router;

    mapping(address pair => FeeConfig) private _configs;
    mapping(address pair => uint256) private _accumulatedFees;
    mapping(address quoteToken => uint256) private _trackedBalance;
    mapping(address pair => bool) private _settling;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Proxy initializer
    /// @param creatorFeeProcessor_ V2 CreatorFeeProcessor address
    /// @param bondingCurve_ Authorized caller for setup()
    function initialize(address protocolManager_, address creatorFeeProcessor_, address bondingCurve_, address router_)
        external
        initializer
    {
        if (creatorFeeProcessor_ == address(0) || bondingCurve_ == address(0) || router_ == address(0)) {
            revert ZeroAddress();
        }
        __AccessManaged_init(protocolManager_);
        _creatorFeeProcessor = ICreatorFeeProcessorV2(creatorFeeProcessor_);
        _bondingCurve = bondingCurve_;
        _router = INadFunRouter(router_);
    }

    /// @inheritdoc IFeeCollector
    function setup(
        address pair,
        address baseToken,
        address quoteToken_,
        uint16 creatorFeeRate,
        uint16 curveProtocolFeeRate,
        uint16 dexProtocolFeeRate
    ) external {
        if (msg.sender != _bondingCurve) revert NotAuthorized();
        if (pair == address(0) || baseToken == address(0) || quoteToken_ == address(0)) revert ZeroAddress();
        if (creatorFeeRate == 0 && curveProtocolFeeRate == 0 && dexProtocolFeeRate == 0) revert InvalidRates();

        FeeConfig storage config = _configs[pair];
        if (config.quoteToken != address(0)) revert AlreadyConfigured();

        _configs[pair] = FeeConfig({
            baseToken: baseToken,
            quoteToken: quoteToken_,
            creatorFeeRate: creatorFeeRate,
            curveProtocolFeeRate: curveProtocolFeeRate,
            dexProtocolFeeRate: dexProtocolFeeRate
        });

        emit Setup(baseToken, pair, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate);
    }

    /// @inheritdoc IFeeCollector
    function getFeeConfig(address pair) external view returns (FeeConfig memory) {
        return _configs[pair];
    }

    /// @inheritdoc IFeeCollector
    /// @dev msg.sender must be the pair itself or bondingCurve. Caller transfers quoteToken before calling.
    ///      Actual amount is determined by balance delta and must cover protocolFee + creatorFee.
    ///      Protocol fee is sent to feeReceiver immediately; only creator fee is accumulated.
    function collectFee(address pair, uint256 protocolFee, uint256 creatorFee) external {
        if (msg.sender != pair && msg.sender != _bondingCurve) revert NotAuthorized();
        FeeConfig storage config = _configs[pair];
        if (config.quoteToken == address(0)) revert NotConfigured();

        address quoteTokenAddr = config.quoteToken;
        uint256 currentBalance = IERC20(quoteTokenAddr).balanceOf(address(this));
        uint256 feeReceived = currentBalance - _trackedBalance[quoteTokenAddr];
        uint256 expectedFee = protocolFee + creatorFee;
        if (feeReceived < expectedFee) revert InvalidFeeAmount();
        if (feeReceived == 0) return;

        uint256 protocolPayout = protocolFee + (feeReceived - expectedFee);
        if (protocolPayout > 0) {
            IERC20(quoteTokenAddr).safeTransfer(IProtocolManager(authority()).feeReceiver(), protocolPayout);
        }

        if (creatorFee > 0) {
            _accumulatedFees[pair] += creatorFee;
        }

        _trackedBalance[quoteTokenAddr] = IERC20(quoteTokenAddr).balanceOf(address(this));

        emit Collect(config.baseToken, pair, feeReceived);
    }

    /// @inheritdoc IFeeCollector
    /// @dev Settles accumulated creator fees to CreatorFeeProcessor.
    ///      Restricted to operators authorized via `ProtocolManager.setOperatorPermission` so
    ///      settlement cannot be timed by arbitrary callers for MEV around the fee-waived
    ///      vault buyback/zap path. Refuses to run while the pair is mid-`lock` (e.g., inside a
    ///      flash-swap callback), since CreatorFeeProcessor's vault hooks reenter the pair and
    ///      would revert silently under the `try/catch` — leaving funds stranded in the vaults.
    function settle(address pair, uint256 minAmountOut) external restricted {
        if (INadFunPair(pair).isLocked()) revert PairLocked();

        FeeConfig storage config = _configs[pair];
        if (config.quoteToken == address(0)) revert NotConfigured();

        uint256 creatorFee = _accumulatedFees[pair];
        if (creatorFee < IProtocolManager(authority()).settlementThreshold(config.quoteToken)) return;

        _settling[pair] = true;
        if (minAmountOut > 0 && _getSettlementAmountOut(config, creatorFee) < minAmountOut) {
            revert InsufficientOutput();
        }

        // CEI: state updates before external calls
        _accumulatedFees[pair] = 0;
        _trackedBalance[config.quoteToken] -= creatorFee;

        IERC20(config.quoteToken).safeIncreaseAllowance(address(_creatorFeeProcessor), creatorFee);
        _creatorFeeProcessor.processCreatorFee(config.baseToken, config.quoteToken, creatorFee);
        _settling[pair] = false;

        emit Settle(config.baseToken, pair, creatorFee, creatorFee);
    }

    function _getSettlementAmountOut(FeeConfig storage config, uint256 quoteIn) internal view returns (uint256) {
        return _router.getAmountOut(config.baseToken, quoteIn, true);
    }

    /// @inheritdoc IFeeCollector
    function accumulatedFee(address pair) external view returns (uint256) {
        return _accumulatedFees[pair];
    }

    /// @inheritdoc IFeeCollector
    function router() external view returns (address) {
        return address(_router);
    }

    /// @inheritdoc IFeeCollector
    function settlementThreshold(address pair) external view returns (uint256) {
        return IProtocolManager(authority()).settlementThreshold(_configs[pair].quoteToken);
    }

    /// @inheritdoc IFeeCollector
    function isSettleable(address pair) external view returns (bool) {
        return _accumulatedFees[pair] >= IProtocolManager(authority()).settlementThreshold(_configs[pair].quoteToken);
    }

    /// @inheritdoc IFeeCollector
    function isSettling(address pair) external view returns (bool) {
        return _settling[pair];
    }

    /// @inheritdoc IFeeCollector
    function setCurveProtocolFeeRate(address pair, uint16 rate) external restricted {
        FeeConfig storage config = _configs[pair];
        if (config.quoteToken == address(0)) revert NotConfigured();
        require(rate <= 1000, "Protocol fee too high");
        uint16 oldRate = config.curveProtocolFeeRate;
        config.curveProtocolFeeRate = rate;
        emit CurveProtocolFeeRateUpdate(pair, oldRate, rate);
    }

    /// @inheritdoc IFeeCollector
    function setDexProtocolFeeRate(address pair, uint16 rate) external restricted {
        FeeConfig storage config = _configs[pair];
        if (config.quoteToken == address(0)) revert NotConfigured();
        require(rate <= 1000, "Dex protocol fee too high");
        uint16 oldRate = config.dexProtocolFeeRate;
        config.dexProtocolFeeRate = rate;
        emit DexProtocolFeeRateUpdate(pair, oldRate, rate);
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}
}
