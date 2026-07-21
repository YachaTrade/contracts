// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test helper mock wrapped native token.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWMON is ERC20 {
    constructor() ERC20("Wrapped MON", "WMON") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /// @dev Test-only: mint without requiring native deposit
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
