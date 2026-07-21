// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {ILPManager} from "../../src/interfaces/ILPManager.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAuthority} from "@openzeppelin/contracts/access/manager/IAuthority.sol";
import {IV3LiquidityActor} from "../../src/interfaces/IV3LiquidityActor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockAuthority is IAuthority {
    mapping(bytes32 => bool) public allowed;

    function set(address caller, address target, bytes4 selector, bool value) external {
        allowed[keccak256(abi.encode(caller, target, selector))] = value;
    }

    function canCall(address caller, address target, bytes4 selector) external view returns (bool) {
        return allowed[keccak256(abi.encode(caller, target, selector))];
    }
}

contract MockFactory {}

contract MockActor is IV3LiquidityActor {
    address public immutable override owner;
    address public immutable override factory;

    constructor(address owner_, address factory_) {
        owner = owner_;
        factory = factory_;
    }

    function quoteLiquidityPositions(address) external pure returns (bytes32, int24, int24, uint128) {
        return (bytes32(0), 0, 0, 0);
    }

    function tokenLiquidityPositions(address) external pure returns (bytes32, int24, int24, uint128) {
        return (bytes32(0), 0, 0, 0);
    }

    function mint(ILPManager.PoolData calldata, uint256, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function increase(ILPManager.PoolData calldata, uint256, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function collectFees(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function viewFees(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

    /// Focused API/math smoke tests. Full lifecycle fixtures are covered by integration suites.
    contract LPManagerV3Test is Test {
        function test_setV3LiquidityActor_wiresOnceAndValidates() public {
            MockAuthority authority = new MockAuthority();
            LPManager implementation = new LPManager();
            LPManager manager = LPManager(
                address(
                    new ERC1967Proxy(
                        address(implementation), abi.encodeCall(LPManager.initialize, (address(authority), address(1)))
                    )
                )
            );
            MockFactory factory = new MockFactory();
            MockActor actor = new MockActor(address(manager), address(factory));
            authority.set(address(this), address(manager), manager.setV3LiquidityActor.selector, true);
            manager.setV3LiquidityActor(address(actor), address(factory));
            assertEq(manager.v3LiquidityActor(), address(actor));
            vm.expectRevert(LPManager.InvalidFactory.selector);
            manager.setV3LiquidityActor(address(actor), address(factory));
        }

        function test_setV3LiquidityActor_rejectsWrongOwnerFactoryAndZero() public {
            MockAuthority authority = new MockAuthority();
            LPManager implementation = new LPManager();
            LPManager manager = LPManager(
                address(
                    new ERC1967Proxy(
                        address(implementation), abi.encodeCall(LPManager.initialize, (address(authority), address(1)))
                    )
                )
            );
            MockFactory factory = new MockFactory();
            authority.set(address(this), address(manager), manager.setV3LiquidityActor.selector, true);
            MockActor wrongOwner = new MockActor(address(this), address(factory));
            vm.expectRevert(LPManager.InvalidFactory.selector);
            manager.setV3LiquidityActor(address(wrongOwner), address(factory));
            vm.expectRevert(LPManager.InvalidFactory.selector);
            manager.setV3LiquidityActor(address(0), address(factory));
        }

        function _reference(ILPManager.AllocateParams memory p, bool quoteIsToken0, int24 spacing)
            internal
            pure
            returns (int24)
        {
            uint256 adjusted = FullMath.mulDiv(
                p.virtualTokenReserve, p.virtualQuoteReserve, p.virtualQuoteReserve - p.graduateFee
            );
            uint256 a0 = quoteIsToken0 ? p.virtualQuoteReserve : adjusted;
            uint256 a1 = quoteIsToken0 ? adjusted : p.virtualQuoteReserve;
            uint256 ratio = FullMath.mulDiv(a1, uint256(1) << 128, a0);
            uint160 sqrtPrice = uint160(Math.sqrt(ratio) << 32);
            int24 raw = TickMath.getTickAtSqrtRatio(sqrtPrice);
            int24 aligned = (raw / spacing) * spacing;
            return quoteIsToken0 ? aligned - spacing : aligned + spacing;
        }

        function test_calculateBondingTick_matchesContractV3Reference() public {
            LPManager manager = new LPManager();
            ILPManager.AllocateParams memory p = ILPManager.AllocateParams({
                token: address(1),
                quoteAmount: 1e18,
                tokenAmount: 2e18,
                virtualQuoteReserve: 1_000_000e18,
                virtualTokenReserve: 2_000_000e18,
                graduateFee: 3_000e18
            });
            assertEq(manager.calculateBondingTick(p, true, 60), _reference(p, true, 60));
            assertEq(manager.calculateBondingTick(p, false, 60), _reference(p, false, 60));
        }

        function testFuzz_calculateBondingTick_matchesReference(
            uint128 virtualQuoteReserve,
            uint128 virtualTokenReserve,
            uint96 graduateFee
        ) public {
            virtualQuoteReserve = uint128(bound(virtualQuoteReserve, 1e18, 1e24));
            virtualTokenReserve = uint128(bound(virtualTokenReserve, 1e18, 1e24));
            graduateFee = uint96(bound(graduateFee, 0, virtualQuoteReserve / 2));
            ILPManager.AllocateParams memory p = ILPManager.AllocateParams({
                token: address(1),
                quoteAmount: 1,
                tokenAmount: 1,
                virtualQuoteReserve: virtualQuoteReserve,
                virtualTokenReserve: virtualTokenReserve,
                graduateFee: graduateFee
            });
            LPManager manager = new LPManager();
            assertEq(manager.calculateBondingTick(p, true, 60), _reference(p, true, 60));
            assertEq(manager.calculateBondingTick(p, false, 60), _reference(p, false, 60));
        }

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

        function test_calculateBondingTick_rejectsGraduateFeeAtReserve() public {
            LPManager manager = new LPManager();
            ILPManager.AllocateParams memory p = ILPManager.AllocateParams({
                token: address(1),
                quoteAmount: 0,
                tokenAmount: 0,
                virtualQuoteReserve: 100,
                virtualTokenReserve: 1,
                graduateFee: 100
            });
            vm.expectRevert(LPManager.InvalidConfig.selector);
            manager.calculateBondingTick(p, true, 60);
        }

        function test_getPositions_revertsBeforeAllocation() public {
            LPManager manager = new LPManager();
            vm.expectRevert(LPManager.InvalidPool.selector);
            manager.getPositions(address(1));
        }
    }
