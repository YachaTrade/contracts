// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "../interfaces/IVault.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IBondingCurve} from "../interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../interfaces/IGiwaRouter.sol";
import {IToken} from "../interfaces/IToken.sol";
import {IWrappedNative} from "../interfaces/IWrappedNative.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

//
//
//

/// @notice Claim-model gift vault. A token binds a `(platform, id)` pair at setup time.
///         quoteToken distributions accumulate on-chain; the bound `receiver` calls
///         `claim(token)` to withdraw the full balance. If the bind window elapses
///         before any `setReceiver` call, the next `afterDeposit` flips the token to
///         permanent-burn mode. Deployed as a singleton shared across all tokens.
///
///         State is explicit: `GiftInfo.state` is a `State` enum with three values —
///         Accumulating → Active → Burned. The receiver is embedded in `GiftInfo`,
///         removing the separate `_expired` / `_receivers` mappings.
contract GiftVault is IVault, UUPSUpgradeable, AccessManagedUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address private constant BURN_ADDRESS = address(0xdead);

    enum Platform {
        GitHub,
        X
    }

    enum State {
        Accumulating,
        Active,
        Burned
    }

    struct GiftTarget {
        Platform platform;
        string id;
    }

    address public creatorFeeProcessor;
    address public bondingCurve;
    ITokenRegistry public tokenRegistry;
    uint256 public expiryDuration;
    address public router;

    mapping(address => uint256) private _pendingQuote;

    /// @dev Per-token record. `state`, `platform`, and `receiver` pack into one slot
    ///      (1 + 1 + 20 = 22 bytes). `receiver` is zero unless `state == Active`.
    struct GiftInfo {
        State state;
        Platform platform;
        address receiver;
        uint256 balance;
        uint256 createdAt;
        string id;
    }

    mapping(address => GiftInfo) private _gifts;

    /// @inheritdoc IVault
    string public metadataURI;

    /// @notice Wrapped-native singleton. When `claim`'s quoteToken matches,
    ///         the vault unwraps and forwards native currency to the receiver instead of WNATIVE.
    /// @dev    Set at `initialize`. Pass `address(0)` to disable the unwrap branch (claims
    ///         always do an ERC20 transfer regardless of quote token).
    address public wnative;

    event VaultSetup(address indexed token, Platform platform, string id);
    event Deposit(address indexed token, uint256 amount, uint256 newBalance);
    event ReceiverSet(address indexed token, address indexed receiver);
    event Claim(address indexed token, address indexed receiver, uint256 amount);
    event Expire(address indexed token, uint256 amount);
    event Burn(address indexed token, address indexed pair, uint256 quoteIn, uint256 tokenBurned);
    event ExpiryUpdate(uint256 oldDuration, uint256 newDuration);

    error NotAuthorized();
    error ZeroAddress();
    error EmptyId();
    error AlreadyConfigured();
    error GiftExpiredError();
    error ZeroDuration();
    error ZeroReceiver();
    error NotConfigured();
    error ZeroBalance();
    error NotReceiver();
    error NativeTransferFailed();
    error UnexpectedNative();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address protocolManager_,
        address creatorFeeProcessor_,
        address bondingCurve_,
        address tokenRegistry_,
        uint256 expiryDuration_,
        address router_,
        address wnative_,
        string calldata metadataURI_
    ) external initializer {
        if (creatorFeeProcessor_ == address(0)) revert ZeroAddress();
        if (bondingCurve_ == address(0)) revert ZeroAddress();
        if (tokenRegistry_ == address(0)) revert ZeroAddress();
        if (expiryDuration_ == 0) revert ZeroDuration();
        if (router_ == address(0)) revert ZeroAddress();

        __AccessManaged_init(protocolManager_);

        creatorFeeProcessor = creatorFeeProcessor_;
        bondingCurve = bondingCurve_;
        tokenRegistry = ITokenRegistry(tokenRegistry_);
        expiryDuration = expiryDuration_;
        router = router_;
        wnative = wnative_;
        metadataURI = metadataURI_;
    }

    /// @inheritdoc IVault
    // data = abi.encode(GiftTarget({platform: Platform.GitHub|X, id: "..."}))
    function setup(address token, bytes calldata data) external {
        if (msg.sender != bondingCurve) revert NotAuthorized();

        GiftTarget memory target = abi.decode(data, (GiftTarget));
        if (bytes(target.id).length == 0) revert EmptyId();

        GiftInfo storage gift = _gifts[token];
        if (bytes(gift.id).length != 0) revert AlreadyConfigured();

        gift.state = State.Accumulating;
        gift.platform = target.platform;
        gift.id = target.id;
        gift.createdAt = block.timestamp;
        emit VaultSetup(token, target.platform, target.id);
    }

    /// @inheritdoc IVault
    //
    function afterDeposit(address token, address quoteToken, uint256 amount) external {
        if (msg.sender != creatorFeeProcessor) revert NotAuthorized();
        if (amount == 0) return;

        GiftInfo storage gift = _gifts[token];
        State s = gift.state;

        if (s == State.Burned) {
            _queueBuybackAndBurn(token, quoteToken, amount);
            return;
        }

        if (s == State.Active) {
            // Receiver bound — accumulate only. Withdrawal is driven by claim().
            gift.balance += amount;
            emit Deposit(token, amount, gift.balance);
            return;
        }

        // Accumulating. If the bind window has closed, flip to permanent-burn and
        // sweep the accumulated balance with the incoming amount.
        if (block.timestamp > gift.createdAt + expiryDuration) {
            uint256 totalAmount = gift.balance + amount;
            gift.balance = 0;
            gift.state = State.Burned;

            emit Expire(token, totalAmount);
            _queueBuybackAndBurn(token, quoteToken, totalAmount);
            return;
        }

        gift.balance += amount;
        emit Deposit(token, amount, gift.balance);
    }

    /// @notice Bind or rotate the claim `receiver` for `token`. Restricted — admin grants
    ///         operator permission to the trusted off-chain relayer that has verified
    ///         platform-id ownership.
    /// @dev Pointer-only update. Any accumulated `balance` is inherited by the incoming
    ///      `receiver`, who may then `claim()` the full amount. First bind and rotate
    ///      are treated identically — past fees follow the current receiver.
    ///      Reverts once the token has entered permanent-burn mode (state == Burned).
    function setReceiver(address token, address receiver) external restricted {
        if (receiver == address(0)) revert ZeroReceiver();

        GiftInfo storage gift = _gifts[token];
        if (gift.state == State.Burned) revert GiftExpiredError();
        if (bytes(gift.id).length == 0) revert NotConfigured();

        gift.receiver = receiver;
        gift.state = State.Active;
        emit ReceiverSet(token, receiver);
    }

    /// @notice Withdraw the full accumulated balance to the bound receiver. Callable
    ///         only by the current `receiver` while the token is `Active`.
    ///         No expiry on claim — once bound, the receiver can claim anytime and
    ///         repeatedly as new fees accrue.
    /// @dev `nonReentrant` + CEI defense in depth. State (`gift.balance`) is zeroed before
    ///      the external call so reentrant `claim(token)` would already revert via
    ///      `ZeroBalance`; the modifier guards against future cross-function paths that
    ///      could share state with `claim` and the WNATIVE unwrap callback.
    function claim(address token) external nonReentrant {
        GiftInfo storage gift = _gifts[token];
        if (gift.state != State.Active) revert NotReceiver();
        if (msg.sender != gift.receiver) revert NotReceiver();

        uint256 amount = gift.balance;
        if (amount == 0) revert ZeroBalance();

        gift.balance = 0;

        address receiver = gift.receiver;
        address quoteToken = tokenRegistry.getQuoteToken(token);
        address wnativeCached = wnative;
        if (wnativeCached != address(0) && quoteToken == wnativeCached) {
            IWrappedNative(wnativeCached).withdraw(amount);
            (bool ok,) = receiver.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(quoteToken).safeTransfer(receiver, amount);
        }
        emit Claim(token, receiver, amount);
    }

    /// @dev Accept native only from the configured WNATIVE contract (callback from
    ///      `IWrappedNative.withdraw`). Rejects all other native sends to prevent
    ///      stranded balances and accidental funding.
    receive() external payable {
        if (msg.sender != wnative) revert UnexpectedNative();
    }

    function _queueBuybackAndBurn(address token, address quoteToken, uint256 amount) internal {
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
            tokenReceived = IGiwaRouter(router)
                .buy(
                    IGiwaRouter.BuyParams({
                        amountIn: totalQuote,
                        amountOutMin: 1,
                        token: token,
                        to: address(this),
                        deadline: block.timestamp
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

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}

    function setExpiryDuration(uint256 newDuration) external restricted {
        if (newDuration == 0) revert ZeroDuration();
        uint256 oldDuration = expiryDuration;
        expiryDuration = newDuration;
        emit ExpiryUpdate(oldDuration, newDuration);
    }

    function getGiftInfo(address token) external view returns (GiftInfo memory) {
        return _gifts[token];
    }

    function getState(address token) external view returns (State) {
        return _gifts[token].state;
    }

    function isExpired(address token) external view returns (bool) {
        return _gifts[token].state == State.Burned;
    }

    function getReceiver(address token) external view returns (address) {
        return _gifts[token].receiver;
    }

    function pendingQuote(address token) external view returns (uint256) {
        return _pendingQuote[token];
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
