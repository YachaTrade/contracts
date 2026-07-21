// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

interface ITreasury {
    error OverflowFund();
    error ZeroAddress();

    event Withdrawal(address indexed receiver, uint256 amount);
}
