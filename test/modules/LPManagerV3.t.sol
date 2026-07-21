// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {ILPManager} from "../../src/interfaces/ILPManager.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";

/// Focused API/math smoke tests. Full lifecycle fixtures are covered by integration suites.
contract LPManagerV3Test is Test {
    function test_legacyLiquidityDisabled() public {
        LPManager manager = new LPManager();
        vm.expectRevert(ILPManager.LegacyLiquidityDisabled.selector);
        manager.addLiquidity(address(1), address(2), 0, 0, ITokenRegistry.DexType.UniswapV3, address(3));
        vm.expectRevert(ILPManager.LegacyLiquidityDisabled.selector);
        manager.claimFees(address(1));
    }

    function test_calculateBondingTick_rejectsInvalidInputs() public {
        LPManager manager = new LPManager();
        ILPManager.AllocateParams memory p;
        vm.expectRevert(LPManager.InvalidConfig.selector);
        manager.calculateBondingTick(p, true, 0);
    }
}
