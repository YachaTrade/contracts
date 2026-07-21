// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {IProtocolManager} from "../../../src/interfaces/IProtocolManager.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";
import {V3PoolDeployer} from "../../../src/core/V3PoolDeployer.sol";
import {BPS} from "../../../src/libraries/Constants.sol";

/// @title UpdateQuoteToken
/// @notice Updates an existing quote token config on ProtocolManager.
/// @dev Change only QUOTE_TOKEN to reuse this script for another quote token.
///
///      Environment variables:
///        CHAIN_ID              - expected RPC chain id
///        MULTISIG_PRIVATE_KEY - signer key for ProtocolManager owner
///        PROTOCOL_MANAGER     - deployed ProtocolManager proxy
///        QUOTE_TOKEN          - quote token address to update
///        V3_POOL_DEPLOYER      - deployed canonical V3PoolDeployer proxy
///        Quote config values   - VIRTUAL_RESERVE, DEPLOY_FEE, V3_FEE_TIER, etc.
///
///      Run:
///        source .env && forge script script/UpdateQuoteToken.s.sol:UpdateQuoteToken \
///            --rpc-url $RPC_URL --broadcast
contract UpdateQuoteToken is Script {
    struct QuoteTokenConfig {
        uint256 virtualReserve;
        uint256 virtualTokenReserve;
        uint256 minTokenReserve;
        uint256 deployFee;
        uint256 graduateFee;
        uint16 curveProtocolFeeRate;
        uint16 dexProtocolFeeRate;
        uint256 settlementThreshold;
        uint24 v3FeeTier;
        uint16 lpFeeProtocolShareBps;
    }

    function run() external {
        require(block.chainid == vm.envUint("CHAIN_ID"), "UpdateQuoteToken: CHAIN_ID mismatch");
        uint256 signerKey = vm.envUint("MULTISIG_PRIVATE_KEY");
        address protocolManager = vm.envAddress("PROTOCOL_MANAGER");
        address quoteToken = vm.envAddress("QUOTE_TOKEN");
        address v3PoolDeployer = vm.envAddress("V3_POOL_DEPLOYER");
        address signer = vm.addr(signerKey);
        QuoteTokenConfig memory updateConfig = _readConfig();

        require(protocolManager.code.length > 0, "UpdateQuoteToken: ProtocolManager missing code");
        require(quoteToken.code.length > 0, "UpdateQuoteToken: quote token missing code");
        require(v3PoolDeployer.code.length > 0, "UpdateQuoteToken: V3PoolDeployer missing code");
        require(
            V3PoolDeployer(v3PoolDeployer).authority() == protocolManager,
            "UpdateQuoteToken: V3PoolDeployer authority mismatch"
        );
        address v3Factory = V3PoolDeployer(v3PoolDeployer).factory();
        require(v3Factory.code.length > 0, "UpdateQuoteToken: V3 factory missing code");
        require(
            IUniswapV3Factory(v3Factory).feeAmountTickSpacing(updateConfig.v3FeeTier) != 0,
            "UpdateQuoteToken: unsupported V3 fee tier"
        );
        require(updateConfig.lpFeeProtocolShareBps <= BPS, "UpdateQuoteToken: LP fee share exceeds BPS");

        ProtocolManager pm = ProtocolManager(protocolManager);
        require(pm.owner() == signer, "UpdateQuoteToken: signer must equal PM.owner");

        IProtocolManager.QuoteConfig memory beforeConfig = pm.getConfig(quoteToken);
        require(beforeConfig.active, "UpdateQuoteToken: quote token not active");
        require(beforeConfig.decimals == IERC20Metadata(quoteToken).decimals(), "UpdateQuoteToken: decimals mismatch");

        _logConfig("Before", beforeConfig);

        vm.startBroadcast(signerKey);

        _updateQuoteToken(pm, quoteToken, updateConfig);

        vm.stopBroadcast();

        IProtocolManager.QuoteConfig memory afterConfig = pm.getConfig(quoteToken);
        _verify(afterConfig, updateConfig, beforeConfig.decimals);
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
        config.v3FeeTier = _readUint24("V3_FEE_TIER");
        config.lpFeeProtocolShareBps = _readUint16("LP_FEE_PROTOCOL_SHARE_BPS");
    }

    function _updateQuoteToken(ProtocolManager pm, address quoteToken, QuoteTokenConfig memory config) internal {
        pm.updateV3QuoteToken(
            quoteToken,
            config.virtualReserve,
            config.virtualTokenReserve,
            config.minTokenReserve,
            config.deployFee,
            config.graduateFee,
            config.curveProtocolFeeRate,
            config.dexProtocolFeeRate,
            config.settlementThreshold,
            config.v3FeeTier,
            config.lpFeeProtocolShareBps
        );
    }

    function _readUint16(string memory key) internal view returns (uint16 value) {
        uint256 rawValue = vm.envUint(key);
        require(rawValue <= type(uint16).max, "UpdateQuoteToken: uint16 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        value = uint16(rawValue);
    }

    function _readUint24(string memory key) internal view returns (uint24 value) {
        uint256 rawValue = vm.envUint(key);
        require(rawValue <= type(uint24).max, "UpdateQuoteToken: uint24 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        value = uint24(rawValue);
    }

    function _verify(IProtocolManager.QuoteConfig memory config, QuoteTokenConfig memory expected, uint8 decimals)
        internal
        pure
    {
        require(config.decimals == decimals, "Verify: decimals mismatch");
        require(config.virtualReserve == expected.virtualReserve, "Verify: virtualReserve mismatch");
        require(config.virtualTokenReserve == expected.virtualTokenReserve, "Verify: virtualTokenReserve mismatch");
        require(config.minTokenReserve == expected.minTokenReserve, "Verify: minTokenReserve mismatch");
        require(config.deployFee == expected.deployFee, "Verify: deployFee mismatch");
        require(config.graduateFee == expected.graduateFee, "Verify: graduateFee mismatch");
        require(config.curveProtocolFeeRate == expected.curveProtocolFeeRate, "Verify: curveProtocolFeeRate mismatch");
        require(config.dexProtocolFeeRate == expected.dexProtocolFeeRate, "Verify: dexProtocolFeeRate mismatch");
        require(config.settlementThreshold == expected.settlementThreshold, "Verify: settlementThreshold mismatch");
        require(config.v3FeeTier == expected.v3FeeTier, "Verify: v3FeeTier mismatch");
        require(config.lpFeeProtocolShareBps == expected.lpFeeProtocolShareBps, "Verify: LP fee share mismatch");
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
        console.log("v3FeeTier:             ", config.v3FeeTier);
        console.log("lpFeeProtocolShareBps:", config.lpFeeProtocolShareBps);
        console.log("active:               ", config.active);
    }
}
