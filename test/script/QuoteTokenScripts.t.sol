// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AddQuoteToken} from "../../script/deploy/normal/AddQuoteToken.s.sol";
import {UpdateQuoteToken} from "../../script/deploy/normal/UpdateQuoteToken.s.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract AddQuoteTokenHarness is AddQuoteToken {
    function addQuoteToken(ProtocolManager protocolManager, address quoteToken, QuoteTokenConfig calldata config)
        external
    {
        _addQuoteToken(protocolManager, quoteToken, config);
        _verify(protocolManager.getConfig(quoteToken), config, MockERC20(quoteToken).decimals());
    }
}

contract UpdateQuoteTokenHarness is UpdateQuoteToken {
    function updateQuoteToken(ProtocolManager protocolManager, address quoteToken, QuoteTokenConfig calldata config)
        external
    {
        uint8 decimals = protocolManager.getConfig(quoteToken).decimals;
        _updateQuoteToken(protocolManager, quoteToken, config);
        _verify(protocolManager.getConfig(quoteToken), config, decimals);
    }
}

contract QuoteTokenScriptsTest is Test {
    address private constant FEE_RECEIVER = address(0xFEE);

    function test_addQuoteTokenConfiguresIndependentSixDecimalV3Quotes() public {
        AddQuoteTokenHarness harness = new AddQuoteTokenHarness();
        ProtocolManager protocolManager = _deployProtocolManager(address(harness));
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);

        AddQuoteToken.QuoteTokenConfig memory usdcConfig = _addConfig(500, 2_500);
        AddQuoteToken.QuoteTokenConfig memory usdtConfig = _addConfig(3_000, 7_500);
        harness.addQuoteToken(protocolManager, address(usdc), usdcConfig);
        harness.addQuoteToken(protocolManager, address(usdt), usdtConfig);

        IProtocolManager.QuoteConfig memory actualUsdc = protocolManager.getConfig(address(usdc));
        IProtocolManager.QuoteConfig memory actualUsdt = protocolManager.getConfig(address(usdt));
        assertEq(actualUsdc.decimals, 6);
        assertEq(actualUsdc.v3FeeTier, 500);
        assertEq(actualUsdc.lpFeeProtocolShareBps, 2_500);
        assertEq(actualUsdt.decimals, 6);
        assertEq(actualUsdt.v3FeeTier, 3_000);
        assertEq(actualUsdt.lpFeeProtocolShareBps, 7_500);
    }

    function test_updateQuoteTokenPreservesDecimalsAndUpdatesV3Config() public {
        UpdateQuoteTokenHarness harness = new UpdateQuoteTokenHarness();
        ProtocolManager protocolManager = _deployProtocolManager(address(this));
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        protocolManager.addQuoteToken(address(usdc), 30_000e6, 1_000_000_000 ether, 200_000_000 ether, 1e6, 5e6, 100, 0);
        protocolManager.setV3QuoteConfig(address(usdc), 500, 1_000);
        protocolManager.transferOwnership(address(harness));

        UpdateQuoteToken.QuoteTokenConfig memory config = UpdateQuoteToken.QuoteTokenConfig({
            virtualReserve: 40_000e6,
            virtualTokenReserve: 1_000_000_000 ether,
            minTokenReserve: 250_000_000 ether,
            deployFee: 2e6,
            graduateFee: 6e6,
            curveProtocolFeeRate: 200,
            dexProtocolFeeRate: 25,
            v3FeeTier: 3_000,
            lpFeeProtocolShareBps: 6_000
        });
        harness.updateQuoteToken(protocolManager, address(usdc), config);

        IProtocolManager.QuoteConfig memory actual = protocolManager.getConfig(address(usdc));
        assertEq(actual.decimals, 6);
        assertEq(actual.virtualReserve, config.virtualReserve);
        assertEq(actual.v3FeeTier, 3_000);
        assertEq(actual.lpFeeProtocolShareBps, 6_000);
    }

    function _deployProtocolManager(address owner) private returns (ProtocolManager protocolManager) {
        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()), abi.encodeCall(ProtocolManager.initialize, (owner, FEE_RECEIVER))
                )
            )
        );
    }

    function _addConfig(uint24 feeTier, uint16 protocolShare)
        private
        pure
        returns (AddQuoteToken.QuoteTokenConfig memory config)
    {
        config = AddQuoteToken.QuoteTokenConfig({
            virtualReserve: 30_000e6,
            virtualTokenReserve: 1_000_000_000 ether,
            minTokenReserve: 200_000_000 ether,
            deployFee: 1e6,
            graduateFee: 5e6,
            curveProtocolFeeRate: 100,
            dexProtocolFeeRate: 0,
            v3FeeTier: feeTier,
            lpFeeProtocolShareBps: protocolShare
        });
    }
}
