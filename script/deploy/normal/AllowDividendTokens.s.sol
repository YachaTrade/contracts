// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {DividendVault} from "../../../src/vault/DividendVault.sol";

interface IOwnableView {
    function owner() external view returns (address);
}

/// @title AllowDividendTokens
/// @notice Testnet direct-broadcast flow for allowlisting DividendVault dividend tokens.
///
/// Required env:
///   MULTISIG_PRIVATE_KEY        - signer key; on testnet this EOA is the ProtocolManager owner
///   V2_PROTOCOL_MANAGER         - ProtocolManager proxy address
///   V2_DIVIDEND_VAULT           - DividendVault proxy address
///   DIVIDEND_ALLOWLIST_TOKENS   - comma-delimited token addresses
///
/// Run:
///   source .env.testnet && forge script script/AllowDividendTokens.s.sol:AllowDividendTokens \
///       --rpc-url $RPC_URL --broadcast
contract AllowDividendTokens is Script {
    function run() external {
        uint256 key = vm.envUint("MULTISIG_PRIVATE_KEY");
        address signer = vm.addr(key);
        address protocolManager = vm.envAddress("V2_PROTOCOL_MANAGER");
        address vault = vm.envAddress("V2_DIVIDEND_VAULT");
        address[] memory tokens = vm.envAddress("DIVIDEND_ALLOWLIST_TOKENS", ",");

        require(vault != address(0), "AllowDividendTokens: V2_DIVIDEND_VAULT zero");
        require(protocolManager != address(0), "AllowDividendTokens: V2_PROTOCOL_MANAGER zero");
        require(tokens.length > 0, "AllowDividendTokens: empty DIVIDEND_ALLOWLIST_TOKENS");

        address owner = IOwnableView(protocolManager).owner();
        require(signer == owner, "AllowDividendTokens: signer is not ProtocolManager owner");

        console.log("========================================");
        console.log("Allow DividendVault dividend tokens (direct EOA broadcast)");
        console.log("========================================");
        console.log("DividendVault:                ", vault);
        console.log("Signer:                       ", signer);
        console.log("Token count:                  ", tokens.length);
        console.log("========================================");

        vm.startBroadcast(key);

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            require(token != address(0), "AllowDividendTokens: token zero");
            DividendVault(payable(vault)).setAllowedDividendToken(token, true);
            console.log("allowed:", token);
        }

        vm.stopBroadcast();

        console.log("========================================");
        console.log("After broadcast, verify vault.allowedDividendToken(token) == true for each token.");
        console.log("========================================");
    }
}
