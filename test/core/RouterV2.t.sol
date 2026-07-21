// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Legacy V2 LPManager regression coverage retained after the unified V2 router removal.

import {SetUp} from "../SetUp.t.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RouterV2Test is SetUp {
    function test_lpManager_addLiquidity() public {
        uint256 tokenIn = 1000 ether;
        uint256 quoteIn = 1 ether;

        MockERC20 token = new MockERC20("Base2", "M2", 18);
        address pair = nadFunFactory.createPair(address(token), address(quoteToken));

        vm.startPrank(admin);
        protocolManager.setOperatorPermission(
            address(this), address(tokenRegistry), ITokenRegistry.register.selector, true
        );
        protocolManager.setOperatorPermission(address(this), address(lpManager), LPManager.addLiquidity.selector, true);
        vm.stopPrank();

        tokenRegistry.register(address(token), pair, address(quoteToken), ITokenRegistry.DexType.UniswapV2);
        token.mint(address(lpManager), tokenIn);
        quoteToken.mint(address(lpManager), quoteIn);

        uint256 liquidity = lpManager.addLiquidity(
            address(token), address(quoteToken), tokenIn, quoteIn, ITokenRegistry.DexType.UniswapV2, pair
        );

        assertGt(liquidity, 0, "Should receive LP tokens");
        assertEq(lpManager.getPair(address(token)), pair, "Pair should be recorded");
        assertEq(lpManager.getLiquidity(address(token), address(this)), liquidity, "Liquidity should be tracked");
    }
}
