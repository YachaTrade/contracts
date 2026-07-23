// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDividendVault} from "../interfaces/IDividendVault.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IGiwaRouter} from "../interfaces/IGiwaRouter.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBondingCurveV1} from "../integration/interfaces/IBondingCurveV1.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BPS} from "../libraries/Constants.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IWrappedNative} from "../interfaces/IWrappedNative.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";

/// @title DividendVault
/// @notice Records creator-fee quote tokens by configured dividend ratio. Operator bots convert
///         pending quote slices, and holders claim finalized balances through Merkle roots.
contract DividendVault is IDividendVault, UUPSUpgradeable, AccessManagedUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_DIVIDEND_TOKENS = 10;

    // ── Protocol wiring ──
    ITokenRegistry public tokenRegistryV2;
    address public creatorFeeProcessor;
    address public bondingCurve;
    address public router;
    IBondingCurveV1 public bondingCurveV1;
    // External adapter lanes. GiwaRouter handles pre-graduation curve hops and graduated tokens
    // registered with canonical V3 metadata.
    IDexAdapter public uniswapV2Adapter;
    IDexAdapter public uniswapV3Adapter;
    // WNATIVE singleton used only to unwrap native currency on claim. 0 = disabled.
    address public wnative;

    // ── Dividend config (per source token) ──
    mapping(address sourceToken => DividendConfig) private _config;

    // ── Dividend token allowlist ──
    mapping(address token => bool) public allowedDividendToken;

    // ── Conversion accounting ──
    mapping(address sourceToken => mapping(address dividendToken => uint256)) public dividendBalance;
    /// @notice Pending quoteToken awaiting bot conversion into a specific dividend token.
    mapping(address sourceToken => mapping(address dividendToken => uint256)) public pendingSwap;

    // ── Merkle distribution / claim ──
    bytes32 public merkleRoot;
    // Cumulative dividend already paid out, per (source, holder, dividend). The leaf amount is the FULL
    // cumulative accrued (computed off-chain); claim() pays only (amount - claimedCumulative), so a
    // republished / equal / lower root pays 0 → distribution is race-free regardless of root timing.
    mapping(address sourceToken => mapping(address holder => mapping(address dividendToken => uint256))) public
        claimedCumulative;

    /// @inheritdoc IVault
    string public metadataURI;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Accept native only from the configured WNATIVE callback during withdraw.
    receive() external payable {
        if (msg.sender != wnative) revert UnexpectedNative();
    }

    function initialize(
        address protocolManager_,
        address tokenRegistryV2_,
        address creatorFeeProcessor_,
        address bondingCurve_,
        address router_,
        address bondingCurveV1_,
        string calldata metadataURI_
    ) external initializer {
        if (tokenRegistryV2_ == address(0)) revert ZeroAddress();
        if (creatorFeeProcessor_ == address(0)) revert ZeroAddress();
        if (bondingCurve_ == address(0)) revert ZeroAddress();
        if (router_ == address(0)) revert ZeroAddress();
        if (router_.code.length == 0) revert NotContract();
        if (bondingCurveV1_ == address(0)) revert ZeroAddress();
        if (bondingCurveV1_.code.length == 0) revert NotContract();

        __AccessManaged_init(protocolManager_);

        tokenRegistryV2 = ITokenRegistry(tokenRegistryV2_);
        creatorFeeProcessor = creatorFeeProcessor_;
        bondingCurve = bondingCurve_;
        router = router_;
        bondingCurveV1 = IBondingCurveV1(bondingCurveV1_);
        metadataURI = metadataURI_;
    }

    /// @inheritdoc IVault
    /// @dev data = abi.encode(address[] dividendTokens, uint16[] ratios, uint256 minBalance)
    function setup(address sourceToken, bytes calldata data) external {
        if (msg.sender != bondingCurve) revert NotAuthorized();
        if (_config[sourceToken].dividendTokens.length != 0) revert AlreadyConfigured();

        (address[] memory dividendTokens, uint16[] memory ratios, uint256 minBalance) =
            abi.decode(data, (address[], uint16[], uint256));

        uint256 tokenCount = dividendTokens.length;
        if (tokenCount == 0 || tokenCount > MAX_DIVIDEND_TOKENS) revert InvalidTokenCount();
        if (ratios.length != tokenCount) revert LengthMismatch();

        address quoteToken = tokenRegistryV2.getQuoteToken(sourceToken);

        uint256 totalBps;
        for (uint256 i; i < tokenCount; ++i) {
            address dividendToken = dividendTokens[i];
            if (dividendToken == address(0)) revert ZeroAddress();
            if (ratios[i] == 0) revert ZeroRatio();

            bool supported = dividendToken == quoteToken;
            if (!supported && tokenRegistryV2.isRegistered(dividendToken)) supported = true;
            if (!supported && allowedDividendToken[dividendToken]) supported = true;
            if (!supported && IProtocolManager(authority()).isAllowed(dividendToken)) supported = true;
            if (!supported && bondingCurveV1.createdAt(dividendToken) != 0 && bondingCurveV1.isGraduated(dividendToken))
            {
                supported = true;
            }
            if (!supported) revert UnsupportedDividendToken();

            for (uint256 j; j < i; ++j) {
                if (dividendTokens[j] == dividendToken) revert DuplicateDividendToken();
            }
            totalBps += ratios[i];
        }
        if (totalBps != BPS) revert InvalidRatioTotal();

        DividendConfig storage config = _config[sourceToken];
        config.dividendTokens = dividendTokens;
        config.ratios = ratios;
        config.minBalance = minBalance;

        emit DividendSetup(sourceToken, dividendTokens, ratios, minBalance);
    }

    function getConfig(address sourceToken) external view returns (DividendConfig memory) {
        return _config[sourceToken];
    }

    /// @inheritdoc IVault
    /// @dev Records ratio splits only. Conversion is performed later by an authorized bot.
    function afterDeposit(address sourceToken, address quoteToken, uint256 amount) external {
        if (msg.sender != creatorFeeProcessor) revert NotAuthorized();

        DividendConfig storage config = _config[sourceToken];
        uint256 tokenCount = config.dividendTokens.length;
        if (amount == 0) tokenCount = 0;

        address[] memory dividendTokens = new address[](tokenCount);
        uint256[] memory slices = new uint256[](tokenCount);
        bool[] memory pending = new bool[](tokenCount);

        uint256 distributed;
        for (uint256 i; i < tokenCount; ++i) {
            address dividendToken = config.dividendTokens[i];
            uint256 slice = (i == tokenCount - 1) ? (amount - distributed) : (amount * config.ratios[i]) / BPS;
            distributed += slice;
            dividendTokens[i] = dividendToken;
            slices[i] = slice;
            pending[i] = dividendToken != quoteToken;
            if (slice == 0) continue;
            if (pending[i]) {
                pendingSwap[sourceToken][dividendToken] += slice;
                continue;
            }
            dividendBalance[sourceToken][dividendToken] += slice;
        }
        if (tokenCount > 0) emit Deposit(sourceToken, dividendTokens, slices, pending);
    }

    /// @notice Operator bot converts pending quote slices through explicit hop paths — batched.
    ///         Orders process sequentially and atomically: any failure reverts the whole batch
    ///         (fail loud; the bot drops the failing order and resubmits).
    function executeConversion(ConversionOrder[] calldata orders) external restricted nonReentrant {
        uint256 orderCount = orders.length;
        if (orderCount == 0) revert InvalidPath();

        address[] memory convertedSourceTokens = new address[](orderCount);
        address[] memory convertedDividendTokens = new address[](orderCount);
        uint256[] memory consumedQuote = new uint256[](orderCount);
        uint256[] memory receivedAmounts = new uint256[](orderCount);

        for (uint256 orderIndex; orderIndex < orderCount; ++orderIndex) {
            ConversionOrder calldata order = orders[orderIndex];

            uint256 pending = pendingSwap[order.sourceToken][order.dividendToken];
            if (order.quoteIn > pending) revert ExcessiveConversion();

            uint256 pathLength = order.path.length;
            if (pathLength == 0) revert InvalidPath();
            if (order.path[pathLength - 1].tokenOut != order.dividendToken) revert InvalidPath();

            address currentToken = tokenRegistryV2.getQuoteToken(order.sourceToken);
            uint256 currentAmount = order.quoteIn;
            uint256 sourceQuoteBalanceBefore = IERC20(currentToken).balanceOf(address(this));
            uint256 consumed;

            for (uint256 i; i < pathLength; ++i) {
                ConversionHop calldata hop = order.path[i];
                address tokenOut = hop.tokenOut;
                uint256 inputBalanceBefore = IERC20(currentToken).balanceOf(address(this));
                uint256 tokenOutBalanceBefore = IERC20(tokenOut).balanceOf(address(this));

                if (address(hop.adapter) == router) {
                    IGiwaRouter routerCached = IGiwaRouter(router);
                    IERC20(currentToken).forceApprove(router, currentAmount);
                    routerCached.buy(
                        IGiwaRouter.BuyParams({
                            amountIn: currentAmount,
                            amountOutMin: 0,
                            token: tokenOut,
                            to: address(this),
                            deadline: block.timestamp
                        })
                    );
                    IERC20(currentToken).forceApprove(router, 0);
                } else {
                    IDexAdapter adapter = hop.adapter;
                    bool adapterAllowed;
                    if (address(adapter) != address(0) && adapter == uniswapV2Adapter) {
                        adapterAllowed = true;
                    }
                    if (!adapterAllowed && address(adapter) != address(0) && adapter == uniswapV3Adapter) {
                        adapterAllowed = true;
                    }
                    if (!adapterAllowed) revert UnknownAdapter();

                    IERC20(currentToken).safeTransfer(address(adapter), currentAmount);
                    adapter.swap(hop.pair, currentToken, tokenOut, currentAmount, address(this), "");
                }

                uint256 inputBalanceAfter = IERC20(currentToken).balanceOf(address(this));
                if (i == 0) consumed = sourceQuoteBalanceBefore - inputBalanceAfter;
                if (i != 0 && inputBalanceAfter > inputBalanceBefore - currentAmount) revert PathResidue();

                currentAmount = IERC20(tokenOut).balanceOf(address(this)) - tokenOutBalanceBefore;
                currentToken = tokenOut;
            }

            uint256 received = currentAmount;
            if (received < order.amountOutMin) revert InsufficientOutput();

            pendingSwap[order.sourceToken][order.dividendToken] = pending - consumed;
            dividendBalance[order.sourceToken][order.dividendToken] += received;
            convertedSourceTokens[orderIndex] = order.sourceToken;
            convertedDividendTokens[orderIndex] = order.dividendToken;
            consumedQuote[orderIndex] = consumed;
            receivedAmounts[orderIndex] = received;
        }

        emit Converted(convertedSourceTokens, convertedDividendTokens, consumedQuote, receivedAmounts);
    }

    /// @notice Operator publishes a new global Merkle root.
    function setMerkleRoot(bytes32 newRoot) external restricted {
        if (newRoot == bytes32(0)) revert InvalidMerkleRoot();
        merkleRoot = newRoot;
        emit SetMerkleRoot(newRoot);
    }

    /// @notice Holders claim their dividend allocation for the current Merkle period.
    /// @dev msg.sender claims for itself. Per item: verify proof (revert on mismatch); pay
    ///      (amount - claimedCumulative), then advance claimedCumulative. WNATIVE -> native unwrap.
    /// @dev Reverts the entire call on: proof failure (InvalidMerkleProof), unconfigured source
    ///      (SourceNotConfigured), holder below minBalance (BelowMinBalance), and insufficient vault
    ///      balance for the payout (InsufficientVaultBalance). Zero-amount and fully-claimed
    ///      (amount <= claimedCumulative) items are skip-only — keeping republished/equal/lower roots
    ///      idempotent and race-free.
    function claim(
        address[] calldata sourceTokens,
        address[] calldata dividendTokens,
        uint256[] calldata amounts,
        bytes32[][] calldata merkleProofs
    ) external nonReentrant {
        uint256 length = sourceTokens.length;
        if (length == 0 || length != dividendTokens.length || length != amounts.length || length != merkleProofs.length)
        {
            revert InvalidArrayLength();
        }

        bytes32 root = merkleRoot;
        if (root == bytes32(0)) revert InvalidMerkleRoot();

        uint256[] memory paidAmounts = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            address sourceToken = sourceTokens[i];
            address dividendToken = dividendTokens[i];
            uint256 amount = amounts[i];

            if (amount == 0) continue;

            bytes32 leaf = keccak256(abi.encode(sourceToken, msg.sender, dividendToken, amount));
            if (!MerkleProof.verify(merkleProofs[i], root, leaf)) revert InvalidMerkleProof();

            DividendConfig storage config = _config[sourceToken];
            if (config.dividendTokens.length == 0) revert SourceNotConfigured();

            if (IERC20(sourceToken).balanceOf(msg.sender) < config.minBalance) revert BelowMinBalance();

            // ── cumulative-claimed: pay only the unclaimed delta ──
            uint256 alreadyClaimed = claimedCumulative[sourceToken][msg.sender][dividendToken];
            if (amount <= alreadyClaimed) continue; // nothing new accrued for this holder
            uint256 payout = amount - alreadyClaimed;

            if (IERC20(dividendToken).balanceOf(address(this)) < payout) revert InsufficientVaultBalance();

            claimedCumulative[sourceToken][msg.sender][dividendToken] = amount; // high-water mark (== alreadyClaimed + payout)
            address wnativeCached = wnative;
            bool unwrapNative = wnativeCached != address(0) && dividendToken == wnativeCached;
            if (unwrapNative) IWrappedNative(wnativeCached).withdraw(payout);
            if (unwrapNative) TransferHelper.safeTransferNative(msg.sender, payout);
            if (!unwrapNative) IERC20(dividendToken).safeTransfer(msg.sender, payout);
            paidAmounts[i] = payout;
        }

        emit Claim(msg.sender, sourceTokens, dividendTokens, paidAmounts);
    }

    /// @notice Admin sets the WNATIVE singleton used for native unwrap on claim. 0 disables unwrap.
    function setWnative(address newWnative) external restricted {
        wnative = newWnative;
        emit SetWnative(newWnative);
    }

    /// @notice Admin replaces the explicit adapter allowlist lanes. 0 disables that lane.
    function setAdapters(address uniswapV2Adapter_, address uniswapV3Adapter_) external restricted {
        uniswapV2Adapter = IDexAdapter(uniswapV2Adapter_);
        uniswapV3Adapter = IDexAdapter(uniswapV3Adapter_);
        emit SetAdapters(uniswapV2Adapter_, uniswapV3Adapter_);
    }

    /// @notice Admin opens or closes setup admission for an external dividend token.
    function setAllowedDividendToken(address token, bool allowed) external restricted {
        if (!allowed) {
            allowedDividendToken[token] = false;
            emit SetAllowedDividendToken(token, false);
            return;
        }

        if (token.code.length == 0) revert NotContract();
        if (bondingCurveV1.createdAt(token) != 0 && !bondingCurveV1.isGraduated(token)) {
            revert V1TokenNotGraduated();
        }

        allowedDividendToken[token] = true;
        emit SetAllowedDividendToken(token, true);
    }

    function setAuthority(address) public view override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
