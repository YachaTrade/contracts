// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {SetUp} from "../SetUp.t.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {IYachaRouter} from "../../src/interfaces/IYachaRouter.sol";
import {IV3LiquidityActor} from "../../src/interfaces/IV3LiquidityActor.sol";
import {IV3SwapAdapter} from "../../src/interfaces/IV3SwapAdapter.sol";
import {YachaRouter} from "../../src/router/YachaRouter.sol";
import {CreatorFeeVault} from "../../src/vault/CreatorFeeVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LPPrincipalLockHandler {
    uint256 private constant MIN_QUOTE_IN = 1e12;
    uint256 private constant QUOTE_RANGE = 0.1 ether;

    YachaRouter private immutable _router;
    LPManager private immutable _lpManager;
    MockERC20 private immutable _quoteToken;
    IERC20 private immutable _launchToken;
    IUniswapV3Pool private immutable _pool;
    IV3LiquidityActor private immutable _liquidityActor;
    address private immutable _swapAdapter;
    address private immutable _creatorFeeProcessor;
    CreatorFeeVault private immutable _creatorFeeVault;
    address private immutable _feeReceiver;

    uint256 public donatedQuote;
    uint256 public collectAttemptCount;
    uint256 public noFeeCollectSkipCount;
    uint256 public successfulCollectionCount;
    uint256 public successfulFeeCollectionCount;
    uint256 public permittedDustRollbackCount;
    uint256 public unknownCollectRevertCount;
    uint256 public maxPermittedDustTokenFee;
    bytes4 public lastUnknownCollectRevertSelector;

    struct PositionSnapshot {
        bytes32 quoteKey;
        int24 quoteLower;
        int24 quoteUpper;
        uint128 quoteLiquidity;
        bytes32 tokenKey;
        int24 tokenLower;
        int24 tokenUpper;
        uint128 tokenLiquidity;
    }

    error AtomicRollbackMismatch();
    error UnexpectedPositionKey(bytes32 suppliedKey, bytes32 recomputedKey);

    constructor(
        YachaRouter router_,
        LPManager lpManager_,
        MockERC20 quoteToken_,
        address launchToken_,
        address pool_,
        IV3LiquidityActor liquidityActor_,
        address swapAdapter_,
        address creatorFeeProcessor_,
        CreatorFeeVault creatorFeeVault_,
        address feeReceiver_
    ) {
        _router = router_;
        _lpManager = lpManager_;
        _quoteToken = quoteToken_;
        _launchToken = IERC20(launchToken_);
        _pool = IUniswapV3Pool(pool_);
        _liquidityActor = liquidityActor_;
        _swapAdapter = swapAdapter_;
        _creatorFeeProcessor = creatorFeeProcessor_;
        _creatorFeeVault = creatorFeeVault_;
        _feeReceiver = feeReceiver_;
    }

    function roundTrip(uint96 rawQuoteIn) external {
        uint256 quoteIn = MIN_QUOTE_IN + uint256(rawQuoteIn) % QUOTE_RANGE;
        _quoteToken.mint(address(this), quoteIn);
        _quoteToken.approve(address(_router), quoteIn);
        uint256 tokenOut = _router.buy(
            IYachaRouter.BuyParams({
                amountIn: quoteIn,
                amountOutMin: 1,
                token: address(_launchToken),
                to: address(this),
                deadline: block.timestamp
            })
        );

        uint256 fullBalance = _launchToken.balanceOf(address(this));
        require(fullBalance == tokenOut, "unexpected launch-token balance");
        _launchToken.approve(address(_router), fullBalance);
        _router.sell(
            IYachaRouter.SellParams({
                amountIn: fullBalance,
                amountOutMin: 1,
                token: address(_launchToken),
                to: address(this),
                deadline: block.timestamp
            })
        );
        require(_launchToken.balanceOf(address(this)) == 0, "full-balance sell left dust");
    }

    function collect() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(_launchToken);
        (uint256 pendingTokenFee, uint256 pendingQuoteFee) = _pendingFees();
        if (pendingTokenFee == 0 && pendingQuoteFee == 0) {
            noFeeCollectSkipCount++;
            return;
        }
        collectAttemptCount++;
        bytes32 rollbackSnapshot = _atomicStateHash();
        uint256 distributedQuoteBefore = _distributedQuoteBalance();
        try _lpManager.collect(tokens) {
            successfulCollectionCount++;
            if (_distributedQuoteBalance() > distributedQuoteBefore) successfulFeeCollectionCount++;
        } catch (bytes memory reason) {
            bytes4 selector = _selector(reason);
            if (selector == IV3SwapAdapter.InvalidAmountOut.selector && pendingTokenFee != 0) {
                if (_atomicStateHash() != rollbackSnapshot) revert AtomicRollbackMismatch();
                permittedDustRollbackCount++;
                if (pendingTokenFee > maxPermittedDustTokenFee) maxPermittedDustTokenFee = pendingTokenFee;
            } else {
                unknownCollectRevertCount++;
                lastUnknownCollectRevertSelector = selector;
            }
        }
    }

    function donateQuote(uint96 rawDonation) external {
        uint256 amount = 1 + uint256(rawDonation) % QUOTE_RANGE;
        donatedQuote += amount;
        _quoteToken.mint(address(_lpManager), amount);
    }

    function _pendingFees() private view returns (uint256 tokenFee, uint256 quoteFee) {
        (uint256 fee0, uint256 fee1) = _liquidityActor.viewFees(address(_pool));
        if (_pool.token0() == address(_launchToken)) {
            return (fee0, fee1);
        }
        return (fee1, fee0);
    }

    function _distributedQuoteBalance() private view returns (uint256) {
        return _quoteToken.balanceOf(_feeReceiver) + _quoteToken.balanceOf(address(_creatorFeeVault));
    }

    function _atomicStateHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _positionStateHash(),
                _balanceStateHash(),
                _allowanceStateHash(),
                donatedQuote,
                _creatorFeeVault.getBalance(address(_launchToken))
            )
        );
    }

    function _positionStateHash() private view returns (bytes32) {
        PositionSnapshot memory p;
        (
            p.quoteKey,
            p.quoteLower,
            p.quoteUpper,
            p.quoteLiquidity,
            p.tokenKey,
            p.tokenLower,
            p.tokenUpper,
            p.tokenLiquidity
        ) = _lpManager.getPositions(address(_launchToken));
        bytes32 recomputedQuoteKey = keccak256(abi.encodePacked(address(_liquidityActor), p.quoteLower, p.quoteUpper));
        bytes32 recomputedTokenKey = keccak256(abi.encodePacked(address(_liquidityActor), p.tokenLower, p.tokenUpper));
        if (p.quoteKey != recomputedQuoteKey) revert UnexpectedPositionKey(p.quoteKey, recomputedQuoteKey);
        if (p.tokenKey != recomputedTokenKey) revert UnexpectedPositionKey(p.tokenKey, recomputedTokenKey);
        return keccak256(
            abi.encode(
                p,
                recomputedQuoteKey,
                _canonicalPositionHash(recomputedQuoteKey),
                recomputedTokenKey,
                _canonicalPositionHash(recomputedTokenKey)
            )
        );
    }

    function _canonicalPositionHash(bytes32 key) private view returns (bytes32) {
        (uint128 liquidity, uint256 growth0, uint256 growth1, uint128 owed0, uint128 owed1) = _pool.positions(key);
        return keccak256(abi.encode(liquidity, growth0, growth1, owed0, owed1));
    }

    function _balanceStateHash() private view returns (bytes32) {
        bytes32 moduleBalances = keccak256(
            abi.encode(
                _launchToken.balanceOf(address(_lpManager)),
                _quoteToken.balanceOf(address(_lpManager)),
                _launchToken.balanceOf(address(_liquidityActor)),
                _quoteToken.balanceOf(address(_liquidityActor)),
                _launchToken.balanceOf(_swapAdapter),
                _quoteToken.balanceOf(_swapAdapter),
                _launchToken.balanceOf(_creatorFeeProcessor),
                _quoteToken.balanceOf(_creatorFeeProcessor)
            )
        );
        bytes32 recipientBalances = keccak256(
            abi.encode(
                _launchToken.balanceOf(address(_creatorFeeVault)),
                _quoteToken.balanceOf(address(_creatorFeeVault)),
                _launchToken.balanceOf(_feeReceiver),
                _quoteToken.balanceOf(_feeReceiver)
            )
        );
        return keccak256(abi.encode(moduleBalances, recipientBalances));
    }

    function _allowanceStateHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _launchToken.allowance(address(_lpManager), address(_liquidityActor)),
                _quoteToken.allowance(address(_lpManager), address(_liquidityActor)),
                _launchToken.allowance(address(_lpManager), _swapAdapter),
                _quoteToken.allowance(address(_lpManager), _swapAdapter),
                _launchToken.allowance(address(_lpManager), _creatorFeeProcessor),
                _quoteToken.allowance(address(_lpManager), _creatorFeeProcessor)
            )
        );
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(reason, 0x20))
        }
    }
}

