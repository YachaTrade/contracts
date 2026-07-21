// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal mock of NadFunRouter.buy used to exercise DividendVault's router conversion hop.
/// @dev Mirrors the real router's refund semantics: pull the full `amountIn` from the caller via
///      transferFrom, then transfer the unconsumed `amountIn - consume` back to the caller. The
///      vault is the caller, so the refund lands directly in the vault — what its balance-delta
///      `consumed` accounting depends on. `consumeBps` tunes the consumed fraction (default: full),
///      `_nextOut` of `params.token` is minted to `params.to` so the output delta can be asserted.
contract MockNadFunRouter {
    uint16 internal constant BPS = 10000;

    address public quoteToken;
    uint16 public consumeBps = BPS; // default: consume the full amountIn (no refund)
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

    /// @dev Pulls the full `amountIn` then refunds `amountIn - consume` to msg.sender (the real
    ///      router's behaviour at the graduation cap). Mints `_nextOut` of the target token to
    ///      `params.to` and returns it.
    function buy(INadFunRouter.BuyParams calldata params) external returns (uint256 amountOut) {
        uint256 consume = (params.amountIn * consumeBps) / BPS;
        IERC20(quoteToken).transferFrom(msg.sender, address(this), params.amountIn);
        uint256 refund = params.amountIn - consume;
        if (refund > 0) {
            IERC20(quoteToken).transfer(msg.sender, refund);
        }
        amountOut = _nextOut;
        if (amountOut > 0) {
            MockERC20(params.token).mint(params.to, amountOut);
        }
    }
}
