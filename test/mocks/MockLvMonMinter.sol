// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWrappedNative} from "../../src/interfaces/IWrappedNative.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockLvMonMinter {
    event Minted(address indexed user, uint256 monIn, uint256 lvmonOut);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event WhitelistUpdated(address indexed account, bool allowed);

    address public owner;
    address public issuer;
    IERC20 public lvmon;
    IWrappedNative public wmon;
    mapping(address account => bool allowed) public whitelist;

    uint256 public lvmonOutPerMonIn = 1e18;

    constructor(address owner_, address issuer_, address wmon_, address lvmon_) {
        owner = owner_;
        issuer = issuer_;
        wmon = IWrappedNative(wmon_);
        lvmon = IERC20(lvmon_);
    }

    function mint(uint256 amountIn) external payable returns (uint256 lvmonOut) {
        require(msg.value == amountIn, "value mismatch");
        lvmonOut = amountIn * lvmonOutPerMonIn / 1e18;
        MockERC20(address(lvmon)).mint(msg.sender, lvmonOut);
        emit Minted(msg.sender, amountIn, lvmonOut);
    }

    function setLvmonOutPerMonIn(uint256 lvmonOutPerMonIn_) external {
        lvmonOutPerMonIn = lvmonOutPerMonIn_;
    }

    function renounceOwnership() external {
        address previousOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(previousOwner, address(0));
    }

    function setWhitelist(address account, bool allowed) external {
        whitelist[account] = allowed;
        emit WhitelistUpdated(account, allowed);
    }

    function transferOwnership(address newOwner) external {
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }
}
