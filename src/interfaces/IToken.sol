// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IToken -- Simple ERC20 token interface for NadFun v2
/// @notice Deployed as ERC-1167 clone by BondingCurve. No fee-on-transfer.
///         Fee collection happens at the NadFunPair and BondingCurve level.
interface IToken {
    error AlreadyInitialized();
    error NotBondingCurve();
    error AlreadyGraduated();
    error TransferToPairBeforeGraduation();

    /// @notice Clone initializer. Called once by BondingCurve after deployment.
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param tokenURI_ Token metadata URI
    /// @param bondingCurve_ BondingCurve contract address (receives total supply)
    /// @param pair_ NadFunPair address (transfer blocked before graduation)
    function initialize(
        string memory name_,
        string memory symbol_,
        string memory tokenURI_,
        address bondingCurve_,
        address pair_
    ) external;

    /// @notice Called by BondingCurve on graduation. Sets isGraduated flag.
    function setIsGraduated() external;

    /// @notice Whether this token has graduated from bonding curve to DEX.
    function isGraduated() external view returns (bool);

    /// @notice The BondingCurve contract that deployed this token.
    function bondingCurve() external view returns (address);

    /// @notice The NadFunPair address for this token.
    function pair() external view returns (address);

    /// @notice Token metadata URI.
    function tokenURI() external view returns (string memory);

    /// @notice Fixed total supply: 1 billion tokens (1e27 wei).
    function TOTAL_SUPPLY() external view returns (uint256);
}
