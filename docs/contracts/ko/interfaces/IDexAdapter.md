# IDexAdapter

**경로:** `src/interfaces/IDexAdapter.sol`
**타입:** 선택적 외부-market adapter interface

`IDexAdapter`는 선택적 vault integration이 명시적으로 설정한 외부 market에서 사용하는 push 기반 interface다. Canonical launch 경로는 이 interface를 사용하지 않는다. YachaRouter는 `IV3SwapAdapter`, LPManager는 `IV3LiquidityActor`와 `IV3SwapAdapter`를 사용한다.

## 함수

| 함수 | 설명 |
| --- | --- |
| `swap(pair, tokenIn, tokenOut, amountIn, to, data)` | Push-funded swap 실행 |
| `getAmountOut(pair, tokenIn, amountIn)` | Exact-input quote |
| `getAmountIn(pair, tokenOut, amountOut)` | Exact-output quote |
| `addLiquidity(pair, tokenA, tokenB, amountA, amountB, to)` | Push-funded liquidity 추가 |
| `removeLiquidity(pair, liquidity, to)` | Liquidity 제거 |
| `claimableFees(pair, liquidity)` | 수집 가능 fee 조회 |
| `claimFees(pair, liquidity, to)` | Fee 수집 |

현재 선택적 구현은 `UniswapV2ExternalAdapter`와 `UniswapV3ExternalAdapter`다.
