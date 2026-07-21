// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WETH} from "solady/tokens/WETH.sol";

/// @title WrappedEther
/// @notice Permissionless 1:1 wrapper for the chain's native ETH.
contract WrappedEther is WETH {}
