// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {V3SwapAdapter} from "../../src/adapters/V3SwapAdapter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IV3SwapAdapter} from "../../src/interfaces/IV3SwapAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IUniswapV3SwapCallbackTarget {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract MutableTokenRegistry {
    mapping(address token => ITokenRegistry.TokenInfo info) private _tokenInfo;
    mapping(address pool => address token) private _tokensByPool;

    function setToken(address token, address pool, address quoteToken, uint24 feeTier) external {
        _tokenInfo[token] = ITokenRegistry.TokenInfo({
            pair: pool, pool: pool, quoteToken: quoteToken, dexType: ITokenRegistry.DexType.UniswapV3, feeTier: feeTier
        });
        _tokensByPool[pool] = token;
    }

    function setTokenByPool(address pool, address token) external {
        _tokensByPool[pool] = token;
    }

    function getTokenInfo(address token) external view returns (ITokenRegistry.TokenInfo memory) {
        return _tokenInfo[token];
    }

    function getTokenByPool(address pool) external view returns (address) {
        return _tokensByPool[pool];
    }
}

contract MutableV3Factory {
    mapping(bytes32 key => address pool) private _pools;

    function setPool(address tokenA, address tokenB, uint24 feeTier, address pool) external {
        _pools[_key(tokenA, tokenB, feeTier)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 feeTier) external view returns (address) {
        return _pools[_key(tokenA, tokenB, feeTier)];
    }

    function _key(address tokenA, address tokenB, uint24 feeTier) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, feeTier));
    }
}

contract MaliciousSwapPool {
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;

    enum Attack {
        None,
        ForgedData,
        WrongCanonicalPool,
        WrongReverseRegistry,
        WrongTokenOrder,
        WrongFeeTier,
        WrongFactory,
        TwoPositiveDeltas,
        ExcessiveInput,
        Replay,
        WrongCaller,
        NoCallback,
        Reenter
    }

    address public factory;
    address public token0;
    address public token1;
    uint24 public fee;

    MutableTokenRegistry public immutable registry;
    address public immutable launchToken;
    Attack public attack;
    MaliciousSwapPool public alternatePool;
    bytes4 public observedReentryError;

    constructor(
        address factoryAddress,
        address token0_,
        address token1_,
        uint24 fee_,
        MutableTokenRegistry registry_,
        address launchToken_
    ) {
        factory = factoryAddress;
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        registry = registry_;
        launchToken = launchToken_;
    }

    function setAttack(Attack attack_, MaliciousSwapPool alternatePool_) external {
        attack = attack_;
        alternatePool = alternatePool_;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 amountInMax = amountSpecified > 0 ? amountSpecified.toUint256() : 1;
        bytes memory callbackData = data;

        if (attack == Attack.ForgedData) {
            callbackData = abi.encode(address(0xdead));
        } else if (attack == Attack.WrongCanonicalPool) {
            MutableV3Factory(factory).setPool(token0, token1, fee, address(0xdead));
        } else if (attack == Attack.WrongReverseRegistry) {
            registry.setTokenByPool(address(this), address(0xdead));
        } else if (attack == Attack.WrongTokenOrder) {
            (token0, token1) = (token1, token0);
        } else if (attack == Attack.WrongFeeTier) {
            ++fee;
        } else if (attack == Attack.WrongFactory) {
            factory = address(0xdead);
        }

        amount0 = zeroForOne ? amountInMax.toInt256() : -int256(1);
        amount1 = zeroForOne ? -int256(1) : amountInMax.toInt256();
        if (attack == Attack.TwoPositiveDeltas) {
            amount0 = 1;
            amount1 = 1;
        } else if (attack == Attack.ExcessiveInput) {
            amount0 = zeroForOne ? (amountInMax + 1).toInt256() : -int256(1);
            amount1 = zeroForOne ? -int256(1) : (amountInMax + 1).toInt256();
        }

        if (attack == Attack.NoCallback) return (amount0, amount1);
        if (attack == Attack.WrongCaller) {
            alternatePool.invokeCallback(msg.sender, amount0, amount1, callbackData);
        } else {
            IUniswapV3SwapCallbackTarget(msg.sender).uniswapV3SwapCallback(amount0, amount1, callbackData);
        }
        if (attack == Attack.Replay) {
            IUniswapV3SwapCallbackTarget(msg.sender).uniswapV3SwapCallback(amount0, amount1, callbackData);
        } else if (attack == Attack.Reenter) {
            try IV3SwapAdapter(msg.sender)
                .exactInput(
                    IV3SwapAdapter.ExactInputParams({
                        token: launchToken,
                        tokenIn: token0,
                        amountIn: 1,
                        amountOutMin: 1,
                        recipient: recipient,
                        sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1,
                        deadline: block.timestamp
                    })
                ) {}
            catch (bytes memory reason) {
                if (reason.length >= 4) {
                    bytes4 selector;
                    assembly {
                        selector := mload(add(reason, 0x20))
                    }
                    observedReentryError = selector;
                }
            }
            IERC20(zeroForOne ? token1 : token0).safeTransfer(recipient, 1);
        }
    }

    function invokeCallback(address target, int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        IUniswapV3SwapCallbackTarget(target).uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }
}

