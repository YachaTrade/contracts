# LPManager

**Path:** `src/core/LPManager.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `ILPManager`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

Pure LP accounting layer. Delegates DEX interactions to DexAdapter via TokenRegistry. Uses TokenRegistry as the pair source of truth and tracks per-caller liquidity amounts. Graduation LP is intended to be permanent protocol launch liquidity; LPManager does not expose a liquidity-removal entrypoint.

---

## State Variables

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `_tokenRegistry` | `address` | private | TokenRegistry for adapter lookup |
| `_liquidities` | `mapping(address => mapping(address => uint256))` | private | Per-token, per-caller liquidity tracking |

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager, tokenRegistry)` | initializer | Proxy initialization |
| `addLiquidity(token, quoteToken, tokenAmount, quoteAmount, dexType, pair)` | restricted | Add liquidity via DexAdapter delegation, track accounting |
| `claimFees(token)` | external | Collect LP fees via DexAdapter |
| `getPair(token)` | view | Return pair address for a token (queried from TokenRegistry) |
| `getLiquidity(token, caller)` | view | Return caller's LP amount for a token |
| `feeReceiver()` | view | Fee receiver address (queried from ProtocolManager) |

---

## Key Logic: addLiquidity Flow

`addLiquidity` is **not payable**. It delegates to DexAdapter for the actual DEX interaction.

```
BondingCurve._graduate() -> LPManager.addLiquidity(...)

  |- Validation:
  |   +- require(IERC20(token).balanceOf(this) >= tokenAmount)
  |
  |- Delegate to DexAdapter:
  |   |- IERC20(token).safeTransfer(adapter, tokenAmount)
  |   |- IERC20(quoteToken).safeTransfer(adapter, quoteAmount)
  |   +- liquidity = adapter.addLiquidity(pair, token, quoteToken, tokenAmount, quoteAmount, address(this))
  |
  +- Accounting:
      _liquidities[token][msg.sender] += liquidity
```

---

## Errors

| Error | Description |
|-------|-------------|
| `AddLiquidityFailed()` | Liquidity returned 0 |
| `InsufficientTokenBalance()` | Insufficient token balance |
| `NoClaimableFees()` | No claimable fees available |
| `UnsupportedDexType()` | Requested DexType is not supported |
