// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICreatorFeeProcessor} from "../interfaces/ICreatorFeeProcessor.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BPS} from "../libraries/Constants.sol";

/// @title CreatorFeeProcessor
/// @notice Pulls creator fees from FeeCollector and distributes them across configured vault slots.
contract CreatorFeeProcessor is ICreatorFeeProcessor {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_VAULTS = 5;

    address public immutable bondingCurve;
    address public immutable feeCollector;

    mapping(address => VaultSlot[]) private _vaults;

    constructor(address bondingCurve_, address feeCollector_) {
        require(bondingCurve_ != address(0), "Zero bondingCurve");
        require(feeCollector_ != address(0), "Zero feeCollector");

        bondingCurve = bondingCurve_;
        feeCollector = feeCollector_;
    }

    /// @inheritdoc ICreatorFeeProcessor
    function setup(address token, VaultSlot[] calldata vaults) external {
        if (msg.sender != bondingCurve) revert NotAuthorized();
        if (_vaults[token].length > 0) revert AlreadyConfigured();
        if (vaults.length == 0) revert NoVaults();
        if (vaults.length > MAX_VAULTS) revert TooManyVaults();

        uint256 totalBps;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].bps == 0) revert ZeroBps();
            if (vaults[i].vault == address(0)) revert ZeroAddress();
            totalBps += vaults[i].bps;
            _vaults[token].push(vaults[i]);
        }
        if (totalBps != BPS) revert InvalidBpsTotal();

        emit Setup(token, vaults);
    }

    /// @inheritdoc ICreatorFeeProcessor
    //
    function processCreatorFee(address token, address quoteToken, uint256 amount) external {
        if (msg.sender != feeCollector) revert NotAuthorized();
        if (amount == 0) return;

        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), amount);

        _distributeToVaults(token, quoteToken, amount);
    }

    function _distributeToVaults(address token, address quoteToken, uint256 creatorFeeQuote) internal {
        VaultSlot[] storage vaults = _vaults[token];
        uint256 distributed;
        uint256 len = vaults.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 amount;
            if (i == len - 1) {
                amount = creatorFeeQuote - distributed;
            } else {
                amount = (creatorFeeQuote * vaults[i].bps) / BPS;
                distributed += amount;
            }

            if (amount > 0) {
                address vaultAddr = vaults[i].vault;
                IERC20(quoteToken).safeTransfer(vaultAddr, amount);
                emit Distribute(token, vaultAddr, amount);

                IVault(vaultAddr).afterDeposit(token, quoteToken, amount);
            }
        }
    }

    /// @inheritdoc ICreatorFeeProcessor
    function vaultCount(address token) external view returns (uint256) {
        return _vaults[token].length;
    }

    /// @inheritdoc ICreatorFeeProcessor
    function getVaults(address token) external view returns (VaultSlot[] memory) {
        return _vaults[token];
    }
}
