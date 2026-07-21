// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {V3PoolDeployer} from "../../src/core/V3PoolDeployer.sol";
import {IV3PoolDeployer} from "../../src/interfaces/IV3PoolDeployer.sol";
import {TokenRegistry} from "../../src/core/TokenRegistry.sol";
import {ProtocolManager} from "../../src/core/ProtocolManager.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ContractV3MathReference} from "../harness/ContractV3MathReference.sol";

contract NonCanonicalFactory {
    address internal immutable returnedPool;

    constructor() {
        returnedPool = address(this);
    }

    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 60;
    }

    function createPool(address, address, uint24) external view returns (address) {
        return returnedPool;
    }

    function getPool(address, address, uint24) external pure returns (address) {
        return address(0xdead);
    }
}

contract V3PoolDeployerTest is Test {
    uint24 internal constant FEE_TIER = 3_000;
    uint256 internal constant VIRTUAL_RESERVE = 30 ether;
    uint256 internal constant VIRTUAL_TOKEN_RESERVE = 1_000_000_000 ether;
    uint256 internal constant MIN_TOKEN_RESERVE = 200_000_000 ether;

    address internal constant CREATOR = address(0xc0ffee);
    address internal constant REGISTRAR = address(0xbeef);
    address internal constant ATTACKER = address(0xbad);

    ProtocolManager internal protocolManager;
    UniswapV3Factory internal factory;
    V3PoolDeployer internal deployer;
    TokenRegistry internal registry;
    MockERC20 internal quoteToken;
    ContractV3MathReference internal mathReference;

    function setUp() public {
        protocolManager = ProtocolManager(
            address(
                new ERC1967Proxy(
                    address(new ProtocolManager()),
                    abi.encodeCall(ProtocolManager.initialize, (address(this), address(0xfee)))
                )
            )
        );
        quoteToken = new MockERC20("Quote", "QUOTE", 18);
        protocolManager.addQuoteToken(
            address(quoteToken), VIRTUAL_RESERVE, VIRTUAL_TOKEN_RESERVE, MIN_TOKEN_RESERVE, 1 ether, 5 ether, 100, 0, 0
        );
        protocolManager.setV3QuoteConfig(address(quoteToken), FEE_TIER, 5_000);

        factory = new UniswapV3Factory();
        deployer = _deployPoolDeployer(address(factory));
        registry = TokenRegistry(
            address(
                new ERC1967Proxy(
                    address(new TokenRegistry()), abi.encodeCall(TokenRegistry.initialize, (address(protocolManager)))
                )
            )
        );
        mathReference = new ContractV3MathReference();

        protocolManager.setOperatorPermission(CREATOR, address(deployer), V3PoolDeployer.createPool.selector, true);
        protocolManager.setOperatorPermission(REGISTRAR, address(registry), TokenRegistry.registerV3.selector, true);
    }

    function test_createPool_tokenIsToken0_matchesContractV3Price() public {
        address token = _addressBelow(address(quoteToken));

        vm.prank(CREATOR);
        address pool = deployer.createPool(token, address(quoteToken));

        uint256 targetVirtualQuoteAmount = VIRTUAL_RESERVE * VIRTUAL_TOKEN_RESERVE / MIN_TOKEN_RESERVE;
        uint160 expected = mathReference.calculateSqrtPrice(MIN_TOKEN_RESERVE, targetVirtualQuoteAmount);
        (uint160 sqrtPriceX96,,,, uint16 observationCardinalityNext,,) = IUniswapV3Pool(pool).slot0();

        assertEq(IUniswapV3Pool(pool).token0(), token);
        assertEq(sqrtPriceX96, expected);
        assertEq(observationCardinalityNext, 32);
    }

    function test_createPool_quoteIsToken0_matchesContractV3Price() public {
        address token = _addressAbove(address(quoteToken));

        vm.prank(CREATOR);
        address pool = deployer.createPool(token, address(quoteToken));

        uint256 targetVirtualQuoteAmount = VIRTUAL_RESERVE * VIRTUAL_TOKEN_RESERVE / MIN_TOKEN_RESERVE;
        uint160 expected = mathReference.calculateSqrtPrice(targetVirtualQuoteAmount, MIN_TOKEN_RESERVE);
        (uint160 sqrtPriceX96,,,, uint16 observationCardinalityNext,,) = IUniswapV3Pool(pool).slot0();

        assertEq(IUniswapV3Pool(pool).token0(), address(quoteToken));
        assertEq(sqrtPriceX96, expected);
        assertEq(observationCardinalityNext, 32);
    }

    function test_createPool_registersCanonicalPoolAndFeeTier() public {
        address token = _addressBelow(address(quoteToken));

        vm.prank(CREATOR);
        address pool = deployer.createPool(token, address(quoteToken));

        assertEq(factory.getPool(token, address(quoteToken), FEE_TIER), pool);
        assertEq(IUniswapV3Pool(pool).factory(), address(factory));
        assertEq(IUniswapV3Pool(pool).fee(), FEE_TIER);
        assertEq(registry.getPool(token), address(0), "deployer must not mutate TokenRegistry");

        vm.prank(REGISTRAR);
        registry.registerV3(token, pool, address(quoteToken), FEE_TIER);

        ITokenRegistry.TokenInfo memory info = registry.getTokenInfo(token);
        assertEq(info.pair, pool);
        assertEq(info.pool, pool);
        assertEq(info.quoteToken, address(quoteToken));
        assertEq(uint8(info.dexType), uint8(ITokenRegistry.DexType.UniswapV3));
        assertEq(info.feeTier, FEE_TIER);
        assertEq(registry.getPool(token), pool);
        assertEq(registry.getTokenByPool(pool), token);
    }

    function test_createPool_revertsForUnauthorizedCaller() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATTACKER));
        deployer.createPool(_addressBelow(address(quoteToken)), address(quoteToken));
    }

    function test_createPool_revertsForInactiveQuoteConfig() public {
        protocolManager.removeQuoteToken(address(quoteToken));

        vm.prank(CREATOR);
        vm.expectRevert(IV3PoolDeployer.QuoteTokenNotAllowed.selector);
        deployer.createPool(_addressBelow(address(quoteToken)), address(quoteToken));
    }

    function test_createPool_revertsForUnsupportedFeeTier() public {
        protocolManager.setV3QuoteConfig(address(quoteToken), 123, 5_000);

        vm.prank(CREATOR);
        vm.expectRevert(IV3PoolDeployer.InvalidFeeTier.selector);
        deployer.createPool(_addressBelow(address(quoteToken)), address(quoteToken));
    }

    function test_createPool_revertsForZeroFeeTier() public {
        MockERC20 zeroTierQuoteToken = new MockERC20("Zero Tier Quote", "ZERO", 18);
        protocolManager.addQuoteToken(
            address(zeroTierQuoteToken),
            VIRTUAL_RESERVE,
            VIRTUAL_TOKEN_RESERVE,
            MIN_TOKEN_RESERVE,
            1 ether,
            5 ether,
            100,
            0,
            0
        );

        vm.prank(CREATOR);
        vm.expectRevert(IV3PoolDeployer.InvalidFeeTier.selector);
        deployer.createPool(_addressBelow(address(zeroTierQuoteToken)), address(zeroTierQuoteToken));
    }

    function test_createPool_revertsForNonCanonicalFactoryResult() public {
        V3PoolDeployer nonCanonicalDeployer = _deployPoolDeployer(address(new NonCanonicalFactory()));

        vm.expectRevert(IV3PoolDeployer.InvalidPool.selector);
        nonCanonicalDeployer.createPool(_addressBelow(address(quoteToken)), address(quoteToken));
    }

    function test_predictedTokenPoolSquatting_reusesUninitializedCanonicalPool() public {
        address futureToken = _futureAddressBelow(address(quoteToken));
        assertEq(futureToken.code.length, 0, "predicted token must not exist yet");

        vm.prank(ATTACKER);
        address squattedPool = factory.createPool(futureToken, address(quoteToken), FEE_TIER);
        (uint160 sqrtPriceBefore,,,,,,) = IUniswapV3Pool(squattedPool).slot0();
        assertEq(sqrtPriceBefore, 0);

        vm.prank(CREATOR);
        address pool = deployer.createPool(futureToken, address(quoteToken));

        uint256 targetVirtualQuoteAmount = VIRTUAL_RESERVE * VIRTUAL_TOKEN_RESERVE / MIN_TOKEN_RESERVE;
        uint160 expected = mathReference.calculateSqrtPrice(MIN_TOKEN_RESERVE, targetVirtualQuoteAmount);
        (uint160 sqrtPriceX96,,,, uint16 observationCardinalityNext,,) = IUniswapV3Pool(pool).slot0();
        assertEq(pool, squattedPool);
        assertEq(factory.getPool(futureToken, address(quoteToken), FEE_TIER), squattedPool);
        assertEq(sqrtPriceX96, expected);
        assertEq(observationCardinalityNext, 32);
        assertEq(registry.getPool(futureToken), address(0));
        assertFalse(registry.isRegistered(futureToken));
    }

    function test_predictedTokenPoolSquatting_rejectsArbitraryInitializedPoolWithoutMutation() public {
        address futureToken = _futureAddressBelow(address(quoteToken));
        assertEq(futureToken.code.length, 0, "predicted token must not exist yet");

        vm.prank(ATTACKER);
        address squattedPool = factory.createPool(futureToken, address(quoteToken), FEE_TIER);
        vm.prank(ATTACKER);
        IUniswapV3Pool(squattedPool).initialize(uint160(1 << 96));
        uint256 targetVirtualQuoteAmount = VIRTUAL_RESERVE * VIRTUAL_TOKEN_RESERVE / MIN_TOKEN_RESERVE;
        uint160 expected = mathReference.calculateSqrtPrice(MIN_TOKEN_RESERVE, targetVirtualQuoteAmount);
        assertNotEq(uint160(1 << 96), expected, "attacker price must be arbitrary");
        bytes32 slot0Before = _slot0Hash(squattedPool);

        vm.prank(CREATOR);
        vm.expectRevert(IV3PoolDeployer.PoolAlreadyInitialized.selector);
        deployer.createPool(futureToken, address(quoteToken));

        assertEq(_slot0Hash(squattedPool), slot0Before);
        assertEq(factory.getPool(futureToken, address(quoteToken), FEE_TIER), squattedPool);
        assertEq(registry.getPool(futureToken), address(0));
        assertFalse(registry.isRegistered(futureToken));
    }

    function test_predictedTokenPoolSquatting_rejectsExpectedPriceInitializedPoolWithoutMutation() public {
        address futureToken = _futureAddressBelow(address(quoteToken));
        assertEq(futureToken.code.length, 0, "predicted token must not exist yet");
        uint256 targetVirtualQuoteAmount = VIRTUAL_RESERVE * VIRTUAL_TOKEN_RESERVE / MIN_TOKEN_RESERVE;
        uint160 expected = mathReference.calculateSqrtPrice(MIN_TOKEN_RESERVE, targetVirtualQuoteAmount);

        vm.prank(ATTACKER);
        address squattedPool = factory.createPool(futureToken, address(quoteToken), FEE_TIER);
        vm.prank(ATTACKER);
        IUniswapV3Pool(squattedPool).initialize(expected);
        bytes32 slot0Before = _slot0Hash(squattedPool);

        vm.prank(CREATOR);
        vm.expectRevert(IV3PoolDeployer.PoolAlreadyInitialized.selector);
        deployer.createPool(futureToken, address(quoteToken));

        assertEq(_slot0Hash(squattedPool), slot0Before);
        assertEq(factory.getPool(futureToken, address(quoteToken), FEE_TIER), squattedPool);
        assertEq(registry.getPool(futureToken), address(0));
        assertFalse(registry.isRegistered(futureToken));
    }

    function test_initializer_rejectsZeroOrCodeLessFactory() public {
        V3PoolDeployer implementation = new V3PoolDeployer();

        vm.expectRevert(IV3PoolDeployer.InvalidFactory.selector);
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(V3PoolDeployer.initialize, (address(protocolManager), address(0)))
        );

        vm.expectRevert(IV3PoolDeployer.InvalidFactory.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(V3PoolDeployer.initialize, (address(protocolManager), address(0x1234)))
        );
    }

    function test_initializer_rejectsZeroOrCodeLessAuthority() public {
        V3PoolDeployer implementation = new V3PoolDeployer();

        vm.expectRevert(IV3PoolDeployer.InvalidAuthority.selector);
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(V3PoolDeployer.initialize, (address(0), address(factory)))
        );

        vm.expectRevert(IV3PoolDeployer.InvalidAuthority.selector);
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(V3PoolDeployer.initialize, (address(0x1234), address(factory)))
        );
    }

    function test_implementationInitializersAreDisabled() public {
        V3PoolDeployer implementation = new V3PoolDeployer();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(protocolManager), address(factory));
    }

    function test_initializerStoresFactoryAndAuthorityInProxyStorage() public view {
        assertEq(deployer.factory(), address(factory));
        assertEq(deployer.authority(), address(protocolManager));
    }

    function test_setAuthorityRemainsLocked() public {
        vm.prank(address(protocolManager));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(protocolManager))
        );
        deployer.setAuthority(address(factory));
    }

    function test_upgrade_revertsForUnauthorizedCaller() public {
        V3PoolDeployer newImplementation = new V3PoolDeployer();

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATTACKER));
        deployer.upgradeToAndCall(address(newImplementation), bytes(""));
    }

    function test_upgrade_succeedsForAuthorityOwnerAndPreservesStorage() public {
        V3PoolDeployer newImplementation = new V3PoolDeployer();

        deployer.upgradeToAndCall(address(newImplementation), bytes(""));

        assertEq(deployer.factory(), address(factory));
        assertEq(deployer.authority(), address(protocolManager));
    }

    function test_registerV3_revertsForUnauthorizedCaller() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATTACKER));
        registry.registerV3(address(0x1000), address(factory), address(quoteToken), FEE_TIER);
    }

    function test_registerV3_revertsForZeroInputs() public {
        vm.startPrank(REGISTRAR);
        vm.expectRevert(TokenRegistry.ZeroAddress.selector);
        registry.registerV3(address(0), address(factory), address(quoteToken), FEE_TIER);
        vm.expectRevert(TokenRegistry.ZeroAddress.selector);
        registry.registerV3(address(0x1000), address(0), address(quoteToken), FEE_TIER);
        vm.expectRevert(TokenRegistry.ZeroAddress.selector);
        registry.registerV3(address(0x1000), address(factory), address(0), FEE_TIER);
        vm.stopPrank();
    }

    function test_registerV3_revertsForCodeLessPool() public {
        vm.prank(REGISTRAR);
        vm.expectRevert(TokenRegistry.InvalidPool.selector);
        registry.registerV3(address(0x1000), address(0x2000), address(quoteToken), FEE_TIER);
    }

    function test_registerV3_revertsWhenTokenAlreadyMapped() public {
        address token = _addressBelow(address(quoteToken));
        vm.prank(CREATOR);
        address pool = deployer.createPool(token, address(quoteToken));

        vm.startPrank(REGISTRAR);
        registry.registerV3(token, pool, address(quoteToken), FEE_TIER);
        vm.expectRevert(TokenRegistry.AlreadyRegistered.selector);
        registry.registerV3(token, address(factory), address(quoteToken), FEE_TIER);
        vm.stopPrank();
    }

    function test_register_revertsWhenPoolAlreadyMapped() public {
        address firstToken = _addressBelow(address(quoteToken));
        address secondToken = address(uint160(firstToken) - 1);
        vm.etch(secondToken, hex"00");
        vm.prank(CREATOR);
        address pool = deployer.createPool(firstToken, address(quoteToken));

        vm.startPrank(REGISTRAR);
        registry.registerV3(firstToken, pool, address(quoteToken), FEE_TIER);
        vm.expectRevert(TokenRegistry.PoolAlreadyRegistered.selector);
        registry.registerV3(secondToken, pool, address(quoteToken), FEE_TIER);
        vm.stopPrank();

        assertEq(registry.getTokenByPool(pool), firstToken);
        assertFalse(registry.isRegistered(secondToken));
    }

    function _deployPoolDeployer(address factory_) internal returns (V3PoolDeployer instance) {
        instance = V3PoolDeployer(
            address(
                new ERC1967Proxy(
                    address(new V3PoolDeployer()),
                    abi.encodeCall(V3PoolDeployer.initialize, (address(protocolManager), factory_))
                )
            )
        );
    }

    function _addressBelow(address other) internal returns (address result) {
        result = address(uint160(other) - 1);
        vm.etch(result, hex"00");
    }

    function _addressAbove(address other) internal returns (address result) {
        result = address(uint160(other) + 1);
        vm.etch(result, hex"00");
    }

    function _futureAddressBelow(address other) internal pure returns (address) {
        return address(uint160(other) - 1);
    }

    function _slot0Hash(address pool) internal view returns (bytes32) {
        (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        ) = IUniswapV3Pool(pool).slot0();
        return keccak256(
            abi.encode(
                sqrtPriceX96,
                tick,
                observationIndex,
                observationCardinality,
                observationCardinalityNext,
                feeProtocol,
                unlocked
            )
        );
    }
}
