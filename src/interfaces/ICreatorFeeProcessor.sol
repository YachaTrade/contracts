// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICreatorFeeProcessor
/// @notice Distributes creator fees across configured vault slots.

interface ICreatorFeeProcessor {
    struct VaultSlot {
        address vault;
        uint16 bps;
    }

    event Distribute(address indexed token, address indexed vault, uint256 amount);
    event CallbackFail(address indexed vault, uint256 amount, bytes reason);
    event Setup(address indexed token, VaultSlot[] vaults);

    error InvalidBpsTotal();
    error ZeroAddress();
    error NotAuthorized();
    error TooManyVaults();
    error NoVaults();
    error ZeroBps();
    error AlreadyConfigured();
    error InvalidProtocolManager();
    error InvalidBalanceDelta(address token, address account, uint256 expectedBalance, uint256 currentBalance);

    function setup(address token, VaultSlot[] calldata vaults) external;

    function processCreatorFee(address token, address quoteToken, uint256 amount) external;

    function vaultCount(address token) external view returns (uint256);
    function getVaults(address token) external view returns (VaultSlot[] memory);
}
