# NadSwapAdapter

**Path:** `src/adapters/NadSwapAdapter.sol`
**Pattern:** Stateless (불변 배포, 프록시 없음)
**Inheritance:** `IDexAdapter`

NadFunPair(V2 AMM) 전용 어댑터. IDexAdapter 인터페이스를 구현하는 얇은 래퍼(thin wrapper). AMM 수학을 자체 구현하지 않고 NadFunPair.getAmountOut/getAmountIn에 위임. Push 패턴 — 호출자가 토큰을 어댑터로 먼저 전송해야 함.

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `swap(pair, tokenIn, tokenOut, amountIn, to, data)` | external | tokenIn을 pair로 전송 → pair.getAmountOut으로 출력량 계산 → pair.swap 실행. `data`는 flash swap 지원용으로 pair에 전달. |
| `getAmountOut(pair, tokenIn, amountIn)` | view | pair.getAmountOut에 위임 (fee-aware) |
| `getAmountIn(pair, tokenOut, amountOut)` | view | pair.getAmountIn에 위임 (fee-aware) |
| `addLiquidity(pair, tokenA, tokenB, amountA, amountB, to)` | external | 두 토큰을 pair로 전송 → pair.mint(to)로 LP 발행 |
| `removeLiquidity(pair, liquidity, to)` | external | LP를 pair로 전송 → pair.burn(to)로 기초 토큰 반환 |
| `claimableFees(pair, liquidity)` | pure | 항상 revert — NadFunPair V2는 수수료가 리저브에 내장 |
| `claimFees(pair, liquidity, to)` | pure | 항상 revert — 별도 수수료 청구 메커니즘 없음 |

---

## 에러

| 에러 | 설명 |
|------|------|
| `NoClaims()` | claimableFees/claimFees 호출 시 revert (V2에 해당 기능 없음) |

---

## 핵심 설계

### V2DexAdapter와의 차이

기존 V2DexAdapter는 Uniswap V2 호환 페어용으로 자체 `_getAmountOut`/`_getAmountIn` 수학을 구현했으나, NadSwapAdapter는 NadFunPair에 모든 AMM 계산을 위임한다. NadFunPair가 fee-aware 수학(NadFun 프로토콜 수수료 + 0.25% LP 수수료)의 단일 진실 원천(single source of truth)이므로, 어댑터에서 수학을 중복하지 않는다.

### swap 흐름

```
호출자 → tokenIn을 NadSwapAdapter로 전송
NadSwapAdapter.swap(pair, tokenIn, tokenOut, amountIn, to, data)
  ├─ tokenIn을 pair로 safeTransfer
  ├─ pair.getAmountOut(tokenIn, amountIn) → amountOut (fee 반영)
  ├─ tokenIn == token0 이면 pair.swap(0, amountOut, to, data)
  └─ 아니면 pair.swap(amountOut, 0, to, data)
```

NadFunPair 내부에서 수수료 수집(FeeCollector) 및 K invariant 검증이 이루어진다.
