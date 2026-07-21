// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICreatorFeeProcessor} from "../interfaces/ICreatorFeeProcessor.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BPS} from "../libraries/Constants.sol";

/// @title CreatorFeeProcessor
/// @notice Pulls creator fees from an authorized caller and distributes them across configured vault slots.
contract CreatorFeeProcessor is ICreatorFeeProcessor {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_VAULTS = 5;

    IProtocolManager public immutable protocolManager;

    mapping(address => VaultSlot[]) private _vaults;

    constructor(address protocolManager_) {
        if (protocolManager_.code.length == 0) revert InvalidProtocolManager();
        protocolManager = IProtocolManager(protocolManager_);
    }

    /// @inheritdoc ICreatorFeeProcessor
    function setup(address token, VaultSlot[] calldata vaults) external {
        (bool allowed,) = protocolManager.canCall(msg.sender, address(this), msg.sig);
        if (!allowed) revert NotAuthorized();
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
    function processCreatorFee(address token, address quoteToken, uint256 amount) external {
        (bool allowed,) = protocolManager.canCall(msg.sender, address(this), msg.sig);
        if (!allowed) revert NotAuthorized();
        if (amount == 0) return;

        IERC20 quote = IERC20(quoteToken);
        uint256 entryBalance = quote.balanceOf(address(this));

        _pullExact(quote, msg.sender, amount);

        _distributeToVaults(token, quote, amount);

        uint256 finalBalance = quote.balanceOf(address(this));
        if (finalBalance != entryBalance) {
            revert InvalidBalanceDelta(quoteToken, address(this), entryBalance, finalBalance);
        }
    }

    function _distributeToVaults(address token, IERC20 quoteToken, uint256 creatorFeeQuote) internal {
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
                _pushExact(quoteToken, vaultAddr, amount);
                emit Distribute(token, vaultAddr, amount);

                IVault(vaultAddr).afterDeposit(token, address(quoteToken), amount);
            }
        }
    }

    function _pullExact(IERC20 quoteToken, address sender, uint256 amount) private {
        uint256 senderBalanceBefore = quoteToken.balanceOf(sender);
        uint256 processorBalanceBefore = quoteToken.balanceOf(address(this));

        quoteToken.safeTransferFrom(sender, address(this), amount);

        _requireBalanceDecrease(quoteToken, sender, senderBalanceBefore, amount);
        _requireBalanceIncrease(quoteToken, address(this), processorBalanceBefore, amount);
    }

    function _pushExact(IERC20 quoteToken, address recipient, uint256 amount) private {
        uint256 processorBalanceBefore = quoteToken.balanceOf(address(this));
        uint256 recipientBalanceBefore = quoteToken.balanceOf(recipient);

        quoteToken.safeTransfer(recipient, amount);

        _requireBalanceDecrease(quoteToken, address(this), processorBalanceBefore, amount);
        _requireBalanceIncrease(quoteToken, recipient, recipientBalanceBefore, amount);
    }

    function _requireBalanceDecrease(IERC20 quoteToken, address account, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        uint256 currentBalance = quoteToken.balanceOf(account);
        uint256 expectedBalance = balanceBefore >= amount ? balanceBefore - amount : 0;
        if (balanceBefore < amount || currentBalance != expectedBalance) {
            revert InvalidBalanceDelta(address(quoteToken), account, expectedBalance, currentBalance);
        }
    }

    function _requireBalanceIncrease(IERC20 quoteToken, address account, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        if (amount > type(uint256).max - balanceBefore) {
            revert InvalidBalanceDelta(address(quoteToken), account, type(uint256).max, quoteToken.balanceOf(account));
        }

        uint256 expectedBalance = balanceBefore + amount;
        uint256 currentBalance = quoteToken.balanceOf(account);
        if (currentBalance != expectedBalance) {
            revert InvalidBalanceDelta(address(quoteToken), account, expectedBalance, currentBalance);
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
