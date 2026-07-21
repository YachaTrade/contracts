// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

library TransferHelper {
    error MonTransferFailed();

    /// @notice Forward native MON to `to`. Reverts on call failure.
    function safeTransferMon(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}("");
        if (!success) revert MonTransferFailed();
    }
}
