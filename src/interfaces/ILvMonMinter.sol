// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWrappedNative} from "./IWrappedNative.sol";

interface ILvMonMinter {
    event Minted(address indexed user, uint256 monIn, uint256 lvmonOut);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event WhitelistUpdated(address indexed account, bool allowed);

    function issuer() external view returns (address);
    function lvmon() external view returns (IERC20);
    function mint(uint256 amountIn) external payable returns (uint256 lvmonOut);
    function owner() external view returns (address);
    function renounceOwnership() external;
    function setWhitelist(address account, bool allowed) external;
    function transferOwnership(address newOwner) external;
    function whitelist(address account) external view returns (bool);
    function wmon() external view returns (IWrappedNative);
}
