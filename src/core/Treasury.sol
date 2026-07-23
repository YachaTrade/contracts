// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {ITreasury} from "../interfaces/ITreasury.sol";
import {IWrappedNative} from "../interfaces/IWrappedNative.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";

/// @title Treasury
/// @notice Protocol fee + protocol treasury. Holds WNATIVE (and other ERC20s) and exposes
///         `restricted` withdrawal entrypoints gated by the ProtocolManager authority.
/// @dev    UUPS upgradeable + AccessManaged. ProtocolManager is the authority; PM.owner()
///         is auto-permitted, other addresses can be granted via setOperatorPermission.
contract Treasury is ITreasury, UUPSUpgradeable, AccessManagedUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice WNATIVE token contract address.
    address public wnative;

    /// @notice Fallback function to receive native currency.
    /// @dev    Only accepts native currency from the WNATIVE contract during withdraw.
    receive() external payable {
        assert(msg.sender == wnative);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param protocolManager_ ProtocolManager (acts as AccessManager authority).
    /// @param wnative_         WNATIVE token address.
    function initialize(address protocolManager_, address wnative_) external initializer {
        if (wnative_ == address(0)) revert ZeroAddress();
        __AccessManaged_init(protocolManager_);
        wnative = wnative_;
    }

    /// @notice Returns the total balance of WNATIVE in the treasury.
    function totalAssets() public view returns (uint256) {
        return IERC20(wnative).balanceOf(address(this));
    }

    /// @notice Unwrap `amount` WNATIVE to native currency and forward to `receiver`.
    function executeWithdrawal(address receiver, uint256 amount) external restricted {
        if (amount > totalAssets()) revert OverflowFund();
        IWrappedNative(wnative).withdraw(amount);
        TransferHelper.safeTransferNative(receiver, amount);
        emit Withdrawal(receiver, amount);
    }

    /// @notice Forward `amount` of arbitrary ERC20 `token` held by the treasury to `receiver`.
    function executeWithdrawToken(address token, address receiver, uint256 amount) external restricted {
        if (amount > IERC20(token).balanceOf(address(this))) revert OverflowFund();
        IERC20(token).safeTransfer(receiver, amount);
        emit Withdrawal(receiver, amount);
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}
}
