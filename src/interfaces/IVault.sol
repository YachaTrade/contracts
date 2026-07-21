// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//
//
//

/// @notice All vault implementations must implement this interface.
///         CreatorFeeProcessor transfers quoteToken then calls afterDeposit().
///
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IVault is IERC165 {
    /// @notice Called by CreatorFeeProcessor after transferring quoteToken to this vault.
    /// @dev Must handle per-token logic using token parameter.
    ///      May silently skip on internal failures (try/catch).
    /// @param token The token address (identifies which token's creator fee is being processed)
    /// @param quoteToken The quote token that was transferred
    /// @param amount The amount of quoteToken transferred
    function afterDeposit(address token, address quoteToken, uint256 amount) external;

    /// @notice Per-token setup called by BondingCurve during token creation.
    /// @dev Only vaults that need per-token configuration implement this.
    ///      Vaults without per-token configuration may use a no-op. CreatorFeeVault registers a recipient.
    /// @param token The token being created
    /// @param data Vault-specific setup data (e.g., abi.encode(recipient) for CreatorFeeVault)
    function setup(address token, bytes calldata data) external;

    /// @notice Off-chain metadata URI describing this vault implementation (name, icon, docs link, etc.).
    /// @dev Vault-level value. Set once during initialize(). Not per-token.
    /// @return The metadata URI string
    function metadataURI() external view returns (string memory);
}
