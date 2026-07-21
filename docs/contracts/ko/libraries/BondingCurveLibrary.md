# BondingCurveLibrary

> `src/libraries/BondingCurveLibrary.sol` — 순수 라이브러리 (상태 비저장)

상태 비저장(stateless) 상수곱 AMM 수학 라이브러리. 불변량 `k`와 리저브 값을 기반으로 상수곱 커브의 입출력 계산을 제공.

## 설계

BondingCurveLibrary는 스토리지가 없으며 모든 함수가 `pure`. BondingCurve 컨트랙트가 `virtualQuoteReserve`와 `virtualTokenReserve`를 상태로 저장하고, 스왑 계산을 위해 이 라이브러리에 전달.

본딩 커브뿐만 아니라 모든 상수곱 커브에서 동작. 올림 나눗셈을 사용하여 트레이더에게 유리한 반올림으로 프로토콜이 가치를 잃지 않도록 보장.

## 상수

| 이름 | 값 | 설명 |
|------|---|------|
| *(없음)* | — | 상수 없음; `k`는 매개변수로 전달 (커브 생성 시 `QuoteConfig`에서 설정) |

## 함수

| 함수 | 매개변수 | 반환값 | 설명 |
|------|---------|--------|------|
| `getAmountOut(amountIn, k, reserveIn, reserveOut)` | `uint256, uint256, uint256, uint256` | `uint256` | 주어진 입력량에 대한 출력량 (분모에 올림 적용) |
| `getAmountIn(amountOut, k, reserveIn, reserveOut)` | `uint256, uint256, uint256, uint256` | `uint256` | 원하는 출력량에 필요한 입력량 (올림) |
| `ceilDiv(a, b)` | `uint256, uint256` | `uint256` | 올림 나눗셈 헬퍼 |

### getAmountOut

주어진 입력량에 대해 수신할 출력 토큰 수량을 계산:

```
amountOut = reserveOut - ceil(k / (reserveIn + amountIn))
```

`k / (reserveIn + amountIn)`에 올림 나눗셈을 적용하여 `amountOut`이 약간 적어지도록 하여 프로토콜을 보호.

### getAmountIn

특정 출력량을 받기 위해 필요한 입력 토큰 수량을 계산:

```
newReserveIn = ceil(k / (reserveOut - amountOut))
amountIn = newReserveIn - reserveIn
```

올림 나눗셈을 적용하여 `amountIn`이 약간 많아지도록 하여 프로토콜을 보호.

### ceilDiv

```
ceilDiv(a, b) = (a + b - 1) / b
```

표준 올림 나눗셈. 절삭 대신 올림.

## BondingCurve에서의 사용

```solidity
// 매수: 사용자가 quoteToken을 보내고 token을 수신
uint256 tokenOut = BondingCurveLibrary.getAmountOut(
    quoteAmountIn, k, virtualQuoteReserve, virtualTokenReserve
);

// 매도: 사용자가 token을 보내고 quoteToken을 수신
uint256 quoteOut = BondingCurveLibrary.getAmountOut(
    tokenAmountIn, k, virtualTokenReserve, virtualQuoteReserve
);
```
