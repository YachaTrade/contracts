// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {SetUp} from "../SetUp.t.sol";
import {LPManager} from "../../src/core/LPManager.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LPPrincipalLockHandler {
    uint256 private constant MIN_QUOTE_IN = 1e12;
    uint256 private constant QUOTE_RANGE = 0.1 ether;

    GiwaRouter private immutable _router;
    LPManager private immutable _lpManager;
    MockERC20 private immutable _quoteToken;
    IERC20 private immutable _launchToken;

    uint256 public donatedQuote;

    constructor(GiwaRouter router_, LPManager lpManager_, MockERC20 quoteToken_, address launchToken_) {
        _router = router_;
        _lpManager = lpManager_;
        _quoteToken = quoteToken_;
        _launchToken = IERC20(launchToken_);
    }

    function roundTrip(uint96 rawQuoteIn) external {
        uint256 quoteIn = MIN_QUOTE_IN + uint256(rawQuoteIn) % QUOTE_RANGE;
        _quoteToken.mint(address(this), quoteIn);
        _quoteToken.approve(address(_router), quoteIn);
        uint256 tokenOut = _router.buy(
            IGiwaRouter.BuyParams({
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
            IGiwaRouter.SellParams({
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
        _lpManager.collect(tokens);
    }

    function donateQuote(uint96 rawDonation) external {
        uint256 amount = 1 + uint256(rawDonation) % QUOTE_RANGE;
        donatedQuote += amount;
        _quoteToken.mint(address(_lpManager), amount);
    }
}

/// forge-config: default.invariant.depth = 256
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

        handler = new LPPrincipalLockHandler(giwaRouter, lpManager, quoteToken, launchToken);
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
            + IERC20(launchToken).balanceOf(address(giwaRouter)) + IERC20(launchToken).balanceOf(address(v3SwapAdapter))
            + IERC20(launchToken).balanceOf(address(creatorFeeProcessor))
            + IERC20(launchToken).balanceOf(address(creatorFeeVault));
        assertEq(accounted, IERC20(launchToken).totalSupply(), "launch-token supply escaped known lifecycle actors");
        assertEq(
            quoteToken.balanceOf(address(lpManager)),
            handler.donatedQuote(),
            "collection consumed donated LPManager quote"
        );
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
        (uint128 liveQuoteLiquidity,,,,) = IUniswapV3Pool(pool).positions(quoteKey);
        (uint128 liveTokenLiquidity,,,,) = IUniswapV3Pool(pool).positions(tokenKey);
        assertEq(liveQuoteLiquidity, quoteLiquidity, "cached quote liquidity differs from canonical pool");
        assertEq(liveTokenLiquidity, tokenLiquidity, "cached token liquidity differs from canonical pool");
        return keccak256(
            abi.encode(
                quoteKey,
                quoteLower,
                quoteUpper,
                quoteLiquidity,
                liveQuoteLiquidity,
                tokenKey,
                tokenLower,
                tokenUpper,
                tokenLiquidity,
                liveTokenLiquidity
            )
        );
    }
}
