# LPManager

**Path:** `src/core/LPManager.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `ILPManager`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

순수 LP 회계 레이어. TokenRegistry를 통해 DexAdapter에 DEX 상호작용을 위임한다. pair 주소는 TokenRegistry를 source of truth로 사용하고, 호출자별 유동성 수량만 추적한다. Graduation LP는 영구 launch liquidity로 유지되며, LPManager는 유동성 제거 entrypoint를 노출하지 않는다.

---

## State Variables

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_tokenRegistry` | `address` | private | 어댑터 조회용 TokenRegistry |
| `_liquidities` | `mapping(address => mapping(address => uint256))` | private | 토큰별, 호출자별 유동성 추적 |

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager, tokenRegistry)` | initializer | 프록시 초기화 |
| `addLiquidity(token, quoteToken, tokenAmount, quoteAmount, dexType, pair)` | restricted | DexAdapter 위임을 통한 유동성 추가, 회계 추적 |
| `claimFees(token)` | external | DexAdapter를 통한 LP 수수료 수취 |
| `getPair(token)` | view | TokenRegistry에서 토큰의 pair 주소 조회 |
| `getLiquidity(token, caller)` | view | 호출자의 LP 수량 반환 |
| `feeReceiver()` | view | 수수료 수령 주소 (ProtocolManager에서 조회) |

---

## Key Logic: addLiquidity Flow

`addLiquidity`는 **payable이 아님**. DexAdapter에 실제 DEX 상호작용을 위임.

```
BondingCurve._graduate() -> LPManager.addLiquidity(...)

  |- 검증:
  |   +- require(IERC20(token).balanceOf(this) >= tokenAmount)
  |
  |- DexAdapter 위임:
  |   |- IERC20(token).safeTransfer(adapter, tokenAmount)
  |   |- IERC20(quoteToken).safeTransfer(adapter, quoteAmount)
  |   +- liquidity = adapter.addLiquidity(pair, token, quoteToken, tokenAmount, quoteAmount, address(this))
  |
  +- 회계:
      _liquidities[token][msg.sender] += liquidity
```

---

## Errors

| Error | Description |
|-------|-------------|
| `AddLiquidityFailed()` | 유동성 반환값 0 |
| `InsufficientTokenBalance()` | 토큰 잔액 부족 |
| `NoClaimableFees()` | 청구 가능한 수수료 없음 |
| `UnsupportedDexType()` | 지원하지 않는 DexType |
