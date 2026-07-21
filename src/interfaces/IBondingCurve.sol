// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITokenRegistry} from "./ITokenRegistry.sol";

/// @title IBondingCurve
/// @notice Core bonding curve interface for token creation, trading, and graduation.

interface IBondingCurve {
    // V1: constant product AMM (x * y = k)
    enum CurveVersion {
        V1
    }

    struct Curve {
        address token;
        address creator;
        address quoteToken;
        /// @dev AMM quote reserve (virtual + real), buy increases, sell decreases
        uint256 virtualQuoteReserve;
        /// @dev AMM token reserve (virtual + real), buy decreases, sell increases
        uint256 virtualTokenReserve;
        uint256 k;
        uint256 minTokenReserve;
        uint256 initialQuoteReserve;
        uint256 initialTokenReserve;
        /// @dev `block.number` at curve creation. Drives anti-sniping window via
        ///      ProtocolManager's per-block penalty table.
        uint64 createdAtBlock;
        bool graduated;
        CurveVersion version;
        ITokenRegistry.DexType dexType;
        address pair;
        uint256 graduateFee;
    }

    /// @notice Vault allocation for token creation
    struct VaultAllocation {
        /// @dev Singleton vault address (registered in VaultRegistry)
        address vault;
        /// @dev Basis points allocation (> 0, sum = 10000)
        uint16 bps;
        /// @dev Vault-specific setup data (e.g., recipient for CreatorFeeVault)
        bytes setupData;
    }

    struct CreateTokenParams {
        string name;
        string symbol;
        string tokenURI;
        address quoteToken;
        /// @dev Vault allocations (max 5, bps sum = 10000)
        VaultAllocation[] vaults;
        bytes32 salt;
        ITokenRegistry.DexType dexType;
        address creator;
        /// @dev Explicit quote amount to use for the optional initial buy.
        uint256 buyQuoteAmount;
    }

    event Create(
        address indexed creator,
        address indexed token,
        address indexed pair,
        address quoteToken,
        string name,
        string symbol,
        string tokenURI,
        uint256 virtualQuoteReserve,
        uint256 virtualTokenReserve,
        uint256 minTokenReserve
    );

    event Buy(address indexed token, address indexed buyer, uint256 quoteIn, uint256 tokenOut);

    event Sell(address indexed token, address indexed seller, uint256 tokenIn, uint256 quoteOut);

    event Graduate(address indexed token, address indexed pair);

    event SnipingPenalty(address indexed token, address indexed buyer, uint256 snipingFee, uint256 penaltyBps);

    event Sync(
        address indexed token,
        uint256 realQuoteReserve,
        uint256 realTokenReserve,
        uint256 virtualQuoteReserve,
        uint256 virtualTokenReserve
    );

    event ModuleUpdate(bytes32 indexed moduleId, address indexed module);

    event Halt(bool halted);

    error TokenNotFound();
    error AlreadyGraduated();
    error InvalidKValue();
    error ProtocolHalted();
    error UnsupportedVersion();
    error ZeroModule();
    error ModuleAlreadySet(bytes32 moduleId);
    error InsufficientTokenOut();
    error DuplicateVault();
    error InvalidBalanceDelta(address token, address account, uint256 requiredBalance, uint256 currentBalance);

    function create(CreateTokenParams calldata params) external payable returns (address token, uint256 tokenOut);

    function buy(address to, address token, uint256 quoteIn) external returns (uint256 tokenOut);

    function sell(address to, address token, uint256 tokenIn) external returns (uint256 quoteOut);

    function getCurve(address token) external view returns (Curve memory);

    function getQuoteToken(address token) external view returns (address);

    function isHalted() external view returns (bool);

    function getAmountOut(address token, uint256 amountIn, bool isBuy) external view returns (uint256 amountOut);

    function getAmountIn(address token, uint256 amountOut, bool isBuy) external view returns (uint256 amountIn);

    function getSnipingPenalty(address token) external view returns (uint256 penaltyBps);

    function setModule(bytes32 moduleId, address module) external;

    function halt(bool halted) external;
}
