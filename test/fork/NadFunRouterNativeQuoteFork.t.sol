// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILvMonMinter} from "../../src/interfaces/ILvMonMinter.sol";
import {IWrappedNative} from "../../src/interfaces/IWrappedNative.sol";
import {NadFunRouter} from "../../src/router/NadFunRouter.sol";

contract NadFunRouterNativeQuoteHarness is NadFunRouter {
    function fundQuoteFromNativeForTest(address quoteToken, uint256 quoteIn) external payable {
        _fundQuoteFromNative(quoteToken, quoteIn);
    }
}

contract NadFunRouterNativeQuoteForkTest is Test {
    NadFunRouterNativeQuoteHarness internal router;
    IWrappedNative internal wmon;
    ILvMonMinter internal lvmonMinter;
    IERC20 internal lvmon;

    address internal user;

    function setUp() public {
        if (!vm.envOr("RUN_FORK_TESTS", false)) {
            vm.skip(true, "Set RUN_FORK_TESTS=true to run fork tests");
        }

        vm.createSelectFork(vm.envString("RPC_URL"));

        wmon = IWrappedNative(vm.envAddress("WMON"));
        lvmonMinter = ILvMonMinter(vm.envAddress("LVMON_MINTER"));
        lvmon = IERC20(vm.envAddress("LV_MON"));
        user = makeAddr("forkUser");

        assertEq(address(lvmonMinter.lvmon()), address(lvmon), "env LV_MON should match minter.lvmon");

        NadFunRouterNativeQuoteHarness impl = new NadFunRouterNativeQuoteHarness();
        router = NadFunRouterNativeQuoteHarness(
            payable(address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            NadFunRouter.initialize,
                            (address(0xA11CE), address(0xB0B), address(0xC0DE), address(wmon), address(lvmonMinter))
                        )
                    )
                ))
        );
    }

    function test_fundQuoteFromNative_usesRealWmonDeposit() public {
        uint256 quoteIn = 1 ether;

        vm.deal(user, quoteIn);
        vm.prank(user);
        router.fundQuoteFromNativeForTest{value: quoteIn}(address(wmon), quoteIn);

        assertEq(wmon.balanceOf(address(router)), quoteIn, "Router should receive real WMON");
        assertEq(address(router).balance, 0, "Router should hold no native");
    }

    function test_fundQuoteFromNative_usesRealLvmonMint() public {
        uint256 quoteIn = 1 ether;

        if (!lvmonMinter.whitelist(address(router))) {
            vm.prank(lvmonMinter.owner());
            lvmonMinter.setWhitelist(address(router), true);
        }

        uint256 routerQuoteBefore = lvmon.balanceOf(address(router));
        uint256 userQuoteBefore = lvmon.balanceOf(user);

        vm.deal(user, quoteIn);
        vm.prank(user);
        router.fundQuoteFromNativeForTest{value: quoteIn}(address(lvmon), quoteIn);

        uint256 routerQuoteIn = lvmon.balanceOf(address(router)) - routerQuoteBefore;
        uint256 userQuoteRefund = lvmon.balanceOf(user) - userQuoteBefore;

        assertGe(routerQuoteIn + userQuoteRefund, quoteIn, "Minter should mint enough LVMON");
        assertEq(routerQuoteIn, quoteIn, "Router should retain requested LVMON quote");
        assertEq(address(router).balance, 0, "Router should hold no native");
    }
}
