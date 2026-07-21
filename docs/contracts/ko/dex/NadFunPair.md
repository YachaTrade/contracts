# NadFunPair

**Path:** `src/dex/NadFunPair.sol`
**Pattern:** EIP-1167 Clone (NadFunFactory가 생성)
**Inheritance:** `INadFunPair`, `ERC20PermitUpgradeable`

NadFun 전용 V2 AMM 페어. Uniswap V2 Pair 기반이나, NadFun 프로토콜 수수료 수집을 위한 FeeCollector 연동과 fee-aware AMM view 함수가 추가됨. LP 토큰("NadFun LP", "NADLP")을 자체 발행.

---

## 상수

| 상수 | 값 | 설명 |
|------|---|------|
| `MINIMUM_LIQUIDITY` | `10**3` | 최초 유동성 공급 시 0xdead로 잠기는 최소 LP |
| `LP_FEE_RATE` | `25` | 0.25% LP 수수료 (BPS) |

---

## 상태 변수

| 변수 | 타입 | 설명 |
|------|------|------|
| `factory` | `address` | 이 페어를 배포한 NadFunFactory |
| `token0` | `address` | 정렬된 첫 번째 토큰 |
| `token1` | `address` | 정렬된 두 번째 토큰 |
| `feeCollector` | `address` | 수수료 수집 컨트랙트 |
| `_reserve0` | `uint112` | token0 리저브 |
| `_reserve1` | `uint112` | token1 리저브 |
| `_blockTimestampLast` | `uint32` | 마지막 업데이트 블록 타임스탬프 |
| `price0CumulativeLast` | `uint256` | TWAP 누적 가격 (token0 기준) |
| `price1CumulativeLast` | `uint256` | TWAP 누적 가격 (token1 기준) |
| `kLast` | `uint256` | 마지막 유동성 이벤트 시점의 k 값 (프로토콜 수수료 계산용) |

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `initialize(factory, token0, token1, feeCollector)` | external, initializer | factory가 clone 배포 후 1회 호출. factory 주소, 토큰 주소, FeeCollector 설정 |
| `getReserves()` | view | (reserve0, reserve1, blockTimestampLast) 반환 |
| `mint(to)` | external, lock | 유동성 추가 → LP 토큰 발행 |
| `burn(to)` | external, lock | LP 소각 → 기초 토큰 반환 |
| `swap(amount0Out, amount1Out, to, data)` | external | 스왑 실행 + fee 수집 + k invariant 검증 |
| `skim(to)` | external, lock | 잔액과 리저브 차이를 to로 전송 |
| `sync()` | external, lock | 리저브를 현재 잔액으로 동기화 |
| `getAmountOut(tokenIn, amountIn)` | view | fee-aware 출력량 계산 (NadFun fee + 0.25% LP fee 포함) |
| `getAmountIn(tokenOut, amountOut)` | view | fee-aware 입력량 역계산 |

---

## 이벤트

| 이벤트 | 설명 |
|--------|------|
| `Mint(sender, amount0, amount1)` | 유동성 추가 시 |
| `Burn(sender, amount0, amount1, to)` | 유동성 제거 시 |
| `Swap(sender, amount0In, amount1In, amount0Out, amount1Out, to)` | 스왑 실행 시 |
| `Sync(reserve0, reserve1)` | 리저브 업데이트 시 |

---

## 핵심 설계: Fee-Aware AMM

### 스왑 수수료 수집 흐름

```
swap() 호출
  ├─ _swap() [lock]
  │   ├─ 잔액 변화량(balance delta)으로 amountIn 감지
  │   ├─ 출력 토큰 전송
  │   ├─ flash loan 콜백 (data.length > 0이면 nadFunCall)
  │   ├─ _collectFee(): FeeCollector에 수수료 전송 + collectFee() 호출
  │   │   ├─ Buy (quoteIn → baseOut): fee = quoteIn * feeRate / BPS
  │   │   └─ Sell (baseIn → quoteOut): fee = quoteOut * feeRate / (BPS - LP_FEE_RATE - feeRate)
  │   ├─ K invariant 검증 (0.25% LP 수수료 반영)
  │   └─ _update(): 리저브 + TWAP 갱신
```

### getAmountOut / getAmountIn

NadFunPair가 직접 fee-aware AMM 수학을 구현:
- **Buy** (quoteIn → baseOut): creator + DEX protocol fee가 입력에서 차감 후 0.25% LP 수수료 적용
- **Sell** (baseIn → quoteOut): 0.25% LP 수수료 적용 후 creator + DEX protocol fee를 출력에서 차감
- fee 정보는 `FeeCollector.getFeeConfig(address(this))`로 `FeeConfig` 전체를 조회하고, `feeRate = creatorFeeRate + dexProtocolFeeRate`는 pair가 로컬에서 합산

기호:

| 기호 | 의미 |
|------|------|
| `BPS` | `10_000` |
| `LP_FEE_RATE` | `25` (0.25%) |
| `feeRate` | `creatorFeeRate + dexProtocolFeeRate` |
| `quoteToken` | creator/protocol fee가 부과되는 quote asset |

Buy 여부는 `tokenIn == quoteToken`으로 판단한다.

#### `getAmountOut(tokenIn, amountIn)`

Buy:

```text
totalFeeRate = LP_FEE_RATE + feeRate
amountInWithFee = amountIn * (BPS - totalFeeRate)
amountOut = amountInWithFee * reserveOut / (reserveIn * BPS + amountInWithFee)
```

Sell:

```text
amountInWithLpFee = amountIn * (BPS - LP_FEE_RATE)
grossQuoteOut = amountInWithLpFee * reserveOut / (reserveIn * BPS + amountInWithLpFee)
amountOut = grossQuoteOut - ceil(grossQuoteOut * feeRate / (BPS - LP_FEE_RATE))
```

Sell에서 반환되는 `amountOut`은 유저가 받는 net quote amount다. 실제 `swap()` 중 `_collectFee()`는 아래 공식으로 quote fee를 pair에서 `FeeCollector`로 전송한다.

```text
quoteFee = netQuoteOut * feeRate / (BPS - LP_FEE_RATE - feeRate)
```

즉 sell에서는 LP fee가 반영된 gross quote output에서 creator/protocol fee를 떼고, 나머지를 유저에게 주는 구조다.

#### `getAmountIn(tokenOut, amountOut)`

Buy:

```text
totalFeeRate = LP_FEE_RATE + feeRate
amountIn = ceil(reserveIn * BPS * amountOut / ((BPS - totalFeeRate) * (reserveOut - amountOut)))
```

Sell:

```text
grossQuoteOut = amountOut
if feeRate > 0:
  grossQuoteOut = ceil(amountOut * (BPS - LP_FEE_RATE) / (BPS - LP_FEE_RATE - feeRate))

amountIn = ceil(reserveIn * BPS * grossQuoteOut / ((BPS - LP_FEE_RATE) * (reserveOut - grossQuoteOut)))
```

Sell에서 caller가 넣는 `amountOut`은 받고 싶은 net quote amount다. Pair는 먼저 creator/protocol fee 전의 gross quote output으로 올려 계산한 뒤, LP fee가 반영된 Uniswap V2 역산 공식을 적용한다.

### 프로토콜 수수료 민팅 (_mintFee)

`feeTo != address(0)`이면 유동성 이벤트(mint/burn) 시 k 성장분의 1/5을 LP 토큰으로 `feeTo`에 민팅. 0.25% LP fee에서 약 0.05%의 protocol LP fee에 해당한다.
