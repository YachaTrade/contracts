# INadFunRouter

**Path:** `src/interfaces/INadFunRouter.sol`
**Type:** Interface

통합 라우터 인터페이스. 졸업 전(BondingCurve) / 졸업 후(DEX) 거래를 단일 진입점으로 제공. 슬리피지 보호, 데드라인, 네이티브 토큰 래핑, EIP-2612 Permit 등 편의 기능 포함.

---

## Struct: 토큰 생성

| 구조체 | 필드 | 설명 |
|--------|------|------|
| `CreateParams` | `name`, `symbol`, `quoteToken`, `creatorFeeRate`, `vaults[]`, `salt`, `dexType`, `buyQuoteAmount`, `deadline` | 토큰 생성 파라미터. `buyQuoteAmount > 0`이면 초기 매수 동시 실행 |

## Struct: ExactIn 매수

| 구조체 | 설명 |
|--------|------|
| `BuyParams` | ERC20 quoteToken으로 매수 (`token`, `amountIn`, `amountOutMin`, `deadline`) |
| `BuyWithNativeParams` | 네이티브 토큰으로 매수 (`token`, `amountOutMin`, `deadline`) |
| `BuyWithPermitParams` | Permit으로 approve 없이 매수 (+ `v`, `r`, `s`) |

## Struct: ExactIn 매도

| 구조체 | 설명 |
|--------|------|
| `SellParams` | ERC20 quoteToken으로 수령 매도 (`token`, `amountIn`, `amountOutMin`, `deadline`) |
| `SellToNativeParams` | 네이티브 토큰으로 수령 매도 |
| `SellWithPermitParams` | Permit으로 approve 없이 매도 |
| `SellToNativeWithPermitParams` | Permit + 네이티브 수령 매도 |

## Struct: ExactOut

| 구조체 | 설명 |
|--------|------|
| `ExactOutBuyParams` | 정확한 출력량 매수 (`amountOut`, `amountInMax`) |
| `ExactOutBuyWithNativeParams` | 네이티브로 정확한 출력량 매수 |
| `ExactOutSellParams` | 정확한 출력량 매도 (`amountInMax`, `amountOut`) |
| `ExactOutSellToNativeParams` | 네이티브로 정확한 출력량 매도 |

---

## 함수 시그니처

### Create

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `create(params)` | `(address token, uint256 tokenOut)` | ERC20으로 토큰 생성 (+ 초기 매수) |
| `createWithNative(params)` | `(address token, uint256 tokenOut)` | 네이티브로 토큰 생성 (+ 초기 매수) |

### ExactIn Buy

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `buy(params)` | `uint256 amountOut` | ERC20으로 매수 |
| `buyWithNative(params)` | `uint256 amountOut` | 네이티브로 매수 |
| `buyWithPermit(params)` | `uint256 amountOut` | Permit으로 매수 |

### ExactIn Sell

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `sell(params)` | `uint256 amountOut` | ERC20으로 매도 |
| `sellToNative(params)` | `uint256 amountOut` | 네이티브로 수령 매도 |
| `sellWithPermit(params)` | `uint256 amountOut` | Permit으로 매도 |
| `sellToNativeWithPermit(params)` | `uint256 amountOut` | Permit + 네이티브 매도 |

### ExactOut Buy

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `exactOutBuy(params)` | `uint256 amountIn` | 정확한 출력량 매수 |
| `exactOutBuyWithNative(params)` | `uint256 amountIn` | 네이티브로 정확한 출력량 매수 |

### ExactOut Sell

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `exactOutSell(params)` | `uint256 amountOut` | 정확한 출력량 매도 |
| `exactOutSellToNative(params)` | `uint256 amountOut` | 네이티브로 정확한 출력량 매도 |

### Views

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `isGraduated(token)` | `bool` | 졸업 여부 조회 |
| `getBondingCurveAmountOut(token, amountIn, isBuy)` | `uint256` | 본딩 커브 예상 출력량 |
| `getBondingCurveAmountIn(token, amountOut, isBuy)` | `uint256` | 본딩 커브 필요 입력량 |
| `getDexAmountOut(token, amountIn, isBuy)` | `uint256` | 등록된 DEX adapter 기준 예상 출력량 |
| `getDexAmountIn(token, amountOut, isBuy)` | `uint256` | 등록된 DEX adapter 기준 필요 입력량 |
| `bondingCurve()` | `address` | BondingCurve 주소 |
| `tokenRegistry()` | `address` | TokenRegistry 주소 |
| `wrappedNative()` | `address` | Wrapped native 토큰 주소 |

---

## 이벤트

| 이벤트 | 설명 |
|--------|------|
| `Buy(buyer, token, amountIn, amountOut, graduated)` | 매수 시. `graduated` 플래그로 본딩커브/DEX 구분 |
| `Sell(seller, token, amountIn, amountOut, graduated)` | 매도 시 |
| `Create(token, creator)` | 토큰 생성 시 |

---

## 에러

| 에러 | 설명 |
|------|------|
| `ExpiredDeadline()` | 만료된 데드라인 |
| `InvalidAmountIn()` | 유효하지 않은 입력량 |
| `InvalidAmountOut()` | 유효하지 않은 출력량 |
| `InsufficientOutput()` | 슬리피지 한도 초과 (출력 부족) |
| `ExcessiveInput()` | 입력 한도 초과 |
| `TokenNotFound()` | 등록되지 않은 토큰 |
| `NativeTransferFailed()` | 네이티브 토큰 전송 실패 |
