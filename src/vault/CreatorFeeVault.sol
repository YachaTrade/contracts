// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "../interfaces/IVault.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
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

/// @notice Accumulates quoteToken per-token, claimable by the registered creator.
contract CreatorFeeVault is IVault, UUPSUpgradeable, AccessManagedUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    mapping(address => address) private _creators;
    mapping(address => uint256) private _balances;

    address public bondingCurve;
    address public creatorFeeProcessor;
    ITokenRegistry public tokenRegistry;

    /// @inheritdoc IVault
    string public metadataURI;

    /// @notice Wrapped-native singleton. When `claim`'s quoteToken matches,
    ///         the vault unwraps and forwards native currency to the creator instead of WNATIVE.
    /// @dev    Set at `initialize`. Pass `address(0)` to disable the unwrap branch (claims
    ///         always do an ERC20 transfer regardless of quote token).
    address public wnative;

    event Deposit(address indexed token, uint256 amount, uint256 newBalance);
    event Claim(address indexed token, address indexed creator, uint256 amount);
    event VaultSetup(address indexed token, address creator);
    event CreatorUpdate(address indexed token, address indexed oldCreator, address indexed newCreator);

    error NotAuthorized();
    error ZeroCreator();
    error AlreadyConfigured();
    error NotConfigured();
    error ZeroBalance();
    error NativeTransferFailed();
    error UnexpectedNative();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address protocolManager_,
        address bondingCurve_,
        address creatorFeeProcessor_,
        address tokenRegistry_,
        address wnative_,
        string calldata metadataURI_
    ) external initializer {
        require(bondingCurve_ != address(0), "Zero bondingCurve");
        require(creatorFeeProcessor_ != address(0), "Zero creatorFeeProcessor");
        require(tokenRegistry_ != address(0), "Zero tokenRegistry");

        __AccessManaged_init(protocolManager_);

        bondingCurve = bondingCurve_;
        creatorFeeProcessor = creatorFeeProcessor_;
        tokenRegistry = ITokenRegistry(tokenRegistry_);
        wnative = wnative_;
        metadataURI = metadataURI_;
    }

    /// @inheritdoc IVault
    // data = abi.encode(creator)
    function setup(address token, bytes calldata data) external {
        if (msg.sender != bondingCurve) revert NotAuthorized();
        if (_creators[token] != address(0)) revert AlreadyConfigured();

        address creator = abi.decode(data, (address));
        if (creator == address(0)) revert ZeroCreator();

        _creators[token] = creator;
        emit VaultSetup(token, creator);
    }

    /// @inheritdoc IVault
    function afterDeposit(address token, address, uint256 amount) external {
        if (msg.sender != creatorFeeProcessor) revert NotAuthorized();
        if (amount == 0) return;
        if (_creators[token] == address(0)) return;

        _balances[token] += amount;
        emit Deposit(token, amount, _balances[token]);
    }

    /// @dev `nonReentrant` + CEI defense in depth. State (`_balances[token]`) is zeroed
    ///      before the external call so reentrant `claim(token)` would already revert via
    ///      `ZeroBalance`; the modifier guards against future cross-function paths that
    ///      could share state with `claim` and the WNATIVE unwrap callback.
    function claim(address token) external nonReentrant {
        address creator = _creators[token];
        if (msg.sender != creator) revert NotAuthorized();
        uint256 amount = _balances[token];
        if (amount == 0) revert ZeroBalance();

        _balances[token] = 0;

        address quoteToken = tokenRegistry.getQuoteToken(token);
        address wnativeCached = wnative;
        if (wnativeCached != address(0) && quoteToken == wnativeCached) {
            IWrappedNative(wnativeCached).withdraw(amount);
            (bool ok,) = creator.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(quoteToken).safeTransfer(creator, amount);
        }
        emit Claim(token, creator, amount);
    }

    /// @dev Accept native only from the configured WNATIVE contract (callback from
    ///      `IWrappedNative.withdraw`). Rejects all other native sends to prevent
    ///      stranded balances and accidental funding.
    receive() external payable {
        if (msg.sender != wnative) revert UnexpectedNative();
    }

    function setCreator(address token, address newCreator) external restricted {
        if (newCreator == address(0)) revert ZeroCreator();
        address oldCreator = _creators[token];
        if (oldCreator == address(0)) revert NotConfigured();
        _creators[token] = newCreator;
        emit CreatorUpdate(token, oldCreator, newCreator);
    }

    function getCreator(address token) external view returns (address) {
        return _creators[token];
    }

    function getBalance(address token) external view returns (uint256) {
        return _balances[token];
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
