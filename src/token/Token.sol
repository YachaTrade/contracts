// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IToken} from "../interfaces/IToken.sol";
import {TOKEN_TOTAL_SUPPLY} from "../libraries/Constants.sol";

// Token -- Simple ERC20 + Permit for bonding-curve launches
//
//

/// @title Token -- Simple ERC20 + Permit for bonding-curve launches
/// @notice Deployed as ERC-1167 clone. No fee-on-transfer.
contract Token is ERC20Upgradeable, ERC20PermitUpgradeable, IToken {
    uint256 public constant TOTAL_SUPPLY = TOKEN_TOTAL_SUPPLY;

    address public bondingCurve;
    address public pair;
    bool public isGraduated;
    string private _tokenURI;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IToken
    function initialize(
        string memory name_,
        string memory symbol_,
        string memory tokenURI_,
        address bondingCurve_,
        address pair_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        _tokenURI = tokenURI_;
        bondingCurve = bondingCurve_;
        pair = pair_;
        _mint(bondingCurve_, TOTAL_SUPPLY);
    }

    /// @inheritdoc IToken
    function tokenURI() external view returns (string memory) {
        return _tokenURI;
    }

    /// @dev Blocks transfers to pair before graduation to prevent reserve corruption.
    function _update(address from, address to, uint256 value) internal override {
        if (!isGraduated && to == pair) revert TransferToPairBeforeGraduation();
        super._update(from, to, value);
    }

    /// @inheritdoc IToken
    function setIsGraduated() external {
        if (msg.sender != bondingCurve) revert NotBondingCurve();
        if (isGraduated) revert AlreadyGraduated();
        isGraduated = true;
    }
}
