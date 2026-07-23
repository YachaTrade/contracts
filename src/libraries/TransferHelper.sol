// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

library TransferHelper {
    error NativeTransferFailed();

    /// @notice Forward native currency to `to`. Reverts on call failure.
    function safeTransferNative(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}("");
        if (!success) revert NativeTransferFailed();
    }
}
