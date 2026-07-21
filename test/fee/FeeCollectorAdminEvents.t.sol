// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";

contract FeeCollectorAdminEventsTest is Test {
    FeeCollector collector;
    ProtocolManager protocolManager;

    address feeReceiver = makeAddr("feeReceiver");
    address creatorFeeProcessor = makeAddr("creatorFeeProcessor");
    address bondingCurve = makeAddr("bondingCurve");
    address router = makeAddr("router");
    address pair = makeAddr("pair");
    address token = makeAddr("token");
    address quoteToken = makeAddr("quoteToken");

    function setUp() public {
        ProtocolManager pmImpl = new ProtocolManager();
        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(ProtocolManager.initialize, (address(this), feeReceiver))
                )
            )
        );

        FeeCollector collectorImpl = new FeeCollector();
        collector = FeeCollector(
            address(
                new ERC1967Proxy(
                    address(collectorImpl),
                    abi.encodeCall(
                        FeeCollector.initialize, (address(protocolManager), creatorFeeProcessor, bondingCurve, router)
                    )
                )
            )
        );

        vm.prank(bondingCurve);
        collector.setup(pair, token, quoteToken, 200, 100, 100);
    }

    function test_setCurveProtocolFeeRate_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(collector));
        emit IFeeCollector.CurveProtocolFeeRateUpdate(pair, 100, 300);

        collector.setCurveProtocolFeeRate(pair, 300);
    }

    function test_setDexProtocolFeeRate_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(collector));
        emit IFeeCollector.DexProtocolFeeRateUpdate(pair, 100, 400);

        collector.setDexProtocolFeeRate(pair, 400);
    }
}
