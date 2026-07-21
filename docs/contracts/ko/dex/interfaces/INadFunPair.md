# INadFunPair

**Path:** `src/dex/interfaces/INadFunPair.sol`
**Type:** Interface

NadFunPair 인터페이스. Uniswap V2 Pair 표준 함수에 fee-aware AMM view 함수(`getAmountOut`, `getAmountIn`)와 `feeCollector` 조회가 추가됨.

`getAmountOut()` / `getAmountIn()`은 NadFunPair swap의 canonical quote interface다. 0.25% LP fee와 NadFun creator/protocol fee 계산을 모두 포함하므로, NadFunPair 라우팅에는 일반 Uniswap V2 library math를 그대로 쓰면 안 된다.

---

## 함수 시그니처

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `MINIMUM_LIQUIDITY()` | `uint256` | 최소 유동성 상수 (10**3) |
| `factory()` | `address` | 팩토리 주소 |
| `token0()` | `address` | 정렬된 첫 번째 토큰 |
| `token1()` | `address` | 정렬된 두 번째 토큰 |
| `feeCollector()` | `address` | FeeCollector 컨트랙트 주소 |
| `getReserves()` | `(uint112, uint112, uint32)` | (reserve0, reserve1, blockTimestampLast) |
| `price0CumulativeLast()` | `uint256` | TWAP 누적 가격 (token0) |
| `price1CumulativeLast()` | `uint256` | TWAP 누적 가격 (token1) |
| `kLast()` | `uint256` | 마지막 유동성 이벤트 시 k 값 |
| `initialize(token0, token1, feeCollector)` | — | 팩토리가 호출하는 초기화 |
| `mint(to)` | `uint256 liquidity` | 유동성 추가 → LP 발행 |
| `burn(to)` | `(uint256, uint256)` | LP 소각 → 기초 토큰 반환 |
| `swap(amount0Out, amount1Out, to, data)` | — | 스왑 실행 (+ flash loan 콜백) |
| `skim(to)` | — | 잔액-리저브 차이 전송 |
| `sync()` | — | 리저브를 현재 잔액으로 동기화 |
| `getAmountOut(tokenIn, amountIn)` | `uint256` | fee-aware 출력량 계산 (NadFun fee + 0.25% LP fee) |
| `getAmountIn(tokenOut, amountOut)` | `uint256` | fee-aware 입력량 역계산 (NadFun fee + 0.25% LP fee) |

---

## Fee-Aware Quote 규칙

기호:

```text
BPS = 10_000
LP_FEE_RATE = 25
feeRate = creatorFeeRate + dexProtocolFeeRate
```

Buy 방향은 `tokenIn == quoteToken`으로 판단한다.

| 방향 | 유저 입출력 | fee 위치 |
|------|-------------|----------|
| Buy | quote in, base out | input에서 LP fee + creator/protocol fee 차감 |
| Sell | base in, quote out | input에서 LP fee 차감, quote output에서 creator/protocol fee 차감 |

Sell에서 `getAmountOut()`은 유저가 받는 net quote output을 반환한다. `getAmountIn()`은 받고 싶은 net quote output을 입력받고, 내부에서 creator/protocol fee 전 gross quote output으로 올린 뒤 LP fee 역산 공식을 적용한다.

---

## 이벤트

| 이벤트 | 설명 |
|--------|------|
| `Mint(sender, amount0, amount1)` | 유동성 추가 시 |
| `Burn(sender, amount0, amount1, to)` | 유동성 제거 시 |
| `Swap(sender, amount0In, amount1In, amount0Out, amount1Out, to)` | 스왑 시 |
| `Sync(reserve0, reserve1)` | 리저브 업데이트 시 |
