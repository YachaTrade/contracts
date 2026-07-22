// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {LPManager} from "../../src/core/LPManager.sol";
import {CreatorFeeProcessor} from "../../src/core/CreatorFeeProcessor.sol";
import {ICreatorFeeProcessor} from "../../src/interfaces/ICreatorFeeProcessor.sol";
import {ILPManager} from "../../src/interfaces/ILPManager.sol";
import {IProtocolManager} from "../../src/interfaces/IProtocolManager.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IV3LiquidityActor} from "../../src/interfaces/IV3LiquidityActor.sol";
import {IV3SwapAdapter} from "../../src/interfaces/IV3SwapAdapter.sol";
import {IVault} from "../../src/interfaces/IVault.sol";

interface ILPManagerCollectTarget {
    function collect(address[] calldata tokens) external;
}

contract CollectAuthority {
    mapping(bytes32 permission => bool allowed) private _permissions;
    mapping(address quoteToken => IProtocolManager.QuoteConfig config) private _configs;
    address public receiver;

    function setPermission(address caller, address target, bytes4 selector, bool allowed) external {
        _permissions[keccak256(abi.encode(caller, target, selector))] = allowed;
    }

    function setConfig(address quoteToken, uint16 protocolShareBps) external {
        IProtocolManager.QuoteConfig storage config = _configs[quoteToken];
        config.active = true;
        config.v3FeeTier = 3_000;
        config.lpFeeProtocolShareBps = protocolShareBps;
    }

    function setReceiver(address receiver_) external {
        receiver = receiver_;
    }

    function canCall(address caller, address target, bytes4 selector) external view returns (bool, uint32) {
        return (_permissions[keccak256(abi.encode(caller, target, selector))], 0);
    }

    function getConfig(address quoteToken) external view returns (IProtocolManager.QuoteConfig memory) {
        return _configs[quoteToken];
    }

    function feeReceiver() external view returns (address) {
        return receiver;
    }
}

