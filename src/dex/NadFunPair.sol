// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {INadFunPair} from "./interfaces/INadFunPair.sol";
import {INadFunCallee} from "./interfaces/INadFunCallee.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {Math} from "../libraries/Math.sol";
import {UQ112x112} from "../libraries/UQ112x112.sol";
import {BPS} from "../libraries/Constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface INadFunFactoryMinimal {
    function feeTo() external view returns (address);
}

contract NadFunPair is INadFunPair, ERC20PermitUpgradeable {
    using UQ112x112 for uint224;

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant LP_FEE_RATE = 25; // 0.25% in BPS

    address public factory;
    address public token0;
    address public token1;
    address public feeCollector;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast;

    uint256 private _unlocked;

    modifier lock() {
        require(_unlocked == 1, "NadFunPair: LOCKED");
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address factory_, address token0_, address token1_, address feeCollector_)
        external
        initializer
    {
        __ERC20_init("NadFun LP", "NADLP");
        __ERC20Permit_init("NadFun LP");
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        feeCollector = feeCollector_;
        _unlocked = 1;
    }

    function getReserves() public view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimestampLast = _blockTimestampLast;
    }

    /// @notice Whether the pair is currently inside a `lock`-guarded operation.
    /// @dev Exposed so external callers (e.g., FeeCollector.settle) can refuse to run inside
    ///      flash-swap callbacks, where vault `afterDeposit` hooks would reenter the pair and
    ///      revert silently under a `try/catch`.
    function isLocked() external view returns (bool) {
        return _unlocked == 0;
    }

    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 reserve0, uint112 reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - uint256(reserve0);
        uint256 amount1 = balance1 - uint256(reserve1);

        bool feeOn = _mintFee(reserve0, reserve1);
        uint256 totalSupply_ = totalSupply();

        if (totalSupply_ == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY); // lock minimum liquidity
        } else {
            liquidity = Math.min(amount0 * totalSupply_ / uint256(reserve0), amount1 * totalSupply_ / uint256(reserve1));
        }
        require(liquidity > 0, "NadFunPair: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, reserve0, reserve1);
        if (feeOn) kLast = uint256(_reserve0) * uint256(_reserve1);

        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 reserve0, uint112 reserve1,) = getReserves();
        address token0_ = token0;
        address token1_ = token1;
        uint256 balance0 = IERC20(token0_).balanceOf(address(this));
        uint256 balance1 = IERC20(token1_).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(reserve0, reserve1);
        uint256 totalSupply_ = totalSupply();

        amount0 = liquidity * balance0 / totalSupply_;
        amount1 = liquidity * balance1 / totalSupply_;
        require(amount0 > 0 && amount1 > 0, "NadFunPair: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        _safeTransfer(token0_, to, amount0);
        _safeTransfer(token1_, to, amount1);

        balance0 = IERC20(token0_).balanceOf(address(this));
        balance1 = IERC20(token1_).balanceOf(address(this));

        _update(balance0, balance1, reserve0, reserve1);
        if (feeOn) kLast = uint256(_reserve0) * uint256(_reserve1);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external {
        _swap(amount0Out, amount1Out, to, data);
    }

    function _swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) private lock {
        require(amount0Out > 0 || amount1Out > 0, "NadFunPair: INSUFFICIENT_OUTPUT_AMOUNT");

        (uint112 reserve0_, uint112 reserve1_,) = getReserves();
        require(
            amount0Out < uint256(reserve0_) && amount1Out < uint256(reserve1_), "NadFunPair: INSUFFICIENT_LIQUIDITY"
        );

        require(to != token0 && to != token1, "NadFunPair: INVALID_TO");

        if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);

        if (data.length > 0) INadFunCallee(to).nadFunCall(msg.sender, amount0Out, amount1Out, data);

        uint256 amount0In;
        uint256 amount1In;
        {
            uint256 balance0 = IERC20(token0).balanceOf(address(this));
            uint256 balance1 = IERC20(token1).balanceOf(address(this));
            amount0In = balance0 > uint256(reserve0_) - amount0Out ? balance0 - (uint256(reserve0_) - amount0Out) : 0;
            amount1In = balance1 > uint256(reserve1_) - amount1Out ? balance1 - (uint256(reserve1_) - amount1Out) : 0;
        }
        require(amount0In > 0 || amount1In > 0, "NadFunPair: INSUFFICIENT_INPUT_AMOUNT");

        if (!IFeeCollector(feeCollector).isSettling(address(this))) {
            _collectFee(amount0In, amount1In, amount0Out, amount1Out);
        }

        {
            uint256 balance0 = IERC20(token0).balanceOf(address(this));
            uint256 balance1 = IERC20(token1).balanceOf(address(this));
            {
                uint256 balance0Adjusted = balance0 * BPS - amount0In * LP_FEE_RATE;
                uint256 balance1Adjusted = balance1 * BPS - amount1In * LP_FEE_RATE;
                require(
                    balance0Adjusted * balance1Adjusted >= uint256(reserve0_) * uint256(reserve1_) * (BPS ** 2),
                    "NadFunPair: K"
                );
            }
            _update(balance0, balance1, reserve0_, reserve1_);
        }

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function skim(address to) external lock {
        address token0_ = token0;
        address token1_ = token1;
        _safeTransfer(token0_, to, IERC20(token0_).balanceOf(address(this)) - uint256(_reserve0));
        _safeTransfer(token1_, to, IERC20(token1_).balanceOf(address(this)) - uint256(_reserve1));
    }

    function sync() external lock {
        // Block sync before the pair has any liquidity. Otherwise an attacker could donate a
        // quote token to the pre-graduation pair, call sync() to lift reserves to match the
        // balance, and defeat LPManager's pre-addLiquidity skim (skim only transfers
        // balance - reserve; after sync that delta is zero). Once LP exists, sync is the
        // standard V2 helper that resets reserves to balance.
        require(totalSupply() > 0, "NadFunPair: NOT_LAUNCHED");
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), _reserve0, _reserve1);
    }

    // AMM View Functions

    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        require(tokenIn == token0 || tokenIn == token1, "NadFunPair: INVALID_TOKEN");
        (uint256 reserveIn, uint256 reserveOut) =
            tokenIn == token0 ? (uint256(_reserve0), uint256(_reserve1)) : (uint256(_reserve1), uint256(_reserve0));
        require(amountIn > 0, "NadFunPair: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "NadFunPair: INSUFFICIENT_LIQUIDITY");

        (uint16 feeRate, address quoteToken_) = _getFeeInfo();
        bool isBuy = (tokenIn == quoteToken_);
        bool settling = IFeeCollector(feeCollector).isSettling(address(this));

        if (isBuy || settling) {
            // Buy: LP + swap fee on input (settling: LP only)
            uint256 totalFeeRate = settling ? LP_FEE_RATE : LP_FEE_RATE + uint256(feeRate);
            uint256 amountInWithFee = amountIn * (BPS - totalFeeRate);
            amountOut = (amountInWithFee * reserveOut) / (reserveIn * BPS + amountInWithFee);
        } else {
            uint256 amountInWithLpFee = amountIn * (BPS - LP_FEE_RATE);
            amountOut = (amountInWithLpFee * reserveOut) / (reserveIn * BPS + amountInWithLpFee);
            if (feeRate > 0) {
                amountOut -= FixedPointMathLib.mulDivUp(amountOut, feeRate, BPS - LP_FEE_RATE);
            }
        }
    }

    function getAmountIn(address tokenOut, uint256 amountOut) external view returns (uint256 amountIn) {
        require(tokenOut == token0 || tokenOut == token1, "NadFunPair: INVALID_TOKEN");
        address tokenIn = tokenOut == token0 ? token1 : token0;
        (uint256 reserveIn, uint256 reserveOut) =
            tokenIn == token0 ? (uint256(_reserve0), uint256(_reserve1)) : (uint256(_reserve1), uint256(_reserve0));
        require(amountOut > 0, "NadFunPair: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0 && amountOut < reserveOut, "NadFunPair: INSUFFICIENT_LIQUIDITY");

        (uint16 feeRate, address quoteToken_) = _getFeeInfo();
        bool isBuy = (tokenIn == quoteToken_);
        bool settling = IFeeCollector(feeCollector).isSettling(address(this));

        if (isBuy || settling) {
            // Buy: totalFee on input reverse
            uint256 totalFeeRate = settling ? LP_FEE_RATE : LP_FEE_RATE + uint256(feeRate);
            amountIn =
                FixedPointMathLib.mulDivUp(reserveIn * BPS, amountOut, (BPS - totalFeeRate) * (reserveOut - amountOut));
        } else {
            uint256 amountOutBeforeSwapFee = amountOut;
            if (feeRate > 0) {
                amountOutBeforeSwapFee =
                    FixedPointMathLib.mulDivUp(amountOut, BPS - LP_FEE_RATE, BPS - LP_FEE_RATE - feeRate);
            }
            amountIn = FixedPointMathLib.mulDivUp(
                reserveIn * BPS, amountOutBeforeSwapFee, (BPS - LP_FEE_RATE) * (reserveOut - amountOutBeforeSwapFee)
            );
        }
    }

    // Internal

    function _getFeeInfo() internal view returns (uint16 feeRate, address quoteToken_) {
        try IFeeCollector(feeCollector).getFeeConfig(address(this)) returns (IFeeCollector.FeeConfig memory config) {
            feeRate = config.creatorFeeRate + config.dexProtocolFeeRate;
            quoteToken_ = config.quoteToken;
        } catch {
            return (0, address(0));
        }
    }

    ///
    /// Buy (quoteIn > 0):
    function _collectFee(uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out) private {
        address feeCollectorAddr = feeCollector;
        try IFeeCollector(feeCollectorAddr).getFeeConfig(address(this)) returns (
            IFeeCollector.FeeConfig memory config
        ) {
            uint16 feeRate = config.creatorFeeRate + config.dexProtocolFeeRate;
            address quoteToken_ = config.quoteToken;
            if (feeRate == 0) return;

            bool quoteIsToken0 = (quoteToken_ == token0);
            uint256 swapFee;

            uint256 quoteIn = quoteIsToken0 ? amount0In : amount1In;
            if (quoteIn > 0) {
                swapFee += quoteIn * uint256(feeRate) / BPS;
            }

            uint256 quoteOut = quoteIsToken0 ? amount0Out : amount1Out;
            if (quoteOut > 0) {
                swapFee += quoteOut * uint256(feeRate) / (BPS - LP_FEE_RATE - feeRate);
            }

            if (swapFee > 0) {
                uint256 protocolFee =
                    FixedPointMathLib.mulDivUp(swapFee, uint256(config.dexProtocolFeeRate), uint256(feeRate));
                uint256 creatorFee = swapFee - protocolFee;

                _safeTransfer(quoteToken_, feeCollectorAddr, swapFee);
                IFeeCollector(feeCollectorAddr).collectFee(address(this), protocolFee, creatorFee);
            }
        } catch {}
    }

    function _update(uint256 balance0, uint256 balance1, uint112 reserve0, uint112 reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "NadFunPair: OVERFLOW");
        uint32 blockTimestamp;
        uint32 timeElapsed;
        unchecked {
            blockTimestamp = uint32(block.timestamp % 2 ** 32);
            timeElapsed = blockTimestamp - _blockTimestampLast;
        }
        if (timeElapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            unchecked {
                price0CumulativeLast += uint256(UQ112x112.encode(reserve1).uqdiv(reserve0)) * timeElapsed;
                price1CumulativeLast += uint256(UQ112x112.encode(reserve0).uqdiv(reserve1)) * timeElapsed;
            }
        }
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
        _blockTimestampLast = blockTimestamp;

        emit Sync(uint112(balance0), uint112(balance1));
    }

    function _mintFee(uint112 reserve0, uint112 reserve1) private returns (bool feeOn) {
        address feeTo = INadFunFactoryMinimal(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 kLast_ = kLast;
        if (feeOn) {
            if (kLast_ != 0) {
                uint256 rootK = Math.sqrt(uint256(reserve0) * uint256(reserve1));
                uint256 rootKLast = Math.sqrt(kLast_);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply() * (rootK - rootKLast);
                    uint256 denominator = rootK * 4 + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (kLast_ != 0) {
            kLast = 0;
        }
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "NadFunPair: TRANSFER_FAILED");
    }
}
