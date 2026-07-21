// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {IProtocolManager} from "../../../src/interfaces/IProtocolManager.sol";
import {ProtocolManager} from "../../../src/core/ProtocolManager.sol";
import {V3PoolDeployer} from "../../../src/core/V3PoolDeployer.sol";
import {BPS} from "../../../src/libraries/Constants.sol";

/// @title AddQuoteToken
/// @notice Registers another quote token and its canonical Uniswap V3 configuration.
/// @dev Required env: CHAIN_ID, MULTISIG_PRIVATE_KEY, PROTOCOL_MANAGER, QUOTE_TOKEN, V3_POOL_DEPLOYER,
///      VIRTUAL_RESERVE, VIRTUAL_TOKEN_RESERVE, MIN_TOKEN_RESERVE, DEPLOY_FEE,
///      GRADUATE_FEE, CURVE_PROTOCOL_FEE_RATE, DEX_PROTOCOL_FEE_RATE,
///      SETTLEMENT_THRESHOLD, V3_FEE_TIER, LP_FEE_PROTOCOL_SHARE_BPS.
contract AddQuoteToken is Script {
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
        require(block.chainid == vm.envUint("CHAIN_ID"), "AddQuoteToken: CHAIN_ID mismatch");
        uint256 signerKey = vm.envUint("MULTISIG_PRIVATE_KEY");
        address protocolManagerAddress = vm.envAddress("PROTOCOL_MANAGER");
        address quoteToken = vm.envAddress("QUOTE_TOKEN");
        address v3PoolDeployer = vm.envAddress("V3_POOL_DEPLOYER");
        address signer = vm.addr(signerKey);
        QuoteTokenConfig memory config = _readConfig();

        require(protocolManagerAddress.code.length > 0, "AddQuoteToken: ProtocolManager missing code");
        require(quoteToken.code.length > 0, "AddQuoteToken: quote token missing code");
        require(v3PoolDeployer.code.length > 0, "AddQuoteToken: V3PoolDeployer missing code");
        require(
            V3PoolDeployer(v3PoolDeployer).authority() == protocolManagerAddress,
            "AddQuoteToken: V3PoolDeployer authority mismatch"
        );
        address v3Factory = V3PoolDeployer(v3PoolDeployer).factory();
        require(v3Factory.code.length > 0, "AddQuoteToken: V3 factory missing code");
        require(
            IUniswapV3Factory(v3Factory).feeAmountTickSpacing(config.v3FeeTier) != 0,
            "AddQuoteToken: unsupported V3 fee tier"
        );
        require(config.lpFeeProtocolShareBps <= BPS, "AddQuoteToken: LP fee share exceeds BPS");

        ProtocolManager protocolManager = ProtocolManager(protocolManagerAddress);
        require(protocolManager.owner() == signer, "AddQuoteToken: signer must equal PM.owner");
        require(!protocolManager.getConfig(quoteToken).active, "AddQuoteToken: quote token already active");

        vm.startBroadcast(signerKey);
        _addQuoteToken(protocolManager, quoteToken, config);
        vm.stopBroadcast();
        _verify(protocolManager.getConfig(quoteToken), config, IERC20Metadata(quoteToken).decimals());

        console.log("Quote token added:", quoteToken);
        console.log("ProtocolManager: ", protocolManagerAddress);
        console.log("V3 fee tier:    ", config.v3FeeTier);
        console.log("LP protocol BPS:", config.lpFeeProtocolShareBps);
    }

    function _addQuoteToken(ProtocolManager protocolManager, address quoteToken, QuoteTokenConfig memory config)
        internal
    {
        protocolManager.addV3QuoteToken(
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

    function _verify(IProtocolManager.QuoteConfig memory actual, QuoteTokenConfig memory expected, uint8 decimals)
        internal
        pure
    {
        require(actual.active, "Verify: quote token inactive");
        require(actual.decimals == decimals, "Verify: decimals mismatch");
        require(actual.virtualReserve == expected.virtualReserve, "Verify: virtualReserve mismatch");
        require(actual.virtualTokenReserve == expected.virtualTokenReserve, "Verify: virtualTokenReserve mismatch");
        require(actual.minTokenReserve == expected.minTokenReserve, "Verify: minTokenReserve mismatch");
        require(actual.deployFee == expected.deployFee, "Verify: deployFee mismatch");
        require(actual.graduateFee == expected.graduateFee, "Verify: graduateFee mismatch");
        require(actual.curveProtocolFeeRate == expected.curveProtocolFeeRate, "Verify: curve fee mismatch");
        require(actual.dexProtocolFeeRate == expected.dexProtocolFeeRate, "Verify: DEX fee mismatch");
        require(actual.settlementThreshold == expected.settlementThreshold, "Verify: threshold mismatch");
        require(actual.v3FeeTier == expected.v3FeeTier, "Verify: V3 fee tier mismatch");
        require(actual.lpFeeProtocolShareBps == expected.lpFeeProtocolShareBps, "Verify: LP fee share mismatch");
    }

    function _readUint16(string memory key) internal view returns (uint16 value) {
        uint256 rawValue = vm.envUint(key);
        require(rawValue <= type(uint16).max, "AddQuoteToken: uint16 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        value = uint16(rawValue);
    }

    function _readUint24(string memory key) internal view returns (uint24 value) {
        uint256 rawValue = vm.envUint(key);
        require(rawValue <= type(uint24).max, "AddQuoteToken: uint24 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        value = uint24(rawValue);
    }
}