contract CollectToken is ERC20 {
    address public taxedSender;
    uint16 public taxBps;

    constructor(string memory name_) ERC20(name_, name_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureTax(address sender, uint16 bps) external {
        taxedSender = sender;
        taxBps = bps;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == taxedSender && from != address(0) && to != address(0) && taxBps != 0) {
            uint256 tax = amount * taxBps / 10_000;
            super._update(from, to, amount - tax);
            super._update(from, address(0xdead), tax);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract CollectRegistry {
    mapping(address token => ITokenRegistry.TokenInfo info) private _infos;

    function setInfo(address token, ITokenRegistry.TokenInfo calldata info) external {
        _infos[token] = info;
    }

    function getTokenInfo(address token) external view returns (ITokenRegistry.TokenInfo memory) {
        return _infos[token];
    }

    function getPair(address token) external view returns (address) {
        return _infos[token].pair;
    }
}

contract CollectFactory {
    mapping(bytes32 key => address pool) private _pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[keccak256(abi.encode(tokenA, tokenB, fee))] = pool;
        _pools[keccak256(abi.encode(tokenB, tokenA, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[keccak256(abi.encode(tokenA, tokenB, fee))];
    }
}

contract CollectPool {
    address public immutable token0;
    address public immutable token1;
    address public immutable factory;
    uint24 public immutable fee;
    int24 public constant tickSpacing = 60;

    constructor(address token0_, address token1_, address factory_) {
        token0 = token0_;
        token1 = token1_;
        factory = factory_;
        fee = 3_000;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1 << 96), 0, 0, 0, 0, 0, true);
    }
}

contract CollectActor is IV3LiquidityActor {
    struct Collection {
        uint256 actual0;
        uint256 actual1;
        uint256 reported0;
        uint256 reported1;
    }

    address public immutable override owner;
    address public immutable override factory;
    mapping(address pool => Collection collection) private _collections;
    address public reentryToken;
    bytes4 public observedReentryError;

    constructor(address owner_, address factory_) {
        owner = owner_;
        factory = factory_;
    }

    function setCollection(address pool, uint256 actual0, uint256 actual1, uint256 reported0, uint256 reported1)
        external
    {
        _collections[pool] = Collection(actual0, actual1, reported0, reported1);
    }

    function setReentryToken(address token) external {
        reentryToken = token;
    }

    function mint(ILPManager.PoolData calldata, uint256, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function increase(ILPManager.PoolData calldata, uint256, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function collectFees(address pool) external returns (uint256 amount0, uint256 amount1) {
        if (reentryToken != address(0)) {
            address[] memory tokens = new address[](1);
            tokens[0] = reentryToken;
            try ILPManagerCollectTarget(msg.sender).collect(tokens) {}
            catch (bytes memory reason) {
                if (reason.length >= 4) {
                    bytes4 selector;
                    assembly {
                        selector := mload(add(reason, 0x20))
                    }
                    observedReentryError = selector;
                }
            }
        }

        Collection memory collection = _collections[pool];
        CollectPool targetPool = CollectPool(pool);
        if (collection.actual0 != 0) IERC20(targetPool.token0()).transfer(msg.sender, collection.actual0);
        if (collection.actual1 != 0) IERC20(targetPool.token1()).transfer(msg.sender, collection.actual1);
        return (collection.reported0, collection.reported1);
    }

    function quoteLiquidityPositions(address) external pure returns (bytes32, int24, int24, uint128) {
        return (bytes32(uint256(1)), 0, 0, 1);
    }

    function tokenLiquidityPositions(address) external pure returns (bytes32, int24, int24, uint128) {
        return (bytes32(uint256(2)), 0, 0, 1);
    }

    function viewFees(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

    contract CollectSwapAdapter is IV3SwapAdapter {
        struct Result {
            uint256 actualInput;
            uint256 actualOutput;
            uint256 reportedInput;
            uint256 reportedOutput;
            bool configured;
        }

        address public immutable override factory;
        address public immutable override tokenRegistry;
        CollectRegistry private immutable _registry;
        mapping(address token => Result result) private _results;
        ExactInputParams private _lastParams;

        constructor(address factory_, address registry_) {
            factory = factory_;
            tokenRegistry = registry_;
            _registry = CollectRegistry(registry_);
        }

        function setResult(
            address token,
            uint256 actualInput,
            uint256 actualOutput,
            uint256 reportedInput,
            uint256 reportedOutput
        ) external {
            _results[token] = Result(actualInput, actualOutput, reportedInput, reportedOutput, true);
        }

        function lastParams() external view returns (ExactInputParams memory) {
            return _lastParams;
        }

        function exactInput(ExactInputParams calldata params) external returns (uint256 amountIn, uint256 amountOut) {
            _lastParams = params;
            Result memory result = _results[params.token];
            if (!result.configured) {
                result = Result(params.amountIn, params.amountIn * 2, params.amountIn, params.amountIn * 2, true);
            }
            IERC20(params.tokenIn).transferFrom(msg.sender, address(this), result.actualInput);
            address quoteToken = _registry.getTokenInfo(params.token).quoteToken;
            CollectToken(quoteToken).mint(params.recipient, result.actualOutput);
            return (result.reportedInput, result.reportedOutput);
        }

        function exactOutput(ExactOutputParams calldata) external pure returns (uint256, uint256) {
            revert();
        }
    }

        contract CollectVault is IVault {
            bool public shouldRevert;
            uint256 public callbackAmount;

            function setShouldRevert(bool value) external {
                shouldRevert = value;
            }

            function afterDeposit(address, address, uint256 amount) external {
                if (shouldRevert) revert("vault callback failed");
                callbackAmount += amount;
            }

            function setup(address, bytes calldata) external pure {}

            function metadataURI() external pure returns (string memory) {
                return "";
            }

            function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
                return interfaceId == type(IVault).interfaceId;
            }
        }

        contract LPManagerCollectTest is Test {
            event V3FeesCollected(
                address indexed token,
                address indexed quoteToken,
                uint256 tokenFee,
                uint256 directQuoteFee,
                uint256 swappedQuote,
                uint256 protocolQuote,
                uint256 creatorQuote
            );

            uint16 internal constant DEFAULT_PROTOCOL_SHARE = 5_000;
            address internal constant FEE_RECEIVER = address(0xfee);
            address internal constant ATTACKER = address(0xbad);

            CollectAuthority internal authority;
            CollectRegistry internal registry;
            CollectFactory internal factory;
            CollectSwapAdapter internal swapAdapter;
            CreatorFeeProcessor internal creatorFeeProcessor;
            LPManager internal manager;
            CollectActor internal actor;

            CollectToken internal tokenQuote0;
            CollectToken internal quote0;
            CollectPool internal poolQuote0;
            CollectVault internal vaultQuote0;

            CollectToken internal tokenQuote1;
            CollectToken internal quote1;
            CollectPool internal poolQuote1;
            CollectVault internal vaultQuote1;

            function setUp() public {
                authority = new CollectAuthority();
                registry = new CollectRegistry();
                factory = new CollectFactory();
                swapAdapter = new CollectSwapAdapter(address(factory), address(registry));
                creatorFeeProcessor = new CreatorFeeProcessor(address(authority));
                manager = LPManager(
                    address(
                        new ERC1967Proxy(
                            address(new LPManager()),
                            abi.encodeCall(
                                LPManager.initialize,
                                (
                                    address(authority),
                                    address(registry),
                                    address(creatorFeeProcessor),
                                    address(swapAdapter)
                                )
                            )
                        )
                    )
                );
                actor = new CollectActor(address(manager), address(factory));

                authority.setReceiver(FEE_RECEIVER);
                authority.setPermission(address(this), address(manager), manager.setV3LiquidityActor.selector, true);
                authority.setPermission(address(this), address(manager), manager.allocate.selector, true);
                authority.setPermission(address(this), address(manager), ILPManagerCollectTarget.collect.selector, true);
                authority.setPermission(
                    address(this), address(creatorFeeProcessor), creatorFeeProcessor.setup.selector, true
                );
                authority.setPermission(
                    address(manager), address(creatorFeeProcessor), creatorFeeProcessor.processCreatorFee.selector, true
                );
                manager.setV3LiquidityActor(address(actor), address(factory));

                tokenQuote0 = new CollectToken("TOKEN-QUOTE0");
                quote0 = new CollectToken("QUOTE0");
                poolQuote0 = new CollectPool(address(quote0), address(tokenQuote0), address(factory));
                vaultQuote0 = new CollectVault();
                _register(tokenQuote0, quote0, poolQuote0, vaultQuote0, DEFAULT_PROTOCOL_SHARE);

                tokenQuote1 = new CollectToken("TOKEN-QUOTE1");
                quote1 = new CollectToken("QUOTE1");
                poolQuote1 = new CollectPool(address(tokenQuote1), address(quote1), address(factory));
                vaultQuote1 = new CollectVault();
                _register(tokenQuote1, quote1, poolQuote1, vaultQuote1, 2_500);
            }

            function test_collect_revertsForUnauthorizedCaller() public {
                vm.prank(ATTACKER);
                vm.expectRevert();
                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));
            }

            function test_collect_revertsForEmptyBatch() public {
                vm.expectRevert(LPManager.InvalidBatch.selector);
                ILPManagerCollectTarget(address(manager)).collect(new address[](0));
            }

            function test_collect_revertsForDuplicateToken() public {
                address[] memory tokens = new address[](2);
                tokens[0] = address(tokenQuote0);
                tokens[1] = address(tokenQuote0);
                vm.expectRevert(abi.encodeWithSelector(LPManager.DuplicateToken.selector, address(tokenQuote0)));
                ILPManagerCollectTarget(address(manager)).collect(tokens);
            }

            function test_collect_distributesQuoteOnlyFeesAtFiftyFifty() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 0, 100);

                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(quote0.balanceOf(FEE_RECEIVER), 50);
                assertEq(quote0.balanceOf(address(vaultQuote0)), 50);
                assertEq(vaultQuote0.callbackAmount(), 50);
            }

            function test_collect_swapsAndDistributesTokenOnlyFees_quoteIsToken0() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 40, 0);

                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(quote0.balanceOf(FEE_RECEIVER), 40);
                assertEq(quote0.balanceOf(address(vaultQuote0)), 40);
                IV3SwapAdapter.ExactInputParams memory params = swapAdapter.lastParams();
                assertEq(params.token, address(tokenQuote0));
                assertEq(params.tokenIn, address(tokenQuote0));
                assertEq(params.amountIn, 40);
                assertEq(params.amountOutMin, 0);
                assertEq(params.recipient, address(manager));
                assertEq(params.sqrtPriceLimitX96, TickMath.MAX_SQRT_RATIO - 1);
                assertEq(params.deadline, block.timestamp);
            }

            function test_collect_swapsAndDistributesTokenOnlyFees_quoteIsToken1() public {
                _setFees(tokenQuote1, quote1, poolQuote1, 40, 0);

                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote1)));

                assertEq(quote1.balanceOf(FEE_RECEIVER), 20);
                assertEq(quote1.balanceOf(address(vaultQuote1)), 60);
                assertEq(swapAdapter.lastParams().sqrtPriceLimitX96, TickMath.MIN_SQRT_RATIO + 1);
            }

            function test_collect_combinesDirectAndSwappedQuoteBeforeDistribution() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 40, 20);

                vm.expectEmit(true, true, false, true, address(manager));
                emit V3FeesCollected(address(tokenQuote0), address(quote0), 40, 20, 80, 50, 50);
                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(quote0.balanceOf(FEE_RECEIVER), 50);
                assertEq(quote0.balanceOf(address(vaultQuote0)), 50);
            }

            function test_collect_usesCurrentPerQuoteProtocolShare() public {
                authority.setConfig(address(quote1), 8_000);
                _setFees(tokenQuote1, quote1, poolQuote1, 0, 101);

                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote1)));

                assertEq(quote1.balanceOf(FEE_RECEIVER), 80);
                assertEq(quote1.balanceOf(address(vaultQuote1)), 21);
            }

            function test_collect_handlesMultiQuoteBatchIndependently() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 10, 30);
                _setFees(tokenQuote1, quote1, poolQuote1, 20, 10);
                address[] memory tokens = new address[](2);
                tokens[0] = address(tokenQuote0);
                tokens[1] = address(tokenQuote1);

                ILPManagerCollectTarget(address(manager)).collect(tokens);

                assertEq(quote0.balanceOf(FEE_RECEIVER), 25);
                assertEq(quote0.balanceOf(address(vaultQuote0)), 25);
                assertEq(quote1.balanceOf(FEE_RECEIVER), 12);
                assertEq(quote1.balanceOf(address(vaultQuote1)), 38);
            }

            function test_collect_multiTokenFailureRollsBackEarlierToken() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 0, 100);
                _setFees(tokenQuote1, quote1, poolQuote1, 0, 100);
                vaultQuote1.setShouldRevert(true);
                address[] memory tokens = new address[](2);
                tokens[0] = address(tokenQuote0);
                tokens[1] = address(tokenQuote1);

                vm.expectRevert(bytes("vault callback failed"));
                ILPManagerCollectTarget(address(manager)).collect(tokens);

                assertEq(quote0.balanceOf(address(actor)), 100, "first token fees were not rolled back");
                assertEq(quote1.balanceOf(address(actor)), 100, "failing token fees were not rolled back");
                assertEq(quote0.balanceOf(FEE_RECEIVER), 0, "first protocol distribution was not rolled back");
                assertEq(quote1.balanceOf(FEE_RECEIVER), 0, "second protocol distribution escaped rollback");
                assertEq(quote0.balanceOf(address(vaultQuote0)), 0, "first vault distribution was not rolled back");
                assertEq(quote1.balanceOf(address(vaultQuote1)), 0, "failing vault retained quote");
                assertEq(vaultQuote0.callbackAmount(), 0, "first vault callback state was not rolled back");
                assertEq(quote0.allowance(address(manager), address(creatorFeeProcessor)), 0, "first allowance residue");
                assertEq(
                    quote1.allowance(address(manager), address(creatorFeeProcessor)), 0, "second allowance residue"
                );
            }

            function test_collect_revertsWhenLivePoolMetadataDiffersFromAllocation() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 0, 100);
                registry.setInfo(
                    address(tokenQuote0),
                    ITokenRegistry.TokenInfo({
                        pair: address(poolQuote1),
                        pool: address(poolQuote1),
                        quoteToken: address(quote0),
                        dexType: ITokenRegistry.DexType.UniswapV3,
                        feeTier: 3_000
                    })
                );

                vm.expectRevert(LPManager.InvalidPool.selector);
                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(quote0.balanceOf(address(actor)), 100, "metadata failure consumed pending fees");
                assertEq(quote0.balanceOf(FEE_RECEIVER), 0, "metadata failure distributed protocol fees");
                assertEq(quote0.balanceOf(address(vaultQuote0)), 0, "metadata failure distributed creator fees");
            }

            function test_collect_zeroFeesEmitsAndLeavesNoResidue() public {
                vm.expectEmit(true, true, false, true, address(manager));
                emit V3FeesCollected(address(tokenQuote0), address(quote0), 0, 0, 0, 0, 0);

                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(tokenQuote0.balanceOf(address(manager)), 0);
                assertEq(quote0.balanceOf(address(manager)), 0);
                assertEq(tokenQuote0.allowance(address(manager), address(swapAdapter)), 0);
                assertEq(quote0.allowance(address(manager), address(creatorFeeProcessor)), 0);
            }

            function test_collect_preservesPreexistingDonationsAndCleansAllowances() public {
                tokenQuote0.mint(address(manager), 77);
                quote0.mint(address(manager), 91);
                _setFees(tokenQuote0, quote0, poolQuote0, 40, 20);

                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(tokenQuote0.balanceOf(address(manager)), 77);
                assertEq(quote0.balanceOf(address(manager)), 91);
                assertEq(tokenQuote0.allowance(address(manager), address(swapAdapter)), 0);
                assertEq(quote0.allowance(address(manager), address(creatorFeeProcessor)), 0);
                assertEq(quote0.balanceOf(address(creatorFeeProcessor)), 0);
            }

            function test_collect_revertsWhenSwapConsumesPartialInput() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 40, 0);
                swapAdapter.setResult(address(tokenQuote0), 39, 78, 39, 78);

                vm.expectRevert(LPManager.BalanceDelta.selector);
                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(tokenQuote0.balanceOf(address(actor)), 40);
                assertEq(tokenQuote0.allowance(address(manager), address(swapAdapter)), 0);
            }

            function test_collect_revertsForFalseActorBalanceReport() public {
                tokenQuote0.mint(address(actor), 39);
                actor.setCollection(address(poolQuote0), 0, 39, 0, 40);

                vm.expectRevert(LPManager.BalanceDelta.selector);
                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));
            }

            function test_collect_revertsForFalseSwapBalanceReport() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 40, 0);
                swapAdapter.setResult(address(tokenQuote0), 40, 79, 40, 80);

                vm.expectRevert(LPManager.BalanceDelta.selector);
                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));
            }

            function test_collect_revertsAndRollsBackTaxedActorTransfer() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 100, 0);
                tokenQuote0.configureTax(address(actor), 1_000);

                vm.expectRevert(LPManager.BalanceDelta.selector);
                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(tokenQuote0.balanceOf(address(actor)), 100);
                assertEq(tokenQuote0.balanceOf(address(0xdead)), 0);
            }

            function test_collect_revertsAndRollsBackTaxedDistribution() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 0, 100);
                quote0.configureTax(address(manager), 1_000);

                vm.expectRevert(LPManager.BalanceDelta.selector);
                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(quote0.balanceOf(address(actor)), 100);
                assertEq(quote0.balanceOf(FEE_RECEIVER), 0);
                assertEq(quote0.balanceOf(address(0xdead)), 0);
            }

            function test_collect_revertsAndRollsBackVaultCallbackFailure() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 0, 100);
                vaultQuote0.setShouldRevert(true);

                vm.expectRevert(bytes("vault callback failed"));
                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(quote0.balanceOf(address(actor)), 100);
                assertEq(quote0.balanceOf(FEE_RECEIVER), 0);
                assertEq(quote0.balanceOf(address(vaultQuote0)), 0);
                assertEq(quote0.allowance(address(manager), address(creatorFeeProcessor)), 0);
            }

            function test_collect_blocksActorReentrancyAndCompletesOuterCollection() public {
                _setFees(tokenQuote0, quote0, poolQuote0, 0, 100);
                actor.setReentryToken(address(tokenQuote0));
                authority.setPermission(
                    address(actor), address(manager), ILPManagerCollectTarget.collect.selector, true
                );

                ILPManagerCollectTarget(address(manager)).collect(_tokens(address(tokenQuote0)));

                assertEq(actor.observedReentryError(), LPManager.UnauthorizedCaller.selector);
                assertEq(quote0.balanceOf(FEE_RECEIVER), 50);
                assertEq(quote0.balanceOf(address(vaultQuote0)), 50);
            }

            function test_initialize_rejectsAdapterWithDifferentRegistry() public {
                CollectRegistry wrongRegistry = new CollectRegistry();
                CollectSwapAdapter wrongAdapter = new CollectSwapAdapter(address(factory), address(wrongRegistry));
                LPManager implementation = new LPManager();

                vm.expectRevert(LPManager.InvalidConfig.selector);
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        LPManager.initialize,
                        (address(authority), address(registry), address(creatorFeeProcessor), address(wrongAdapter))
                    )
                );
            }

            function test_initialize_rejectsProcessorWithDifferentProtocolManager() public {
                CollectAuthority wrongAuthority = new CollectAuthority();
                CreatorFeeProcessor wrongProcessor = new CreatorFeeProcessor(address(wrongAuthority));
                LPManager implementation = new LPManager();

                vm.expectRevert(LPManager.InvalidConfig.selector);
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        LPManager.initialize,
                        (address(authority), address(registry), address(wrongProcessor), address(swapAdapter))
                    )
                );
            }

            function test_setV3LiquidityActor_rejectsAdapterFactoryMismatch() public {
                CollectFactory wrongFactory = new CollectFactory();
                CollectSwapAdapter wrongAdapter = new CollectSwapAdapter(address(wrongFactory), address(registry));
                LPManager freshManager = LPManager(
                    address(
                        new ERC1967Proxy(
                            address(new LPManager()),
                            abi.encodeCall(
                                LPManager.initialize,
                                (
                                    address(authority),
                                    address(registry),
                                    address(creatorFeeProcessor),
                                    address(wrongAdapter)
                                )
                            )
                        )
                    )
                );
                CollectActor actorWithCanonicalFactory = new CollectActor(address(freshManager), address(factory));
                authority.setPermission(
                    address(this), address(freshManager), freshManager.setV3LiquidityActor.selector, true
                );

                vm.expectRevert(LPManager.InvalidFactory.selector);
                freshManager.setV3LiquidityActor(address(actorWithCanonicalFactory), address(factory));
            }

            function _register(
                CollectToken token,
                CollectToken quote,
                CollectPool pool,
                CollectVault vault,
                uint16 protocolShare
            ) private {
                factory.setPool(address(token), address(quote), 3_000, address(pool));
                registry.setInfo(
                    address(token),
                    ITokenRegistry.TokenInfo({
                        pair: address(pool),
                        pool: address(pool),
                        quoteToken: address(quote),
                        dexType: ITokenRegistry.DexType.UniswapV3,
                        feeTier: 3_000
                    })
                );
                authority.setConfig(address(quote), protocolShare);
                ICreatorFeeProcessor.VaultSlot[] memory slots = new ICreatorFeeProcessor.VaultSlot[](1);
                slots[0] = ICreatorFeeProcessor.VaultSlot(address(vault), 10_000);
                creatorFeeProcessor.setup(address(token), slots);
                manager.allocate(
                    ILPManager.AllocateParams({
                        token: address(token),
                        quoteAmount: 0,
                        tokenAmount: 0,
                        virtualQuoteReserve: 1_000,
                        virtualTokenReserve: 2_000,
                        graduateFee: 1
                    })
                );
            }

            function _setFees(
                CollectToken token,
                CollectToken quote,
                CollectPool pool,
                uint256 tokenFee,
                uint256 quoteFee
            ) private {
                uint256 amount0 = pool.token0() == address(token) ? tokenFee : quoteFee;
                uint256 amount1 = pool.token1() == address(token) ? tokenFee : quoteFee;
                token.mint(address(actor), tokenFee);
                quote.mint(address(actor), quoteFee);
                actor.setCollection(address(pool), amount0, amount1, amount0, amount1);
            }

            function _tokens(address token) private pure returns (address[] memory tokens) {
                tokens = new address[](1);
                tokens[0] = token;
            }
        }
