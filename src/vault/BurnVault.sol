// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "../interfaces/IVault.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IBondingCurve} from "../interfaces/IBondingCurve.sol";
import {INadFunRouter} from "../interfaces/INadFunRouter.sol";
import {IToken} from "../interfaces/IToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title BurnVault
/// @notice Receives quoteToken, swaps into the paired token, and sends the bought tokens to `0xdead`.
contract BurnVault is IVault, UUPSUpgradeable, AccessManagedUpgradeable {
    using SafeERC20 for IERC20;

    address private constant BURN_ADDRESS = address(0xdead);

    ITokenRegistry public tokenRegistry;
    address public creatorFeeProcessor;
    IBondingCurve public bondingCurve;
    address public router;

    mapping(address => uint256) private _pendingQuote;

    /// @inheritdoc IVault
    string public metadataURI;

    event Burn(address indexed token, address indexed pair, uint256 quoteIn, uint256 tokenBurned);

    error NotAuthorized();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address protocolManager_,
        address tokenRegistry_,
        address creatorFeeProcessor_,
        address bondingCurve_,
        address router_,
        string calldata metadataURI_
    ) external initializer {
        require(tokenRegistry_ != address(0), "Zero tokenRegistry");
        require(creatorFeeProcessor_ != address(0), "Zero creatorFeeProcessor");
        require(bondingCurve_ != address(0), "Zero bondingCurve");
        require(router_ != address(0), "Zero router");

        __AccessManaged_init(protocolManager_);

        tokenRegistry = ITokenRegistry(tokenRegistry_);
        creatorFeeProcessor = creatorFeeProcessor_;
        bondingCurve = IBondingCurve(bondingCurve_);
        router = router_;
        metadataURI = metadataURI_;
    }

    /// @inheritdoc IVault
    function afterDeposit(address token, address quoteToken, uint256 amount) external {
        if (msg.sender != creatorFeeProcessor) revert NotAuthorized();
        if (amount > 0) _pendingQuote[token] += amount;

        try this.executePendingBuyback(token, quoteToken) {}
        catch {
            return;
        }
    }

    function executePendingBuyback(address token, address quoteToken) external {
        if (msg.sender != address(this)) revert NotAuthorized();

        uint256 totalQuote = _pendingQuote[token];
        if (totalQuote == 0) return;

        uint256 tokenReceived;
        uint256 spent;
        address pair;
        if (IToken(token).isGraduated()) {
            ITokenRegistry.TokenInfo memory info = tokenRegistry.getTokenInfo(token);
            pair = info.pair;
            IDexAdapter adapter = tokenRegistry.getAdapter(info.dexType);
            IERC20(quoteToken).safeTransfer(address(adapter), totalQuote);
            tokenReceived = adapter.swap(pair, quoteToken, token, totalQuote, address(this), "");
            spent = totalQuote;
        } else {
            uint256 balanceBefore = IERC20(quoteToken).balanceOf(address(this));
            IERC20(quoteToken).forceApprove(router, totalQuote);
            tokenReceived = INadFunRouter(router)
                .buy(
                    INadFunRouter.BuyParams({
                    amountIn: totalQuote, amountOutMin: 1, token: token, to: address(this), deadline: block.timestamp
                })
                );
            spent = balanceBefore - IERC20(quoteToken).balanceOf(address(this));
        }

        _pendingQuote[token] = totalQuote - spent;

        if (tokenReceived > 0) {
            IERC20(token).safeTransfer(BURN_ADDRESS, tokenReceived);
            emit Burn(token, pair, spent, tokenReceived);
        }
    }

    function pendingQuote(address token) external view returns (uint256) {
        return _pendingQuote[token];
    }

    /// @inheritdoc IVault
    function setup(address, bytes calldata) external {}

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
