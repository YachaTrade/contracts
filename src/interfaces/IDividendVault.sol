// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "./IDexAdapter.sol";
import {IBondingCurveV1} from "../integration/interfaces/IBondingCurveV1.sol";
import {ITokenRegistry} from "./ITokenRegistry.sol";
import {IVault} from "./IVault.sol";

/// @title IDividendVault
/// @notice Vault interface for recording creator-fee quote tokens as dividend assets.
///         Bot-driven conversions and operator-published Merkle roots complete distribution.
interface IDividendVault is IVault {
    struct ConversionOrder {
        address sourceToken;
        address dividendToken;
        ConversionHop[] path;
        uint256 quoteIn;
        uint256 amountOutMin;
    }

    struct ConversionHop {
        IDexAdapter adapter;
        address pair;
        address tokenOut;
    }

    struct DividendConfig {
        address[] dividendTokens; // 1~10
        uint16[] ratios; // sum == BPS (10000)
        uint256 minBalance; // eligibility gate used by claim
        // configured-ness == dividendTokens.length != 0, no deactivation path
    }

    event DividendSetup(address indexed sourceToken, address[] dividendTokens, uint16[] ratios, uint256 minBalance);
    /// @notice Emitted once per afterDeposit call with the full configured dividend split.
    /// @dev pending[i] is true when slices[i] was added to pendingSwap, and false when slices[i]
    ///      was credited to dividendBalance immediately for the quote-token slot.
    event Deposit(address indexed sourceToken, address[] dividendTokens, uint256[] slices, bool[] pending);
    event Converted(address[] sourceTokens, address[] dividendTokens, uint256[] consumedQuote, uint256[] received);
    event SetMerkleRoot(bytes32 indexed merkleRoot);
    event Claim(address indexed holder, address[] sourceTokens, address[] dividendTokens, uint256[] amounts);
    event SetWmon(address wmon);
    event SetAdapters(address nadSwapAdapter, address uniswapV2Adapter, address uniswapV3Adapter);
    event SetAllowedDividendToken(address indexed token, bool allowed);

    error NotAuthorized();
    error ZeroAddress();
    error InvalidTokenCount();
    error LengthMismatch();
    error AlreadyConfigured();
    error ZeroRatio();
    error UnsupportedDividendToken();
    error DuplicateDividendToken();
    error InvalidRatioTotal();
    error SourceNotConfigured();
    error BelowMinBalance();
    error InsufficientVaultBalance();
    error InvalidMerkleRoot();
    error InvalidMerkleProof();
    error InvalidArrayLength();
    error UnexpectedNative();
    error UnknownAdapter();
    error InvalidPath();
    error PathResidue();
    error InsufficientOutput();
    error ExcessiveConversion();
    error V1TokenNotGraduated();
    error NotContract();

    /// @notice Holders claim their dividend allocation for the current Merkle period.
    /// @dev msg.sender claims for itself. Per item: verify proof (revert on mismatch); skip if below
    ///      minBalance or fully claimed (amount <= claimedCumulative); pay (amount - claimedCumulative),
    ///      then advance claimedCumulative. WMON -> native unwrap.
    function claim(
        address[] calldata sourceTokens,
        address[] calldata dividendTokens,
        uint256[] calldata amounts,
        bytes32[][] calldata merkleProofs
    ) external;

    /// @notice Operator publishes a new global Merkle root.
    function setMerkleRoot(bytes32 newRoot) external;

    /// @notice Admin replaces the explicit adapter allowlist lanes. 0 disables that lane.
    function setAdapters(address nadSwapAdapter_, address uniswapV2Adapter_, address uniswapV3Adapter_) external;

    /// @notice Admin sets the WMON singleton used for native unwrap on claim. 0 disables unwrap.
    function setWmon(address newWmon) external;

    /// @notice Admin opens or closes setup admission for an external dividend token.
    function setAllowedDividendToken(address token, bool allowed) external;

    /// @notice Operator converts a pending source quote slice through an explicit hop path.
    /// @dev Registered launch tokens use the router hop (hop.adapter == router); GiwaRouter dispatches
    ///      internally between bonding-curve and canonical V3 execution.
    function executeConversion(ConversionOrder[] calldata orders) external;

    /// @notice Get the dividend configuration for a source token.
    function getConfig(address sourceToken) external view returns (DividendConfig memory);

    /// @notice Current global Merkle root used for claim verification.
    function merkleRoot() external view returns (bytes32);

    /// @notice WMON singleton used for native unwrap on claim. 0 disables unwrap.
    function wmon() external view returns (address);

    /// @notice GiwaRouter used directly for registered launch-token buy hops.
    function router() external view returns (address);

    /// @notice Legacy adapter lane retained for existing external conversion routes.
    function nadSwapAdapter() external view returns (IDexAdapter);

    /// @notice Uniswap V2 adapter lane used for allowed external V2 path hops.
    function uniswapV2Adapter() external view returns (IDexAdapter);

    /// @notice Uniswap V3 adapter lane used for allowed external V3 path hops.
    function uniswapV3Adapter() external view returns (IDexAdapter);

    /// @notice V2 token registry used to validate source and dividend tokens.
    function tokenRegistryV2() external view returns (ITokenRegistry);

    /// @notice V1 bonding curve used to gate pre-graduation V1 dividend-token admission.
    function bondingCurveV1() external view returns (IBondingCurveV1);

    /// @notice Whether setup accepts an external, unregistered dividend token.
    function allowedDividendToken(address token) external view returns (bool);

    /// @notice Accrued dividend-token balance for a source/dividend pair.
    function dividendBalance(address sourceToken, address dividendToken) external view returns (uint256);

    /// @notice Pending quoteToken awaiting swap into a specific dividend token.
    function pendingSwap(address sourceToken, address dividendToken) external view returns (uint256);

    /// @notice Cumulative dividend already paid out to a holder for a source/dividend pair across all roots.
    function claimedCumulative(address sourceToken, address holder, address dividendToken)
        external
        view
        returns (uint256);
}
