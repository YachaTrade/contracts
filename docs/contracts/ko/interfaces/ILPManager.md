# ILPManager

**Path:** `src/interfaces/ILPManager.sol`
**Type:** Interface

LPManager의 LP 회계 및 위임 인터페이스.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `addLiquidity(token, quoteToken, tokenAmount, quoteAmount, dexType, pair)` | `uint256 liquidity` | 유동성 추가 및 호출자별 회계 추적 |
| `claimFees(token)` | `uint256 amount0, uint256 amount1` | LP 수수료 수취 |
| `getPair(token)` | `address` | 토큰의 pair 주소 조회 |
| `getLiquidity(token, caller)` | `uint256` | 호출자의 LP 수량 조회 |

---

## Events

| Event | Description |
|-------|-------------|
| `Allocate(token, pair, caller, dexType, tokenIn, quoteIn, liquidity)` | 유동성 추가 시 발생 |
| `ClaimFee(token, to, dexType, amount0, amount1)` | LP 수수료 수취 시 발생 |