/// forge-config: default.invariant.depth = 256
/// forge-config: default.invariant.fail_on_revert = true
contract LPPrincipalLockInvariant is StdInvariant, SetUp {
    LPPrincipalLockHandler private handler;
    address private launchToken;
    address private pool;
    bytes32 private principalSnapshot;

    function setUp() public override {
        super.setUp();
        launchToken = _createToken();
        _skipAntiSniping();
        _graduateToken(launchToken);
        pool = tokenRegistry.getPool(launchToken);
        principalSnapshot = _positionHash();

        handler = new LPPrincipalLockHandler(
            yachaRouter,
            lpManager,
            quoteToken,
            launchToken,
            pool,
            v3LiquidityActor,
            address(v3SwapAdapter),
            address(creatorFeeProcessor),
            creatorFeeVault,
            feeReceiver
        );
        vm.prank(admin);
        protocolManager.setOperatorPermission(address(handler), address(lpManager), LPManager.collect.selector, true);
        targetContract(address(handler));
    }

    function invariant_principalSupplyAndDonationsRemainLocked() public view {
        assertEq(_positionHash(), principalSnapshot, "position key, range, or liquidity changed");
        uint256 accounted = IERC20(launchToken).balanceOf(user1) + IERC20(launchToken).balanceOf(address(handler))
            + IERC20(launchToken).balanceOf(feeReceiver) + IERC20(launchToken).balanceOf(creator)
            + IERC20(launchToken).balanceOf(pool) + IERC20(launchToken).balanceOf(address(bondingCurve))
            + IERC20(launchToken).balanceOf(address(lpManager))
            + IERC20(launchToken).balanceOf(address(v3LiquidityActor))
            + IERC20(launchToken).balanceOf(address(yachaRouter))
            + IERC20(launchToken).balanceOf(address(v3SwapAdapter))
            + IERC20(launchToken).balanceOf(address(creatorFeeProcessor))
            + IERC20(launchToken).balanceOf(address(creatorFeeVault));
        assertEq(accounted, IERC20(launchToken).totalSupply(), "launch-token supply escaped known lifecycle actors");
        assertEq(
            quoteToken.balanceOf(address(lpManager)),
            handler.donatedQuote(),
            "collection consumed donated LPManager quote"
        );
        assertEq(handler.unknownCollectRevertCount(), 0, "unknown collect revert observed");
        assertEq(uint32(handler.lastUnknownCollectRevertSelector()), 0, "unknown collect revert selector");
        assertEq(
            handler.collectAttemptCount(),
            handler.successfulCollectionCount() + handler.permittedDustRollbackCount(),
            "collect outcome not classified"
        );
        if (handler.collectAttemptCount() != 0) {
            assertGt(handler.successfulFeeCollectionCount(), 0, "no successful fee-bearing collection exercised");
        }
    }

    function test_collectClassifiesCanonicalDustRollback() public {
        uint256 attemptsBefore = handler.collectAttemptCount();
        uint256 successfulBefore = handler.successfulCollectionCount();
        uint256 feeBearingBefore = handler.successfulFeeCollectionCount();
        uint256 dustBefore = handler.permittedDustRollbackCount();

        handler.roundTrip(3_664);
        for (uint256 i; i < 5; ++i) {
            handler.collect();
        }

        assertEq(handler.collectAttemptCount(), attemptsBefore + 5, "collect attempt counter");
        assertGt(handler.successfulCollectionCount(), successfulBefore, "no collection succeeded before dust");
        assertGt(handler.successfulFeeCollectionCount(), feeBearingBefore, "no fee-bearing collection succeeded");
        assertGt(handler.permittedDustRollbackCount(), dustBefore, "dust rollback not classified");
        assertGt(handler.maxPermittedDustTokenFee(), 0, "dust token fee not recorded");
        assertEq(handler.unknownCollectRevertCount(), 0, "dust rollback classified as unknown");
    }

    function _positionHash() private view returns (bytes32) {
        (
            bytes32 quoteKey,
            int24 quoteLower,
            int24 quoteUpper,
            uint128 quoteLiquidity,
            bytes32 tokenKey,
            int24 tokenLower,
            int24 tokenUpper,
            uint128 tokenLiquidity
        ) = lpManager.getPositions(launchToken);
        assertNotEq(quoteKey, bytes32(0), "missing quote position");
        assertNotEq(tokenKey, bytes32(0), "missing token position");
        assertGt(quoteLiquidity, 0, "zero quote position liquidity");
        assertGt(tokenLiquidity, 0, "zero token position liquidity");
        bytes32 recomputedQuoteKey = keccak256(abi.encodePacked(address(v3LiquidityActor), quoteLower, quoteUpper));
        bytes32 recomputedTokenKey = keccak256(abi.encodePacked(address(v3LiquidityActor), tokenLower, tokenUpper));
        assertEq(quoteKey, recomputedQuoteKey, "actor returned unexpected quote position key");
        assertEq(tokenKey, recomputedTokenKey, "actor returned unexpected token position key");
        (uint128 liveQuoteLiquidity,,,,) = IUniswapV3Pool(pool).positions(recomputedQuoteKey);
        (uint128 liveTokenLiquidity,,,,) = IUniswapV3Pool(pool).positions(recomputedTokenKey);
        assertEq(liveQuoteLiquidity, quoteLiquidity, "cached quote liquidity differs from canonical pool");
        assertEq(liveTokenLiquidity, tokenLiquidity, "cached token liquidity differs from canonical pool");
        return keccak256(
            abi.encode(
                quoteKey,
                quoteLower,
                quoteUpper,
                quoteLiquidity,
                recomputedQuoteKey,
                liveQuoteLiquidity,
                tokenKey,
                tokenLower,
                tokenUpper,
                tokenLiquidity,
                recomputedTokenKey,
                liveTokenLiquidity
            )
        );
    }
}
