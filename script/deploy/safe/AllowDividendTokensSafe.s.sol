// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {DividendVault} from "../../../src/vault/DividendVault.sol";

/// @title AllowDividendTokensSafe
/// @notice Mainnet Safe calldata-printing flow for allowlisting DividendVault dividend tokens.
///
/// Required env:
///   V2_DIVIDEND_VAULT           - DividendVault proxy address
///   MULTISIG                    - Safe multisig address
///   DIVIDEND_ALLOWLIST_TOKENS   - comma-delimited token addresses
///
/// Run:
///   source .env.mainnet && forge script script/AllowDividendTokensSafe.s.sol:AllowDividendTokensSafe \
///       --rpc-url $RPC_URL
contract AllowDividendTokensSafe is Script {
    function run() external view {
        address vault = vm.envAddress("V2_DIVIDEND_VAULT");
        address safe = vm.envAddress("MULTISIG");
        address[] memory tokens = vm.envAddress("DIVIDEND_ALLOWLIST_TOKENS", ",");

        require(vault != address(0), "AllowDividendTokensSafe: V2_DIVIDEND_VAULT zero");
        require(safe != address(0), "AllowDividendTokensSafe: MULTISIG zero");
        require(tokens.length > 0, "AllowDividendTokensSafe: empty DIVIDEND_ALLOWLIST_TOKENS");

        console.log("========================================");
        console.log("Allow DividendVault dividend tokens (Safe calldata)");
        console.log("========================================");
        console.log("DividendVault:                ", vault);
        console.log("Safe Multisig:                ", safe);
        console.log("Token count:                  ", tokens.length);
        console.log("========================================");
        console.log(
            string.concat(
                "Submit the following ", vm.toString(tokens.length), " transactions via Safe Transaction Builder:"
            )
        );
        console.log("");

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            require(token != address(0), "AllowDividendTokensSafe: token zero");

            bytes memory data = abi.encodeCall(DividendVault.setAllowedDividendToken, (token, true));

            console.log("token:", token);
            _logSafeTx(string.concat("Tx ", vm.toString(i + 1), ": setAllowedDividendToken(token, true)"), vault, data);
        }

        console.log("========================================");
        console.log("After Safe execution verify vault.allowedDividendToken(token) == true for each.");
        console.log("========================================");
    }

    function _logSafeTx(string memory title, address target, bytes memory data) internal pure {
        console.log(string.concat("---- ", title, " ----"));
        console.log("  to:   ", target);
        console.log("  data:");
        console.logBytes(data);
        console.log("");
    }
}
