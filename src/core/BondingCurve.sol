// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBondingCurve} from "../interfaces/IBondingCurve.sol";
import {IProtocolManager} from "../interfaces/IProtocolManager.sol";
import {BondingCurveLibrary} from "../libraries/BondingCurveLibrary.sol";
import {ITokenRegistry} from "../interfaces/ITokenRegistry.sol";
import {ILPManager} from "../interfaces/ILPManager.sol";
import {IToken} from "../interfaces/IToken.sol";
import {ICreatorFeeProcessor} from "../interfaces/ICreatorFeeProcessor.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {INadFunFactory} from "../dex/interfaces/INadFunFactory.sol";
import {BPS} from "../libraries/Constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IVault} from "../interfaces/IVault.sol";
import {IVaultRegistry} from "../interfaces/IVaultRegistry.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BondingCurve
/// @notice Core state machine for token creation, curve trading, graduation, and anti-sniping.
/// @dev Stores per-token curve state and coordinates TokenRegistry, LPManager, vault setup,
///      FeeCollector setup, and graduation into the NadFun pair.
contract BondingCurve is IBondingCurve, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Clones for address;

    CurveVersion public constant VERSION = CurveVersion.V1;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    bytes32 public constant MODULE_LP_MANAGER = keccak256("LP_MANAGER");
    bytes32 public constant MODULE_TOKEN_REGISTRY = keccak256("TOKEN_REGISTRY");
    bytes32 public constant MODULE_VAULT_REGISTRY = keccak256("VAULT_REGISTRY");
    bytes32 public constant MODULE_CREATOR_FEE_PROCESSOR = keccak256("CREATOR_FEE_PROCESSOR");
    bytes32 public constant MODULE_FEE_COLLECTOR = keccak256("FEE_COLLECTOR");
    bytes32 public constant MODULE_FACTORY = keccak256("FACTORY");

    address private _tokenImplementation;
    IProtocolManager private _protocolManager;
    bool private _halted;

    mapping(address => Curve) internal curves;
    mapping(bytes32 => address) private _modules;

    mapping(address => uint256) private _totalQuoteReserved;

    mapping(address => uint256) private _totalTokenReserved;

    modifier notHalted() {
        if (_halted) revert ProtocolHalted();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address tokenImpl_, address protocolManager_) external initializer {
        require(tokenImpl_ != address(0), "Zero token impl");
        require(protocolManager_ != address(0), "Zero protocol manager");

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);

        _tokenImplementation = tokenImpl_;
        _protocolManager = IProtocolManager(protocolManager_);
    }

    function create(CreateTokenParams calldata params)
        external
        payable
        onlyRole(ROUTER_ROLE)
        notHalted
        nonReentrant
        returns (address token, uint256 tokenOut)
    {
        require(_protocolManager.isAllowed(params.quoteToken), "Quote token not allowed");
        _validateCreatorFeeRate(params.creatorFeeRate);

        address creator = params.creator;
        uint256 quoteIn;

        {
            uint256 totalIn =
                IERC20(params.quoteToken).balanceOf(address(this)) - _totalQuoteReserved[params.quoteToken];

            uint256 deployFee_ = _protocolManager.deployFee(params.quoteToken);
            uint256 requiredQuote = deployFee_ + params.buyQuoteAmount;
            require(totalIn >= requiredQuote, "Insufficient for create");

            if (deployFee_ > 0) {
                IERC20(params.quoteToken).safeTransfer(_protocolManager.feeReceiver(), deployFee_);
            }

            uint256 excessQuote = totalIn - requiredQuote;
            if (excessQuote > 0) {
                IERC20(params.quoteToken).safeTransfer(_protocolManager.feeReceiver(), excessQuote);
            }

            token = _create(params, creator);
            quoteIn = params.buyQuoteAmount;
        }

        {
            Curve storage curve = curves[token];
            emit Create(
                params.creator,
                token,
                curve.pair,
                params.quoteToken,
                params.name,
                params.symbol,
                params.tokenURI,
                curve.virtualQuoteReserve,
                curve.virtualTokenReserve,
                curve.minTokenReserve
            );
        }

        if (quoteIn > 0) {
            tokenOut = _initialBuy(creator, token, curves[token], quoteIn);
        }
    }

    function _create(CreateTokenParams calldata params, address creator) internal returns (address token) {
        IProtocolManager.QuoteConfig memory quoteConfig = _protocolManager.getConfig(params.quoteToken);
        _validateGraduateFee(quoteConfig);

        address registry = _modules[MODULE_TOKEN_REGISTRY];
        require(registry != address(0), "TOKEN_REGISTRY not set");
        // Reject dexTypes that have no adapter registered. Without this, a token created with
        // an unsupported dexType would deploy fine but get stuck at graduation, when LPManager
        // reverts on the unsupported adapter lookup — permanently locking the token.
        require(address(ITokenRegistry(registry).getAdapter(params.dexType)) != address(0), "Unsupported dexType");

        token = _tokenImplementation.cloneDeterministic(params.salt);

        address pair = _deployPairViaFactory(token, params.quoteToken);

        ITokenRegistry(registry).register(token, pair, params.quoteToken, params.dexType);

        address feeCollector_ = _modules[MODULE_FEE_COLLECTOR];
        require(feeCollector_ != address(0), "FEE_COLLECTOR not set");
        IFeeCollector(feeCollector_)
            .setup(
                pair,
                token,
                params.quoteToken,
                params.creatorFeeRate,
                _protocolManager.curveProtocolFeeRate(params.quoteToken),
                _protocolManager.dexProtocolFeeRate(params.quoteToken)
            );

        ICreatorFeeProcessor.VaultSlot[] memory vaultSlots = _setupVaults(token, params.vaults);
        address processor = _modules[MODULE_CREATOR_FEE_PROCESSOR];
        require(processor != address(0), "CREATOR_FEE_PROCESSOR not set");
        ICreatorFeeProcessor(processor).setup(token, vaultSlots);

        IToken(token).initialize(params.name, params.symbol, params.tokenURI, address(this), pair);

        _initCurve(_CurveInitArgs(token, pair), params, quoteConfig, creator);

        _totalTokenReserved[token] = IERC20(token).balanceOf(address(this));
    }

    function _validateCreatorFeeRate(uint16 creatorFeeRate) internal view {
        require(_protocolManager.isCreatorFeeRateAllowed(creatorFeeRate), "Creator fee rate not allowed");
    }

    function _deployPairViaFactory(address token, address quoteToken) internal returns (address) {
        address factory = _modules[MODULE_FACTORY];
        require(factory != address(0), "FACTORY not set");
        return INadFunFactory(factory).createPair(token, quoteToken);
    }

    function _setupVaults(address token, VaultAllocation[] calldata allocations)
        internal
        returns (ICreatorFeeProcessor.VaultSlot[] memory vaultSlots)
    {
        address registry = _modules[MODULE_VAULT_REGISTRY];
        require(registry != address(0), "VAULT_REGISTRY not set");

        vaultSlots = new ICreatorFeeProcessor.VaultSlot[](allocations.length);

        for (uint256 i = 0; i < allocations.length; i++) {
            address vault = allocations[i].vault;
            for (uint256 j = 0; j < i; j++) {
                if (vault == allocations[j].vault) revert DuplicateVault();
            }
            require(IVaultRegistry(registry).isActive(vault), "Vault not active");

            IVault(vault).setup(token, allocations[i].setupData);

            vaultSlots[i] = ICreatorFeeProcessor.VaultSlot({vault: vault, bps: allocations[i].bps});
        }
    }

    struct _CurveInitArgs {
        address token;
        address pair;
    }

    function _initCurve(
        _CurveInitArgs memory args,
        CreateTokenParams calldata params,
        IProtocolManager.QuoteConfig memory quoteConfig,
        address creator
    ) internal {
        Curve storage curve = curves[args.token];
        curve.token = args.token;
        curve.creator = creator;
        curve.quoteToken = params.quoteToken;
        curve.virtualQuoteReserve = quoteConfig.virtualReserve;
        curve.virtualTokenReserve = quoteConfig.virtualTokenReserve;
        curve.k = curve.virtualQuoteReserve * curve.virtualTokenReserve;
        curve.minTokenReserve = quoteConfig.minTokenReserve;
        curve.initialQuoteReserve = quoteConfig.virtualReserve;
        curve.initialTokenReserve = quoteConfig.virtualTokenReserve;
        curve.createdAtBlock = uint64(block.number);
        curve.creatorFeeRate = params.creatorFeeRate;
        curve.version = VERSION;
        curve.dexType = params.dexType;
        curve.pair = args.pair;
        curve.graduateFee = quoteConfig.graduateFee;
    }

    function _validateGraduateFee(IProtocolManager.QuoteConfig memory quoteConfig) internal pure {
        uint256 k = quoteConfig.virtualReserve * quoteConfig.virtualTokenReserve;
        uint256 quoteReserveAtGraduation = FixedPointMathLib.mulDivUp(k, 1, quoteConfig.minTokenReserve);
        uint256 quoteBalanceBeforeGraduateFee = quoteReserveAtGraduation - quoteConfig.virtualReserve;
        require(quoteBalanceBeforeGraduateFee > quoteConfig.graduateFee, "Insufficient for graduate fee");
    }

    //   if (curve.version == CurveVersion.V1) _buyV1(...)
    //   else if (curve.version == CurveVersion.V2) _buyV2(...)
    /// @notice Buys tokens from the bonding curve using quote tokens already transferred to this contract.
    /// @dev This low-level entrypoint performs no slippage or deadline checks. User-facing buys should
    ///      go through NadFunRouter, which enforces caller-provided execution protection.
    function buy(address to, address token) external notHalted nonReentrant returns (uint256 tokenOut) {
        Curve storage curve = curves[token];
        if (curve.token == address(0)) revert TokenNotFound();
        if (curve.graduated) revert AlreadyGraduated();

        if (curve.version == CurveVersion.V1) {
            tokenOut = _buyV1(to, token, curve);
        } else {
            revert UnsupportedVersion();
        }
    }

    function _buyV1(address to, address token, Curve storage curve) internal returns (uint256 tokenOut) {
        uint256 quoteIn = IERC20(curve.quoteToken).balanceOf(address(this)) - _totalQuoteReserved[curve.quoteToken];
        require(quoteIn > 0, "No quote sent");

        (uint256 protocolFee, uint256 snipingFee, uint256 creatorFee, uint256 quoteInAfterFees) =
            _calculateFees(token, quoteIn, curve, true);

        if (quoteInAfterFees == 0) {
            if (snipingFee > 0) {
                IERC20(curve.quoteToken).safeTransfer(_protocolManager.feeReceiver(), snipingFee);
                emit SnipingPenalty(token, to, snipingFee, _getSnipingFeeRate(token));
            }
            _sendCombinedFee(token, curve.quoteToken, protocolFee, creatorFee);
            emit Buy(token, to, quoteIn, 0);
            return 0;
        }

        tokenOut = BondingCurveLibrary.getAmountOut(
            quoteInAfterFees, curve.k, curve.virtualQuoteReserve, curve.virtualTokenReserve
        );

        uint256 availableTokenOut = curve.virtualTokenReserve - curve.minTokenReserve;

        if (tokenOut > availableTokenOut) {
            tokenOut = availableTokenOut;
            uint256 requiredQuoteIn = BondingCurveLibrary.getAmountIn(
                availableTokenOut, curve.k, curve.virtualQuoteReserve, curve.virtualTokenReserve
            );
            uint256 excessQuoteIn = quoteInAfterFees - requiredQuoteIn;
            if (excessQuoteIn > 0) {
                IERC20(curve.quoteToken).safeTransfer(_protocolManager.feeReceiver(), excessQuoteIn);
            }
            quoteInAfterFees = requiredQuoteIn;
        }

        if (snipingFee > 0) {
            IERC20(curve.quoteToken).safeTransfer(_protocolManager.feeReceiver(), snipingFee);
            emit SnipingPenalty(token, to, snipingFee, _getSnipingFeeRate(token));
        }

        _sendCombinedFee(token, curve.quoteToken, protocolFee, creatorFee);

        IERC20(token).safeTransfer(to, tokenOut);

        _updateCurve(token, quoteInAfterFees, tokenOut, true);

        emit Buy(token, to, quoteIn, tokenOut);
    }

    function _initialBuy(address to, address token, Curve storage curve, uint256 quoteIn)
        internal
        returns (uint256 tokenOut)
    {
        (uint256 protocolFee,, uint256 creatorFee, uint256 quoteInAfterFees) =
            _calculateFees(token, quoteIn, curve, false);

        tokenOut = BondingCurveLibrary.getAmountOut(
            quoteInAfterFees, curve.k, curve.virtualQuoteReserve, curve.virtualTokenReserve
        );

        uint256 availableTokenOut = curve.virtualTokenReserve - curve.minTokenReserve;

        if (tokenOut > availableTokenOut) {
            tokenOut = availableTokenOut;
            uint256 requiredQuoteIn = BondingCurveLibrary.getAmountIn(
                availableTokenOut, curve.k, curve.virtualQuoteReserve, curve.virtualTokenReserve
            );
            uint256 excessQuoteIn = quoteInAfterFees - requiredQuoteIn;
            if (excessQuoteIn > 0) {
                IERC20(curve.quoteToken).safeTransfer(_protocolManager.feeReceiver(), excessQuoteIn);
            }
            quoteInAfterFees = requiredQuoteIn;
        }

        _sendCombinedFee(token, curve.quoteToken, protocolFee, creatorFee);

        IERC20(token).safeTransfer(to, tokenOut);

        _updateCurve(token, quoteInAfterFees, tokenOut, true);

        emit Buy(token, to, quoteIn, tokenOut);
    }

    /// @notice Sells tokens into the bonding curve using base tokens already transferred to this contract.
    /// @dev This low-level entrypoint performs no slippage or deadline checks. User-facing sells should
    ///      go through NadFunRouter, which enforces caller-provided execution protection.
    function sell(address to, address token) external notHalted nonReentrant returns (uint256 quoteOut) {
        Curve storage curve = curves[token];
        if (curve.token == address(0)) revert TokenNotFound();
        if (curve.graduated) revert AlreadyGraduated();

        if (curve.version == CurveVersion.V1) {
            quoteOut = _sellV1(to, token, curve);
        } else {
            revert UnsupportedVersion();
        }
    }

    function _sellV1(address to, address token, Curve storage curve) internal returns (uint256 quoteOutAfterFees) {
        uint256 tokenIn = IERC20(token).balanceOf(address(this)) - _totalTokenReserved[token];
        require(tokenIn > 0, "No tokens");

        uint256 quoteOutBeforeFees =
            BondingCurveLibrary.getAmountOut(tokenIn, curve.k, curve.virtualTokenReserve, curve.virtualQuoteReserve);

        (uint256 protocolFee,, uint256 creatorFee, uint256 quoteOutAfterFees_) =
            _calculateFees(token, quoteOutBeforeFees, curve, false);
        quoteOutAfterFees = quoteOutAfterFees_;

        _sendCombinedFee(token, curve.quoteToken, protocolFee, creatorFee);

        IERC20(curve.quoteToken).safeTransfer(to, quoteOutAfterFees);

        _updateCurve(token, tokenIn, quoteOutBeforeFees, false);

        emit Sell(token, to, tokenIn, quoteOutAfterFees);
    }

    function _updateCurve(address token, uint256 amountIn, uint256 amountOut, bool isBuy) private {
        Curve storage curve = curves[token];

        if (isBuy) {
            curve.virtualQuoteReserve += amountIn;
            curve.virtualTokenReserve -= amountOut;
        } else {
            curve.virtualQuoteReserve -= amountOut;
            curve.virtualTokenReserve += amountIn;
        }

        if (curve.virtualQuoteReserve * curve.virtualTokenReserve < curve.k) revert InvalidKValue();

        if (curve.virtualTokenReserve == curve.minTokenReserve) {
            _graduate(token);
        }

        _totalQuoteReserved[curve.quoteToken] = IERC20(curve.quoteToken).balanceOf(address(this));
        _totalTokenReserved[token] = IERC20(token).balanceOf(address(this));

        emit Sync(
            token,
            _totalQuoteReserved[curve.quoteToken],
            _totalTokenReserved[token],
            curve.virtualQuoteReserve,
            curve.virtualTokenReserve
        );
    }

    function _graduate(address token) internal {
        Curve storage curve = curves[token];

        if (curve.version == CurveVersion.V1) {
            _graduateV1(token, curve);
        } else {
            revert UnsupportedVersion();
        }
    }

    function _graduateV1(address token, Curve storage curve) internal {
        curve.graduated = true;

        IToken(token).setIsGraduated();

        address lpManager = _modules[MODULE_LP_MANAGER];
        require(lpManager != address(0), "LP_MANAGER not set");

        uint256 quoteBalanceBeforeGraduateFee = curve.virtualQuoteReserve - curve.initialQuoteReserve;

        uint256 quoteBalanceAfterGraduateFee = quoteBalanceBeforeGraduateFee;
        {
            uint256 graduateFee_ = curve.graduateFee;
            if (graduateFee_ > 0) {
                require(quoteBalanceBeforeGraduateFee > graduateFee_, "Insufficient for graduate fee");
                quoteBalanceAfterGraduateFee = quoteBalanceBeforeGraduateFee - graduateFee_;
                IERC20(curve.quoteToken).safeTransfer(_protocolManager.feeReceiver(), graduateFee_);
            }
        }

        uint256 tokenForLiquidity = quoteBalanceAfterGraduateFee * curve.virtualTokenReserve / curve.virtualQuoteReserve;

        {
            uint256 currentTokenBalance = IERC20(token).balanceOf(address(this));
            uint256 excessToken = currentTokenBalance - tokenForLiquidity;
            if (excessToken > 0) {
                IERC20(token).safeTransfer(_protocolManager.feeReceiver(), excessToken);
            }
        }

        IERC20(token).safeTransfer(lpManager, tokenForLiquidity);
        IERC20(curve.quoteToken).safeTransfer(lpManager, quoteBalanceAfterGraduateFee);

        ILPManager(lpManager)
            .addLiquidity(
                token, curve.quoteToken, tokenForLiquidity, quoteBalanceAfterGraduateFee, curve.dexType, curve.pair
            );

        emit Graduate(token, curve.pair);
    }

    function _calculateFees(address token, uint256 amount, Curve storage curve, bool withSniping)
        internal
        view
        returns (uint256 protocolFee, uint256 snipingFee, uint256 creatorFee, uint256 amountAfterFees)
    {
        address feeCollector_ = _modules[MODULE_FEE_COLLECTOR];
        if (IFeeCollector(feeCollector_).isSettling(curve.pair)) {
            return (0, 0, 0, amount);
        }
        uint256 snipingFeeRate = withSniping ? _getSnipingFeeRate(token) : 0;
        IFeeCollector.FeeConfig memory feeConfig = IFeeCollector(feeCollector_).getFeeConfig(curve.pair);
        uint256 protocolFeeRate = feeConfig.curveProtocolFeeRate;
        uint256 creatorFeeRate = feeConfig.creatorFeeRate;
        uint256 totalFeeRate = snipingFeeRate + protocolFeeRate + creatorFeeRate;
        if (totalFeeRate == 0) {
            return (0, 0, 0, amount);
        }

        uint256 totalFee = totalFeeRate >= BPS ? amount : FixedPointMathLib.mulDivUp(amount, totalFeeRate, BPS);
        amountAfterFees = amount - totalFee;

        uint256 remainingFee = totalFee;
        snipingFee = FixedPointMathLib.mulDivUp(amount, snipingFeeRate, BPS);
        if (snipingFee > remainingFee) snipingFee = remainingFee;
        remainingFee -= snipingFee;

        protocolFee = FixedPointMathLib.mulDivUp(amount, protocolFeeRate, BPS);
        if (protocolFee > remainingFee) protocolFee = remainingFee;
        remainingFee -= protocolFee;

        creatorFee = remainingFee;
    }

    /// @dev Forwards creator-bearing fees to FeeCollector with the exact split calculated by the
    ///      bonding curve fee priority model. Protocol-only fees are paid directly to avoid
    ///      unnecessary FeeCollector accounting.
    function _sendCombinedFee(address token, address quoteToken, uint256 protocolFee, uint256 creatorFee) internal {
        uint256 combinedFee = protocolFee + creatorFee;
        if (combinedFee == 0) return;
        if (creatorFee == 0) {
            IERC20(quoteToken).safeTransfer(_protocolManager.feeReceiver(), protocolFee);
            return;
        }
        address feeCollector_ = _modules[MODULE_FEE_COLLECTOR];
        address pair = ITokenRegistry(_modules[MODULE_TOKEN_REGISTRY]).getPair(token);
        IERC20(quoteToken).safeTransfer(feeCollector_, combinedFee);
        IFeeCollector(feeCollector_).collectFee(pair, protocolFee, creatorFee);
    }

    function _getTotalFeeRate(address token, Curve storage curve, bool withSniping) internal view returns (uint256) {
        address feeCollector_ = _modules[MODULE_FEE_COLLECTOR];
        if (IFeeCollector(feeCollector_).isSettling(curve.pair)) {
            return 0;
        }
        uint256 snipingFeeRate = withSniping ? _getSnipingFeeRate(token) : 0;
        IFeeCollector.FeeConfig memory feeConfig = IFeeCollector(feeCollector_).getFeeConfig(curve.pair);
        return snipingFeeRate + feeConfig.curveProtocolFeeRate + feeConfig.creatorFeeRate;
    }

    function _getSnipingFeeRate(address token) internal view returns (uint256) {
        return _protocolManager.getSnipingPenalty(curves[token].createdAtBlock);
    }

    function getCurve(address token) external view returns (Curve memory) {
        return curves[token];
    }

    function getQuoteToken(address token) external view returns (address) {
        return curves[token].quoteToken;
    }

    function isHalted() external view returns (bool) {
        return _halted;
    }

    function getAmountOut(address token, uint256 amountIn, bool isBuy) external view returns (uint256 amountOut) {
        Curve storage curve = curves[token];
        if (curve.graduated) revert AlreadyGraduated();

        if (isBuy) {
            (,,, uint256 quoteInAfterFees) = _calculateFees(token, amountIn, curve, true);
            if (quoteInAfterFees == 0) return 0;

            amountOut = BondingCurveLibrary.getAmountOut(
                quoteInAfterFees, curve.k, curve.virtualQuoteReserve, curve.virtualTokenReserve
            );

            uint256 availableTokenOut = curve.virtualTokenReserve - curve.minTokenReserve;
            if (amountOut > availableTokenOut) {
                amountOut = availableTokenOut;
            }
        } else {
            uint256 quoteOutBeforeFees = BondingCurveLibrary.getAmountOut(
                amountIn, curve.k, curve.virtualTokenReserve, curve.virtualQuoteReserve
            );
            (,,, uint256 quoteAfterFees) = _calculateFees(token, quoteOutBeforeFees, curve, false);
            amountOut = quoteAfterFees;
        }
    }

    function getAmountIn(address token, uint256 amountOut, bool isBuy) external view returns (uint256 amountIn) {
        Curve storage curve = curves[token];
        if (curve.graduated) revert AlreadyGraduated();

        uint256 totalFeeRate = _getTotalFeeRate(token, curve, isBuy);
        require(totalFeeRate < BPS, "Fee exceeds 100%");

        if (isBuy) {
            uint256 availableTokenOut = curve.virtualTokenReserve - curve.minTokenReserve;
            if (amountOut > availableTokenOut) {
                revert InsufficientTokenOut();
            }

            uint256 quoteInAfterFees = BondingCurveLibrary.getAmountIn(
                amountOut, curve.k, curve.virtualQuoteReserve, curve.virtualTokenReserve
            );
            amountIn = totalFeeRate == 0
                ? quoteInAfterFees
                : FixedPointMathLib.mulDivUp(quoteInAfterFees, BPS, BPS - totalFeeRate);
        } else {
            uint256 quoteOutBeforeFees =
                totalFeeRate == 0 ? amountOut : FixedPointMathLib.mulDivUp(amountOut, BPS, BPS - totalFeeRate);
            amountIn = BondingCurveLibrary.getAmountIn(
                quoteOutBeforeFees, curve.k, curve.virtualTokenReserve, curve.virtualQuoteReserve
            );
        }
    }

    function getSnipingPenalty(address token) external view returns (uint256 penaltyBps) {
        return _getSnipingFeeRate(token);
    }

    function creatorFeeProcessor() external view returns (address) {
        return _modules[MODULE_CREATOR_FEE_PROCESSOR];
    }

    function setModule(bytes32 moduleId, address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module == address(0)) revert ZeroModule();
        if (_modules[moduleId] != address(0)) revert ModuleAlreadySet(moduleId);

        _modules[moduleId] = module;
        emit ModuleUpdate(moduleId, module);
    }

    function halt(bool halted_) external onlyRole(GUARDIAN_ROLE) {
        _halted = halted_;
        emit Halt(halted_);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
