// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";

/// @notice Security invariants for creator-fee settlement callbacks.
/// @dev Generic callback probes keep this coverage independent of any optional product vault.
contract SettlementInvariantsTest is SetUp {
    function _createWithCallback(address callback, bytes32 salt) internal returns (address token) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({vault: callback, bps: 10_000, setupData: ""});

        token = _createViaRouter(
            IBondingCurve.CreateTokenParams({
                name: "Settlement Probe",
                symbol: "SP",
                tokenURI: "",
                quoteToken: address(quoteToken),
                creatorFeeRate: defaultCreatorFeeRate,
                vaults: vaults,
                salt: salt,
                dexType: ITokenRegistry.DexType.UniswapV3,
                creator: creator,
                buyQuoteAmount: 0
            }),
            creator
        );
        _skipAntiSniping();
    }

    function _accumulateUntilSettleable(address token, address pool) internal {
        uint256 threshold = protocolManager.settlementThreshold(address(quoteToken));
        uint256 attempts = 10;
        while (feeCollector.accumulatedFee(pool) < threshold && attempts > 0) {
            _buyOnCurve(user2, token, 100_000 ether);
            attempts--;
        }
        assertGe(feeCollector.accumulatedFee(pool), threshold, "creator fees should reach settlement threshold");
    }

    function test_settlingFlag_togglesOnlyDuringCallback() public {
        SettlingFlagProbe probe = new SettlingFlagProbe(address(feeCollector));
        vm.prank(admin);
        vaultRegistry.register(address(probe), "SettlingFlagProbe", "test callback", IVaultRegistry.VaultType.Creator);

        address token = _createWithCallback(address(probe), keccak256("settling-flag"));
        address pool = bondingCurve.getCurve(token).pair;
        probe.setPool(pool);
        _accumulateUntilSettleable(token, pool);

        assertFalse(feeCollector.isSettling(pool), "flag should be false before settlement");
        feeCollector.settle(pool, 0);

        assertFalse(feeCollector.isSettling(pool), "flag should be false after settlement");
        assertTrue(probe.sawSettling(), "callback should observe an active settlement");
        assertEq(probe.callCount(), 1, "callback should run once");
    }

    function test_bondingCurve_waivesFeesDuringSettlementCallback() public {
        BuyCallbackProbe probe = new BuyCallbackProbe(address(bondingCurve));
        vm.prank(admin);
        vaultRegistry.register(address(probe), "BuyCallbackProbe", "test callback", IVaultRegistry.VaultType.Creator);

        address token = _createWithCallback(address(probe), keccak256("fee-waiver"));
        address pool = bondingCurve.getCurve(token).pair;
        _accumulateUntilSettleable(token, pool);

        uint256 feeReceiverBefore = quoteToken.balanceOf(feeReceiver);
        uint256 accumulatedBefore = feeCollector.accumulatedFee(pool);
        feeCollector.settle(pool, 0);

        assertGt(probe.lastQuoteIn(), 0, "callback should process quote");
        assertGt(probe.lastTokenOut(), 0, "callback should buy tokens");
        assertEq(feeCollector.accumulatedFee(pool), 0, "callback buy should not collect another creator fee");
        assertLt(feeCollector.accumulatedFee(pool), accumulatedBefore, "settlement should clear accumulated fees");
        assertEq(quoteToken.balanceOf(feeReceiver), feeReceiverBefore, "callback buy should not charge protocol fee");
    }

    function test_isSettling_isolatedPerPool() public {
        PoolIsolationProbe probe = new PoolIsolationProbe(address(feeCollector));
        vm.prank(admin);
        vaultRegistry.register(address(probe), "PoolIsolationProbe", "test callback", IVaultRegistry.VaultType.Creator);

        address tokenA = _createWithCallback(address(probe), keccak256("settling-pool-a"));
        address poolA = bondingCurve.getCurve(tokenA).pair;
        address tokenB = _createTokenWith("Settlement B", "SPB", defaultCreatorFeeRate, keccak256("settling-pool-b"));
        address poolB = bondingCurve.getCurve(tokenB).pair;
        _skipAntiSniping();

        probe.setPools(poolA, poolB);
        _accumulateUntilSettleable(tokenA, poolA);
        _accumulateUntilSettleable(tokenB, poolB);
        uint256 accumulatedBBefore = feeCollector.accumulatedFee(poolB);

        assertFalse(feeCollector.isSettling(poolA));
        assertFalse(feeCollector.isSettling(poolB));
        feeCollector.settle(poolA, 0);

        assertTrue(probe.sawSelfSettling(), "settled pool should be marked settling in callback");
        assertFalse(probe.sawOtherSettling(), "unrelated pool should remain outside settlement");
        assertEq(feeCollector.accumulatedFee(poolA), 0, "settled pool should reset");
        assertEq(feeCollector.accumulatedFee(poolB), accumulatedBBefore, "other pool should remain untouched");

        feeCollector.settle(poolB, 0);
        assertEq(feeCollector.accumulatedFee(poolB), 0, "other pool should settle independently");
    }
}

contract SettlingFlagProbe is IVault {
    IFeeCollector public immutable feeCollector;
    address public pool;
    bool public sawSettling;
    uint256 public callCount;

    constructor(address feeCollector_) {
        feeCollector = IFeeCollector(feeCollector_);
    }

    function setPool(address pool_) external {
        pool = pool_;
    }

    function setup(address, bytes calldata) external {}

    function afterDeposit(address, address, uint256) external {
        callCount++;
        sawSettling = feeCollector.isSettling(pool);
    }

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract BuyCallbackProbe is IVault {
    using SafeERC20 for IERC20;

    IBondingCurve public immutable bondingCurve;
    uint256 public lastQuoteIn;
    uint256 public lastTokenOut;

    constructor(address bondingCurve_) {
        bondingCurve = IBondingCurve(bondingCurve_);
    }

    function setup(address, bytes calldata) external {}

    function afterDeposit(address token, address quoteToken, uint256) external {
        uint256 quoteIn = IERC20(quoteToken).balanceOf(address(this));
        if (quoteIn == 0) return;
        lastQuoteIn = quoteIn;
        IERC20(quoteToken).safeTransfer(address(bondingCurve), quoteIn);
        lastTokenOut = bondingCurve.buy(address(this), token);
    }

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract PoolIsolationProbe is IVault {
    IFeeCollector public immutable feeCollector;
    address public selfPool;
    address public otherPool;
    bool public sawSelfSettling;
    bool public sawOtherSettling;

    constructor(address feeCollector_) {
        feeCollector = IFeeCollector(feeCollector_);
    }

    function setPools(address selfPool_, address otherPool_) external {
        selfPool = selfPool_;
        otherPool = otherPool_;
    }

    function setup(address, bytes calldata) external {}

    function afterDeposit(address, address, uint256) external {
        sawSelfSettling = feeCollector.isSettling(selfPool);
        sawOtherSettling = feeCollector.isSettling(otherPool);
    }

    function metadataURI() external pure returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVault).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
