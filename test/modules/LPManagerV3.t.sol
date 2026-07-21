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
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAuthority is IAuthority {
    mapping(bytes32 => bool) public allowed;
    mapping(address => IProtocolManager.QuoteConfig) public configs;
    address public receiver;

    function setReceiver(address r) external {
        receiver = r;
    }

    function setConfig(address q, IProtocolManager.QuoteConfig calldata c) external {
        configs[q] = c;
    }

    function getConfig(address q) external view returns (IProtocolManager.QuoteConfig memory) {
        return configs[q];
    }

    function feeReceiver() external view returns (address) {
        return receiver;
    }

    function set(address caller, address target, bytes4 selector, bool value) external {
        allowed[keccak256(abi.encode(caller, target, selector))] = value;
    }

    function canCall(address caller, address target, bytes4 selector) external view returns (bool) {
        return allowed[keccak256(abi.encode(caller, target, selector))];
    }
}

contract MockFactory {
    address public pool;

    function setPool(address p) external {
        pool = p;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockRegistry {
    ITokenRegistry.TokenInfo public info;

    function setInfo(ITokenRegistry.TokenInfo calldata i) external {
        info = i;
    }

    function getTokenInfo(address) external view returns (ITokenRegistry.TokenInfo memory) {
        return info;
    }

    function getPair(address) external view returns (address) {
        return info.pair;
    }
}

contract MockPool {
    address public token0;
    address public token1;
    address public factory;
    uint24 public fee;
    int24 public tickSpacing;

    constructor(address a, address b, address f, uint24 ft, int24 s) {
        token0 = a;
        token1 = b;
        factory = f;
        fee = ft;
        tickSpacing = s;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (1 << 96, 0, 0, 0, 0, 0, true);
    }
}

contract MockActor is IV3LiquidityActor {
    address public immutable override owner;
    address public immutable override factory;
    uint256 public used0;
    uint256 public used1;
    bool public shouldRevert;
    bytes32 public qpos;
    bytes32 public tpos;

    constructor(address owner_, address factory_) {
        owner = owner_;
        factory = factory_;
    }

    function quoteLiquidityPositions(address) external view returns (bytes32, int24, int24, uint128) {
        return (qpos, 0, 0, 1);
    }

    function tokenLiquidityPositions(address) external view returns (bytes32, int24, int24, uint128) {
        return (tpos, 0, 0, 1);
    }

    function setUsage(uint256 a, uint256 b, bool r) external {
        used0 = a;
        used1 = b;
        shouldRevert = r;
    }

    function mint(ILPManager.PoolData calldata d, uint256 a0, uint256 a1) external returns (uint256, uint256) {
        if (shouldRevert) revert();
        if (qpos != bytes32(0) || tpos != bytes32(0)) revert();
        IERC20(d.token0).transferFrom(msg.sender, address(this), used0);
        IERC20(d.token1).transferFrom(msg.sender, address(this), used1);
        qpos = bytes32(uint256(1));
        tpos = bytes32(uint256(2));
        return (used0, used1);
    }

    function increase(ILPManager.PoolData calldata d, uint256 a0, uint256 a1) external returns (uint256, uint256) {
        if (shouldRevert) revert();
        IERC20(d.token0).transferFrom(msg.sender, address(this), used0);
        IERC20(d.token1).transferFrom(msg.sender, address(this), used1);
        return (used0, used1);
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
        MockFactory internal fixtureFactory;

        function _fixture(bool quote0) internal returns (LPManager, MockERC20, MockERC20, MockActor) {
            MockAuthority a = new MockAuthority();
            MockRegistry r = new MockRegistry();
            MockFactory f = new MockFactory();
            fixtureFactory = f;
            MockERC20 token = new MockERC20("T");
            MockERC20 quote = new MockERC20("Q");
            address t0 = quote0 ? address(quote) : address(token);
            address t1 = quote0 ? address(token) : address(quote);
            MockPool p = new MockPool(t0, t1, address(f), 3000, 60);
            f.setPool(address(p));
            r.setInfo(
                ITokenRegistry.TokenInfo(address(p), address(p), address(quote), ITokenRegistry.DexType.UniswapV3, 3000)
            );
            IProtocolManager.QuoteConfig memory c;
            c.active = true;
            c.v3FeeTier = 3000;
            a.setConfig(address(quote), c);
            a.setReceiver(address(0xBEEF));
            LPManager m = LPManager(
                address(
                    new ERC1967Proxy(
                        address(new LPManager()), abi.encodeCall(LPManager.initialize, (address(a), address(r)))
                    )
                )
            );
            MockActor actor = new MockActor(address(m), address(f));
            a.set(address(this), address(m), m.setV3LiquidityActor.selector, true);
            m.setV3LiquidityActor(address(actor), address(f));
            a.set(address(this), address(m), m.allocate.selector, true);
            a.set(address(this), address(m), m.increaseLiquidity.selector, true);
            token.mint(address(m), 1000);
            quote.mint(address(m), 1000);
            return (m, token, quote, actor);
        }

        function test_allocate_and_increase_harness() public {
            (LPManager m, MockERC20 token, MockERC20 quote, MockActor actor) = _fixture(true);
            actor.setUsage(70, 50, false);
            ILPManager.AllocateParams memory p = ILPManager.AllocateParams(address(token), 100, 200, 1000, 2000, 1);
            m.allocate(p);
            assertEq(token.allowance(address(m), address(actor)), 0);
            assertEq(quote.allowance(address(m), address(actor)), 0);
            assertEq(token.balanceOf(address(0xBEEF)), 150);
            assertEq(quote.balanceOf(address(0xBEEF)), 30);
            assertEq(token.balanceOf(address(m)), 800);
            assertEq(quote.balanceOf(address(m)), 900);
            actor.setUsage(10, 5, false);
            m.increaseLiquidity(address(token), 20, 30);
            assertEq(token.balanceOf(address(0xBEEF)), 165);
            assertEq(quote.balanceOf(address(0xBEEF)), 50);
            assertEq(token.balanceOf(address(m)), 780);
            assertEq(quote.balanceOf(address(m)), 870);
            (bytes32 q,,,,,,,) = m.getPositions(address(token));
            assertEq(q, bytes32(uint256(1)));
        }

        function test_allocate_quoteToken1_order_and_duplicate_reverts() public {
            (LPManager m, MockERC20 token, MockERC20 quote, MockActor actor) = _fixture(false);
            actor.setUsage(40, 60, false);
            m.allocate(ILPManager.AllocateParams(address(token), 100, 200, 1000, 2000, 1));
            (bytes32 q,,,,,,,) = m.getPositions(address(token));
            assertEq(q, bytes32(uint256(1)));
            vm.expectRevert();
            m.allocate(ILPManager.AllocateParams(address(token), 100, 200, 1000, 2000, 1));
            assertEq(token.allowance(address(m), address(actor)), 0);
            assertEq(quote.allowance(address(m), address(actor)), 0);
        }

        function test_allocate_and_increase_unauthorized_revert() public {
            (LPManager m, MockERC20 token,,) = _fixture(true);
            address attacker = address(0xA11CE);
            vm.startPrank(attacker);
            vm.expectRevert();
            m.allocate(ILPManager.AllocateParams(address(token), 100, 200, 1000, 2000, 1));
            vm.expectRevert();
            m.increaseLiquidity(address(token), 1, 1);
            vm.stopPrank();
        }

        function test_allocate_rejects_wrong_canonical_pool() public {
            (LPManager m, MockERC20 token,,) = _fixture(true);
            fixtureFactory.setPool(address(0xCAFE));
            vm.expectRevert(LPManager.InvalidPool.selector);
            m.allocate(ILPManager.AllocateParams(address(token), 100, 200, 1000, 2000, 1));
        }

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
