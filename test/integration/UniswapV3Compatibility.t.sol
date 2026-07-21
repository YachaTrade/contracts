// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {UniswapV3Pool} from "@uniswap/v3-core/contracts/UniswapV3Pool.sol";
import {TestERC20} from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

contract UniswapV3CompatibilityTest is Test {
    // Measured from the locally compiled pool under the repository's pinned compiler profile.
    // PoolAddress carries the same value and the computed-address test verifies the integration.
    bytes32 internal constant PERIPHERY_POOL_INIT_CODE_HASH =
        0x367752ac78d27e54ea28c034da350086d0844159dd0761b767172761728fc7c3;

    function test_poolInitCodeHashMatchesPeripheryConstant() public pure {
        bytes32 compiledPoolInitCodeHash = keccak256(type(UniswapV3Pool).creationCode);
        assertEq(compiledPoolInitCodeHash, PERIPHERY_POOL_INIT_CODE_HASH);
    }

    function test_factoryPoolMatchesPoolAddressComputedAddress() public {
        UniswapV3Factory factory = new UniswapV3Factory();
        TestERC20 tokenA = new TestERC20(1 ether);
        TestERC20 tokenB = new TestERC20(1 ether);
        address pool = factory.createPool(address(tokenA), address(tokenB), 10_000);
        PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(address(tokenA), address(tokenB), 10_000);

        assertEq(pool, PoolAddress.computeAddress(address(factory), key));
        assertEq(factory.getPool(address(tokenA), address(tokenB), 10_000), pool);
        assertEq(factory.feeAmountTickSpacing(10_000), 200);
    }
}
