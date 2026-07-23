# IProtocolManager

**경로:** `src/interfaces/IProtocolManager.sol`
**타입:** Interface

프로토콜 전역 quote 설정과 selector 단위 authority interface다.

## QuoteConfig

```solidity
struct QuoteConfig {
    uint8 decimals;
    uint256 virtualReserve;
    uint256 virtualTokenReserve;
    uint256 minTokenReserve;
    uint256 deployFee;
    uint256 graduateFee;
    uint16 curveProtocolFeeRate;
    uint16 dexProtocolFeeRate;
    uint24 v3FeeTier;
    uint16 lpFeeProtocolShareBps;
    bool active;
}
```

## 주요 함수

| 그룹 | 함수 |
| --- | --- |
| Authority | `setOperatorPermission`, `isOperatorAllowed`, `canCall` |
| Fee 조회 | `feeReceiver`, `curveProtocolFeeRate`, `dexProtocolFeeRate`, `deployFee`, `graduateFee`, `v3FeeTier`, `lpFeeProtocolShareBps` |
| Fee 관리 | `setFeeReceiver`, `setV3QuoteConfig` |
| Anti-sniping | `snipingPenaltyTable`, `snipingPenaltyAt`, `snipingPenaltyTableLength`, `getSnipingPenalty`, `setSnipingPenaltyTable` |
| Quote lifecycle | `addQuoteToken`, `addV3QuoteToken`, `removeQuoteToken`, `updateQuoteToken`, `updateV3QuoteToken` |
| Quote 조회 | `isAllowed`, `getConfig`, `getVirtualReserve`, `getVirtualTokenReserve`, `getMinTokenReserve`, `getDecimals` |

## 이벤트

- `FeeReceiverUpdate`
- `V3QuoteConfigUpdate`
- `SnipingPenaltyTableUpdate`
- `QuoteTokenAdd`
- `QuoteTokenRemove`
- `QuoteTokenUpdate`
- `OperatorPermissionUpdated`

## 에러

- `QuoteTokenNotAllowed`
- `QuoteTokenAlreadyAdded`
- `InvalidFeeTier`
- `InvalidLpFeeShare`
- `ZeroAddress`