contract ToggleFeeOnTransferToken is ERC20 {
    bool public feeEnabled;

    constructor() ERC20("Taxed Quote", "TAX") {}

    function setFeeEnabled(bool enabled) external {
        feeEnabled = enabled;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (feeEnabled && from != address(0) && to != address(0)) {
            uint256 transferFee = amount / 100;
            super._update(from, to, amount - transferFee);
            super._update(from, address(0xdead), transferFee);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract ToggleTransferSurchargeToken is ERC20 {
    bool public surchargeEnabled;

    constructor() ERC20("Surcharge Quote", "SUR") {}

    function setSurchargeEnabled(bool enabled) external {
        surchargeEnabled = enabled;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!surchargeEnabled) return super.transferFrom(from, to, amount);

        _spendAllowance(from, _msgSender(), amount);
        _update(from, to, amount);
        _update(from, address(0xdead), amount / 100);
        return true;
    }
}

contract ToggleOutputRebaseToken is ERC20 {
    address public rebasePool;
    bool public rebaseEnabled;

    constructor() ERC20("Rebasing Launch", "RBL") {}

    function configureRebase(address pool, bool enabled) external {
        rebasePool = pool;
        rebaseEnabled = enabled;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (rebaseEnabled && from == rebasePool && to != address(0)) {
            super._update(address(0), to, amount / 100);
        }
    }
}

contract V3SwapAdapterTest is Test {
    using SafeERC20 for IERC20;

    struct Fixture {
        address launchToken;
        address quoteToken;
        address pool;
        uint24 feeTier;
    }

    struct SwapStateSnapshot {
        uint256 payerInput;
        uint256 recipientOutput;
        uint256 poolInput;
        uint256 poolOutput;
        uint256 payerAllowance;
        uint256 inputTotalSupply;
        uint256 outputTotalSupply;
        uint256 inputSurchargeSink;
        bytes32 poolState;
    }

    uint24 internal constant LOW_FEE_TIER = 500;
    uint24 internal constant HIGH_FEE_TIER = 3_000;
    uint128 internal constant LIQUIDITY = 1_000_000 ether;
    uint256 internal constant TOKEN_BALANCE = 1_000_000_000 ether;
    address internal constant RECIPIENT = address(0xcafe);

    UniswapV3Factory internal factory;
    MutableTokenRegistry internal registry;
    V3SwapAdapter internal adapter;
    Fixture internal launchBelowQuote;
    Fixture internal launchAboveQuote;
    address private _mintPool;

    function setUp() public {
        factory = new UniswapV3Factory();
        registry = new MutableTokenRegistry();
        adapter = new V3SwapAdapter(address(factory), address(registry));
        launchBelowQuote = _createFixture(true, LOW_FEE_TIER);
        launchAboveQuote = _createFixture(false, HIGH_FEE_TIER);
    }

    function test_exactInput_quoteForLaunch_launchBelowQuote() public {
        _assertExactInput(launchBelowQuote, launchBelowQuote.quoteToken);
    }

    function test_exactInput_launchForQuote_launchBelowQuote() public {
        _assertExactInput(launchBelowQuote, launchBelowQuote.launchToken);
    }

    function test_exactInput_quoteForLaunch_launchAboveQuote() public {
        _assertExactInput(launchAboveQuote, launchAboveQuote.quoteToken);
    }

    function test_exactInput_launchForQuote_launchAboveQuote() public {
        _assertExactInput(launchAboveQuote, launchAboveQuote.launchToken);
    }

    function test_exactInput_priceLimitPartialFill_launchBelowQuote() public {
        _assertPriceLimitPartialFill(launchBelowQuote);
    }

    function test_exactInput_priceLimitPartialFill_launchAboveQuote() public {
        _assertPriceLimitPartialFill(launchAboveQuote);
    }

    function test_exactOutput_quoteForLaunch_launchBelowQuote() public {
        _assertExactOutput(launchBelowQuote, launchBelowQuote.quoteToken);
    }

    function test_exactOutput_launchForQuote_launchBelowQuote() public {
        _assertExactOutput(launchBelowQuote, launchBelowQuote.launchToken);
    }

    function test_exactOutput_quoteForLaunch_launchAboveQuote() public {
        _assertExactOutput(launchAboveQuote, launchAboveQuote.quoteToken);
    }

    function test_exactOutput_launchForQuote_launchAboveQuote() public {
        _assertExactOutput(launchAboveQuote, launchAboveQuote.launchToken);
    }

    function test_callback_revertsWithoutActiveSwap() public {
        vm.expectRevert(IV3SwapAdapter.NoActiveSwap.selector);
        adapter.uniswapV3SwapCallback(1, -1, bytes("forged"));
    }

    function test_callback_revertsFromWrongPool() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool, MaliciousSwapPool alternate,, address tokenIn) =
            _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.WrongCaller, alternate);
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.InvalidCallback.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_callback_revertsForForgedData() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.ForgedData, MaliciousSwapPool(address(0)));
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.InvalidCallback.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_callback_revertsForWrongCanonicalPool() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.WrongCanonicalPool, MaliciousSwapPool(address(0)));
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.InvalidCallback.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_callback_revertsForWrongReverseRegistry() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.WrongReverseRegistry, MaliciousSwapPool(address(0)));
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.InvalidCallback.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_callback_revertsForWrongTokenOrder() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.WrongTokenOrder, MaliciousSwapPool(address(0)));
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.InvalidCallback.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_callback_revertsForWrongFeeTier() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.WrongFeeTier, MaliciousSwapPool(address(0)));
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.InvalidCallback.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_callback_revertsForWrongFactory() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.WrongFactory, MaliciousSwapPool(address(0)));
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.InvalidCallback.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_callback_revertsForTwoPositiveDeltas() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.TwoPositiveDeltas, MaliciousSwapPool(address(0)));
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.InvalidCallback.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_callback_revertsAboveMaximumInput() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.ExcessiveInput, MaliciousSwapPool(address(0)));
        address launchToken = pool.launchToken();

        vm.expectPartialRevert(IV3SwapAdapter.ExcessiveCallbackAmount.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_callback_contextCannotBeReenteredOrReplayed() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.Reenter, MaliciousSwapPool(address(0)));
        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        address launchToken = pool.launchToken();

        (uint256 amountIn, uint256 amountOut) = maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));

        assertEq(pool.observedReentryError(), IV3SwapAdapter.ReentrantCall.selector);
        assertEq(balanceBefore - IERC20(tokenIn).balanceOf(address(this)), amountIn);
        assertEq(amountOut, 1);
        vm.expectRevert(IV3SwapAdapter.NoActiveSwap.selector);
        pool.invokeCallback(address(maliciousAdapter), 1, -1, bytes("replay"));
    }

    function test_callback_authenticReplayDuringSwapRevertsAndRollsBackPayment() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.Replay, MaliciousSwapPool(address(0)));
        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.NoActiveSwap.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));

        assertEq(IERC20(tokenIn).balanceOf(address(this)), balanceBefore);
    }

    function test_exactInput_revertsWhenCallbackIsNotConsumed() public {
        (V3SwapAdapter maliciousAdapter, MaliciousSwapPool pool,,, address tokenIn) = _maliciousFixture();
        pool.setAttack(MaliciousSwapPool.Attack.NoCallback, MaliciousSwapPool(address(0)));
        address launchToken = pool.launchToken();

        vm.expectRevert(IV3SwapAdapter.CallbackNotConsumed.selector);
        maliciousAdapter.exactInput(_exactInputParams(launchToken, tokenIn));
    }

    function test_exactInput_revertsForFeeOnTransferInput() public {
        ToggleFeeOnTransferToken taxedQuote = new ToggleFeeOnTransferToken();
        MockERC20 launch = new MockERC20("Tax Fixture Launch", "TFL", 18);
        Fixture memory fixture = _createFixture(address(launch), address(taxedQuote), LOW_FEE_TIER);
        taxedQuote.setFeeEnabled(true);

        taxedQuote.approve(address(adapter), 10 ether);
        vm.expectRevert();
        adapter.exactInput(_params(fixture, address(taxedQuote), 10 ether));
    }

    function test_exactInput_revertsForInputTransferSurchargeAndRollsBack() public {
        ToggleTransferSurchargeToken surchargeQuote = new ToggleTransferSurchargeToken();
        MockERC20 launch = new MockERC20("Surcharge Fixture Launch", "SFL", 18);
        Fixture memory fixture = _createFixture(address(launch), address(surchargeQuote), LOW_FEE_TIER);
        surchargeQuote.setSurchargeEnabled(true);
        IV3SwapAdapter.ExactInputParams memory params = _params(fixture, address(surchargeQuote), 10 ether);
        surchargeQuote.approve(address(adapter), params.amountIn);
        SwapStateSnapshot memory snapshot = _swapStateSnapshot(fixture, address(surchargeQuote));

        vm.expectPartialRevert(IV3SwapAdapter.InvalidBalanceDelta.selector);
        adapter.exactInput(params);

        _assertSwapStateUnchanged(fixture, address(surchargeQuote), snapshot);
    }

    function test_exactInput_revertsForOutputRebaseAndRollsBack() public {
        ToggleOutputRebaseToken rebasingLaunch = new ToggleOutputRebaseToken();
        MockERC20 quote = new MockERC20("Rebase Fixture Quote", "RFQ", 18);
        Fixture memory fixture = _createFixture(address(rebasingLaunch), address(quote), LOW_FEE_TIER);
        rebasingLaunch.configureRebase(fixture.pool, true);
        IV3SwapAdapter.ExactInputParams memory params = _params(fixture, address(quote), 10 ether);
        quote.approve(address(adapter), params.amountIn);
        SwapStateSnapshot memory snapshot = _swapStateSnapshot(fixture, address(quote));

        vm.expectPartialRevert(IV3SwapAdapter.InvalidBalanceDelta.selector);
        adapter.exactInput(params);

        _assertSwapStateUnchanged(fixture, address(quote), snapshot);
    }

    function test_exactInput_doesNotConsumeDonatedAdapterBalance() public {
        uint256 donation = 7 ether;
        IMintableERC20(launchBelowQuote.quoteToken).mint(address(adapter), donation);
        uint256 adapterBalanceBefore = IERC20(launchBelowQuote.quoteToken).balanceOf(address(adapter));

        _assertExactInput(launchBelowQuote, launchBelowQuote.quoteToken);

        assertEq(IERC20(launchBelowQuote.quoteToken).balanceOf(address(adapter)), adapterBalanceBefore);
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        assertEq(msg.sender, _mintPool);
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        if (amount0Owed != 0) IERC20(pool.token0()).safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed != 0) IERC20(pool.token1()).safeTransfer(msg.sender, amount1Owed);
    }

    function _assertExactInput(Fixture memory fixture, address tokenIn) private {
        address tokenOut = tokenIn == fixture.launchToken ? fixture.quoteToken : fixture.launchToken;
        IV3SwapAdapter.ExactInputParams memory params = _params(fixture, tokenIn, 10 ether);
        uint256 payerBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 recipientBalanceBefore = IERC20(tokenOut).balanceOf(RECIPIENT);
        IERC20(tokenIn).approve(address(adapter), params.amountIn);

        (uint256 amountIn, uint256 amountOut) = adapter.exactInput(params);

        assertEq(payerBalanceBefore - IERC20(tokenIn).balanceOf(address(this)), amountIn);
        assertEq(IERC20(tokenOut).balanceOf(RECIPIENT) - recipientBalanceBefore, amountOut);
        assertGt(amountOut, 0);
        assertLe(amountIn, params.amountIn);
    }

    function _assertPriceLimitPartialFill(Fixture memory fixture) private {
        address tokenIn = fixture.quoteToken;
        address tokenOut = fixture.launchToken;
        IV3SwapAdapter.ExactInputParams memory params = _params(fixture, tokenIn, 10 ether);
        params.sqrtPriceLimitX96 = _nearbyPriceLimit(tokenIn, tokenOut);
        uint256 payerBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 recipientBalanceBefore = IERC20(tokenOut).balanceOf(RECIPIENT);
        IERC20(tokenIn).approve(address(adapter), params.amountIn);

        (uint256 amountIn, uint256 amountOut) = adapter.exactInput(params);

        assertGt(amountIn, 0);
        assertLt(amountIn, params.amountIn);
        assertGt(amountOut, 0);
        assertEq(payerBalanceBefore - IERC20(tokenIn).balanceOf(address(this)), amountIn);
        assertEq(IERC20(tokenOut).balanceOf(RECIPIENT) - recipientBalanceBefore, amountOut);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(fixture.pool).slot0();
        assertEq(sqrtPriceX96, params.sqrtPriceLimitX96);
    }

    function _assertExactOutput(Fixture memory fixture, address tokenIn) private {
        address tokenOut = tokenIn == fixture.launchToken ? fixture.quoteToken : fixture.launchToken;
        IV3SwapAdapter.ExactOutputParams memory params = IV3SwapAdapter.ExactOutputParams({
            token: fixture.launchToken,
            tokenIn: tokenIn,
            amountOut: 1 ether,
            amountInMax: 2 ether,
            recipient: RECIPIENT,
            sqrtPriceLimitX96: _priceLimit(tokenIn, tokenOut),
            deadline: block.timestamp
        });
        uint256 payerBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 recipientBalanceBefore = IERC20(tokenOut).balanceOf(RECIPIENT);
        IERC20(tokenIn).approve(address(adapter), params.amountInMax);

        (uint256 amountIn, uint256 amountOut) = adapter.exactOutput(params);

        assertEq(amountOut, params.amountOut);
        assertLe(amountIn, params.amountInMax);
        assertEq(payerBalanceBefore - IERC20(tokenIn).balanceOf(address(this)), amountIn);
        assertEq(IERC20(tokenOut).balanceOf(RECIPIENT) - recipientBalanceBefore, amountOut);
    }

    function _params(Fixture memory fixture, address tokenIn, uint256 amountIn)
        private
        view
        returns (IV3SwapAdapter.ExactInputParams memory)
    {
        address tokenOut = tokenIn == fixture.launchToken ? fixture.quoteToken : fixture.launchToken;
        return IV3SwapAdapter.ExactInputParams({
            token: fixture.launchToken,
            tokenIn: tokenIn,
            amountIn: amountIn,
            amountOutMin: 1,
            recipient: RECIPIENT,
            sqrtPriceLimitX96: _priceLimit(tokenIn, tokenOut),
            deadline: block.timestamp
        });
    }

    function _exactInputParams(address launchToken, address tokenIn)
        private
        view
        returns (IV3SwapAdapter.ExactInputParams memory)
    {
        address tokenOut = launchToken == tokenIn ? address(0x1234) : launchToken;
        return IV3SwapAdapter.ExactInputParams({
            token: launchToken,
            tokenIn: tokenIn,
            amountIn: 10 ether,
            amountOutMin: 1,
            recipient: RECIPIENT,
            sqrtPriceLimitX96: _priceLimit(tokenIn, tokenOut),
            deadline: block.timestamp
        });
    }

    function _createFixture(bool launchIsBelowQuote, uint24 feeTier) private returns (Fixture memory fixture) {
        MockERC20 first = new MockERC20("Fixture A", "A", 18);
        MockERC20 second = new MockERC20("Fixture B", "B", 18);
        (address lower, address higher) =
            address(first) < address(second) ? (address(first), address(second)) : (address(second), address(first));
        fixture = launchIsBelowQuote ? _createFixture(lower, higher, feeTier) : _createFixture(higher, lower, feeTier);
    }

    function _createFixture(address launchToken, address quoteToken, uint24 feeTier)
        private
        returns (Fixture memory fixture)
    {
        address pool = factory.createPool(launchToken, quoteToken, feeTier);
        IUniswapV3Pool(pool).initialize(uint160(1 << 96));
        IMintableERC20(launchToken).mint(address(this), TOKEN_BALANCE);
        IMintableERC20(quoteToken).mint(address(this), TOKEN_BALANCE);
        _mintPool = pool;
        IUniswapV3Pool(pool).mint(address(this), -600, 600, LIQUIDITY, bytes(""));
        _mintPool = address(0);
        registry.setToken(launchToken, pool, quoteToken, feeTier);
        fixture = Fixture({launchToken: launchToken, quoteToken: quoteToken, pool: pool, feeTier: feeTier});
    }

    function _maliciousFixture()
        private
        returns (
            V3SwapAdapter maliciousAdapter,
            MaliciousSwapPool pool,
            MaliciousSwapPool alternate,
            MutableV3Factory maliciousFactory,
            address tokenIn
        )
    {
        MockERC20 first = new MockERC20("Malicious A", "MA", 18);
        MockERC20 second = new MockERC20("Malicious B", "MB", 18);
        (address token0, address token1) =
            address(first) < address(second) ? (address(first), address(second)) : (address(second), address(first));
        address launchToken = token1;
        tokenIn = token0;
        MutableTokenRegistry maliciousRegistry = new MutableTokenRegistry();
        maliciousFactory = new MutableV3Factory();
        pool = new MaliciousSwapPool(
            address(maliciousFactory), token0, token1, LOW_FEE_TIER, maliciousRegistry, launchToken
        );
        alternate = new MaliciousSwapPool(
            address(maliciousFactory), token0, token1, LOW_FEE_TIER, maliciousRegistry, launchToken
        );
        maliciousFactory.setPool(token0, token1, LOW_FEE_TIER, address(pool));
        maliciousRegistry.setToken(launchToken, address(pool), tokenIn, LOW_FEE_TIER);
        maliciousAdapter = new V3SwapAdapter(address(maliciousFactory), address(maliciousRegistry));
        IMintableERC20(tokenIn).mint(address(this), TOKEN_BALANCE);
        IMintableERC20(launchToken).mint(address(pool), 1 ether);
        IERC20(tokenIn).approve(address(maliciousAdapter), type(uint256).max);
    }

    function _swapStateSnapshot(Fixture memory fixture, address tokenIn)
        private
        view
        returns (SwapStateSnapshot memory snapshot)
    {
        address tokenOut = tokenIn == fixture.launchToken ? fixture.quoteToken : fixture.launchToken;
        snapshot = SwapStateSnapshot({
            payerInput: IERC20(tokenIn).balanceOf(address(this)),
            recipientOutput: IERC20(tokenOut).balanceOf(RECIPIENT),
            poolInput: IERC20(tokenIn).balanceOf(fixture.pool),
            poolOutput: IERC20(tokenOut).balanceOf(fixture.pool),
            payerAllowance: IERC20(tokenIn).allowance(address(this), address(adapter)),
            inputTotalSupply: IERC20(tokenIn).totalSupply(),
            outputTotalSupply: IERC20(tokenOut).totalSupply(),
            inputSurchargeSink: IERC20(tokenIn).balanceOf(address(0xdead)),
            poolState: _poolStateHash(fixture.pool)
        });
    }

    function _assertSwapStateUnchanged(Fixture memory fixture, address tokenIn, SwapStateSnapshot memory snapshot)
        private
        view
    {
        address tokenOut = tokenIn == fixture.launchToken ? fixture.quoteToken : fixture.launchToken;
        assertEq(IERC20(tokenIn).balanceOf(address(this)), snapshot.payerInput);
        assertEq(IERC20(tokenOut).balanceOf(RECIPIENT), snapshot.recipientOutput);
        assertEq(IERC20(tokenIn).balanceOf(fixture.pool), snapshot.poolInput);
        assertEq(IERC20(tokenOut).balanceOf(fixture.pool), snapshot.poolOutput);
        assertEq(IERC20(tokenIn).allowance(address(this), address(adapter)), snapshot.payerAllowance);
        assertEq(IERC20(tokenIn).totalSupply(), snapshot.inputTotalSupply);
        assertEq(IERC20(tokenOut).totalSupply(), snapshot.outputTotalSupply);
        assertEq(IERC20(tokenIn).balanceOf(address(0xdead)), snapshot.inputSurchargeSink);
        assertEq(_poolStateHash(fixture.pool), snapshot.poolState);
    }

    function _poolStateHash(address poolAddress) private view returns (bytes32) {
        (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        ) = IUniswapV3Pool(poolAddress).slot0();
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

    function _nearbyPriceLimit(address tokenIn, address tokenOut) private pure returns (uint160) {
        uint160 currentSqrtPriceX96 = uint160(1 << 96);
        uint160 priceDistance = 1e22;
        return tokenIn < tokenOut ? currentSqrtPriceX96 - priceDistance : currentSqrtPriceX96 + priceDistance;
    }

    function _priceLimit(address tokenIn, address tokenOut) private pure returns (uint160) {
        return tokenIn < tokenOut ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
    }
}
