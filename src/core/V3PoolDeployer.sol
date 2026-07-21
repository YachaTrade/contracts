// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IV3PoolDeployer} from "../interfaces/IV3PoolDeployer.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";

/// @title V3PoolDeployer
/// @notice Creates canonical Uniswap V3 pools at the configured graduation-target price.
contract V3PoolDeployer is IV3PoolDeployer, UUPSUpgradeable, AccessManagedUpgradeable {
    address public override factory;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy with its ProtocolManager authority and canonical V3 factory.
    function initialize(address protocolManager_, address factory_) external initializer {
        if (protocolManager_ == address(0) || protocolManager_.code.length == 0) revert InvalidAuthority();
        if (factory_ == address(0) || factory_.code.length == 0) revert InvalidFactory();

        __AccessManaged_init(protocolManager_);
        factory = factory_;
    }

    /// @inheritdoc IV3PoolDeployer
    function createPool(address token, address quoteToken) external restricted returns (address pool) {
        IProtocolManager.QuoteConfig memory config = IProtocolManager(authority()).getConfig(quoteToken);
        if (!config.active) revert QuoteTokenNotAllowed();

        IUniswapV3Factory v3Factory = IUniswapV3Factory(factory);
        if (v3Factory.feeAmountTickSpacing(config.v3FeeTier) == 0) revert InvalidFeeTier();

        uint256 k = config.virtualReserve * config.virtualTokenReserve;
        uint256 targetVirtualQuoteAmount = k / config.minTokenReserve;
        uint160 sqrtPriceX96 = _calculateSqrtPrice(
            token < quoteToken ? config.minTokenReserve : targetVirtualQuoteAmount,
            token < quoteToken ? targetVirtualQuoteAmount : config.minTokenReserve
        );

        pool = v3Factory.getPool(token, quoteToken, config.v3FeeTier);
        if (pool == address(0)) pool = v3Factory.createPool(token, quoteToken, config.v3FeeTier);
        _validateCanonicalPool(v3Factory, pool, token, quoteToken, config.v3FeeTier);

        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        (uint160 currentSqrtPriceX96,,,,,,) = v3Pool.slot0();
        if (currentSqrtPriceX96 != 0) revert PoolAlreadyInitialized();

        v3Pool.initialize(sqrtPriceX96);
        v3Pool.increaseObservationCardinalityNext(32);
    }

    function _validateCanonicalPool(
        IUniswapV3Factory v3Factory,
        address pool,
        address token,
        address quoteToken,
        uint24 feeTier
    ) private view {
        if (pool == address(0) || pool.code.length == 0 || v3Factory.getPool(token, quoteToken, feeTier) != pool) {
            revert InvalidPool();
        }

        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        (address token0, address token1) = token < quoteToken ? (token, quoteToken) : (quoteToken, token);
        if (
            v3Pool.factory() != factory || v3Pool.token0() != token0 || v3Pool.token1() != token1
                || v3Pool.fee() != feeTier
        ) revert InvalidPool();
    }

    function _calculateSqrtPrice(uint256 amount0, uint256 amount1) internal pure returns (uint160 sqrtPriceX96) {
        uint256 ratioX128 = FullMath.mulDiv(amount1, uint256(1) << 128, amount0);
        uint256 sqrtRatioX64 = Math.sqrt(ratioX128);
        uint256 encoded = sqrtRatioX64 << 32;
        if (encoded > type(uint160).max) revert OverFlow();
        return uint160(encoded);
    }

    function setAuthority(address) public override {
        revert AccessManagedUnauthorized(msg.sender);
    }

    function _authorizeUpgrade(address) internal override restricted {}
}
