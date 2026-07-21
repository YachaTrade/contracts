// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal GiwaRouter buy mock used by DividendVault conversion tests.
/// @dev Mirrors the curve refund path by pulling the maximum input, returning the unconsumed
///      portion to the caller, and minting the configured output to the requested recipient.
contract MockGiwaRouter {
    uint16 internal constant BPS = 10_000;

    address public quoteToken;
    uint16 public consumeBps = BPS;
    uint256 internal _nextOut;

    constructor(address quoteToken_) {
        quoteToken = quoteToken_;
    }

    function setQuoteToken(address quoteToken_) external {
        quoteToken = quoteToken_;
    }

    function setConsumeBps(uint16 consumeBps_) external {
        consumeBps = consumeBps_;
    }

    function setNextOut(uint256 nextOut_) external {
        _nextOut = nextOut_;
    }

    function buy(IGiwaRouter.BuyParams calldata params) external returns (uint256 amountOut) {
        uint256 consume = (params.amountIn * consumeBps) / BPS;
        IERC20(quoteToken).transferFrom(msg.sender, address(this), params.amountIn);
        uint256 refund = params.amountIn - consume;
        if (refund > 0) IERC20(quoteToken).transfer(msg.sender, refund);

        amountOut = _nextOut;
        if (amountOut > 0) MockERC20(params.token).mint(params.to, amountOut);
    }
}
