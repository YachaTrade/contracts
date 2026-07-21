// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {IProtocolManager} from "../../../src/interfaces/IProtocolManager.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";

/// @title UpdateQuoteToken
/// @notice Updates an existing quote token config on ProtocolManager.
/// @dev Change only QUOTE_TOKEN to reuse this script for another quote token.
///
///      Environment variables:
///        MULTISIG_PRIVATE_KEY - signer key for ProtocolManager owner
///        V2_PROTOCOL_MANAGER  - deployed ProtocolManager proxy
///        QUOTE_TOKEN          - quote token address to update
///        Quote config values   - VIRTUAL_RESERVE, DEPLOY_FEE, etc.
///
///      Run:
///        source .env && forge script script/UpdateQuoteToken.s.sol:UpdateQuoteToken \
///            --rpc-url $RPC_URL --broadcast
contract UpdateQuoteToken is Script {
    uint8 internal constant DECIMALS = 18;

    struct QuoteTokenConfig {
        uint256 virtualReserve;
        uint256 virtualTokenReserve;
        uint256 minTokenReserve;
        uint256 deployFee;
        uint256 graduateFee;
        uint16 curveProtocolFeeRate;
        uint16 dexProtocolFeeRate;
        uint256 settlementThreshold;
    }

    function run() external {
        uint256 signerKey = vm.envUint("MULTISIG_PRIVATE_KEY");
        address protocolManager = vm.envAddress("V2_PROTOCOL_MANAGER");
        address quoteToken = vm.envAddress("QUOTE_TOKEN");
        address signer = vm.addr(signerKey);
        QuoteTokenConfig memory updateConfig = _readConfig();

        ProtocolManager pm = ProtocolManager(protocolManager);
        require(pm.owner() == signer, "UpdateQuoteToken: signer must equal PM.owner");

        IProtocolManager.QuoteConfig memory beforeConfig = pm.getConfig(quoteToken);
        require(beforeConfig.active, "UpdateQuoteToken: quote token not active");
        require(beforeConfig.decimals == DECIMALS, "UpdateQuoteToken: decimals mismatch");

        _logConfig("Before", beforeConfig);

        vm.startBroadcast(signerKey);

        pm.updateQuoteToken(
            quoteToken,
            updateConfig.virtualReserve,
            updateConfig.virtualTokenReserve,
            updateConfig.minTokenReserve,
            updateConfig.deployFee,
            updateConfig.graduateFee,
            updateConfig.curveProtocolFeeRate,
            updateConfig.dexProtocolFeeRate,
            updateConfig.settlementThreshold
        );

        vm.stopBroadcast();

        IProtocolManager.QuoteConfig memory afterConfig = pm.getConfig(quoteToken);
        _verify(afterConfig, updateConfig);
        _logConfig("After", afterConfig);

        console.log("========================================");
        console.log("Quote token updated");
        console.log("ProtocolManager:", protocolManager);
        console.log("QuoteToken:     ", quoteToken);
        console.log("Signer:         ", signer);
        console.log("========================================");
    }

    function _readConfig() internal view returns (QuoteTokenConfig memory config) {
        config.virtualReserve = vm.envUint("VIRTUAL_RESERVE");
        config.virtualTokenReserve = vm.envUint("VIRTUAL_TOKEN_RESERVE");
        config.minTokenReserve = vm.envUint("MIN_TOKEN_RESERVE");
        config.deployFee = vm.envUint("DEPLOY_FEE");
        config.graduateFee = vm.envUint("GRADUATE_FEE");
        config.curveProtocolFeeRate = _readUint16("CURVE_PROTOCOL_FEE_RATE");
        config.dexProtocolFeeRate = _readUint16("DEX_PROTOCOL_FEE_RATE");
        config.settlementThreshold = vm.envUint("SETTLEMENT_THRESHOLD");
    }

    function _readUint16(string memory key) internal view returns (uint16 value) {
        uint256 rawValue = vm.envUint(key);
        require(rawValue <= type(uint16).max, "UpdateQuoteToken: uint16 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        value = uint16(rawValue);
    }

    function _verify(IProtocolManager.QuoteConfig memory config, QuoteTokenConfig memory expected) internal pure {
        require(config.decimals == DECIMALS, "Verify: decimals mismatch");
        require(config.virtualReserve == expected.virtualReserve, "Verify: virtualReserve mismatch");
        require(config.virtualTokenReserve == expected.virtualTokenReserve, "Verify: virtualTokenReserve mismatch");
        require(config.minTokenReserve == expected.minTokenReserve, "Verify: minTokenReserve mismatch");
        require(config.deployFee == expected.deployFee, "Verify: deployFee mismatch");
        require(config.graduateFee == expected.graduateFee, "Verify: graduateFee mismatch");
        require(config.curveProtocolFeeRate == expected.curveProtocolFeeRate, "Verify: curveProtocolFeeRate mismatch");
        require(config.dexProtocolFeeRate == expected.dexProtocolFeeRate, "Verify: dexProtocolFeeRate mismatch");
        require(config.settlementThreshold == expected.settlementThreshold, "Verify: settlementThreshold mismatch");
        require(config.active, "Verify: active mismatch");
    }

    function _logConfig(string memory label, IProtocolManager.QuoteConfig memory config) internal pure {
        console.log("========================================");
        console.log(label);
        console.log("========================================");
        console.log("decimals:             ", config.decimals);
        console.log("virtualReserve:       ", config.virtualReserve);
        console.log("virtualTokenReserve:  ", config.virtualTokenReserve);
        console.log("minTokenReserve:      ", config.minTokenReserve);
        console.log("deployFee:            ", config.deployFee);
        console.log("graduateFee:          ", config.graduateFee);
        console.log("curveProtocolFeeRate: ", config.curveProtocolFeeRate);
        console.log("dexProtocolFeeRate:   ", config.dexProtocolFeeRate);
        console.log("settlementThreshold:  ", config.settlementThreshold);
        console.log("active:               ", config.active);
    }
}
