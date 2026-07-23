# IYachaRouter

**경로:** `src/interfaces/IYachaRouter.sol`
**유형:** 인터페이스

`IYachaRouter`는 토큰 생성과 생명주기별 거래를 위한 사용자 진입점이다. 졸업 전에는 `BondingCurve`를 호출하고, 졸업 후에는 정식 Uniswap V3 풀 메타데이터만 허용한다. ERC-20 경로는 등록되고 활성화된 여러 quote 토큰을 지원한다. 네이티브 경로는 Router에 설정된 wrapped-native 토큰만 지원한다.

구현과 수수료 공식은 [YachaRouter](../router/YachaRouter.md), 풀 콜백 경계는 [V3SwapAdapter](../adapters/V3SwapAdapter.md)를 참고한다.

## 파라미터 구조체

| 구조체 | 필드 |
|---|---|
| `CreateParams` | `string name`, `string symbol`, `string tokenURI`, `address quoteToken`, `IBondingCurve.VaultAllocation[] vaults`, `bytes32 salt`, `ITokenRegistry.DexType dexType`, `uint256 buyQuoteAmount`, `uint256 deadline` |
| `BuyParams` | `uint256 amountIn`, `uint256 amountOutMin`, `address token`, `address to`, `uint256 deadline` |
| `BuyWithNativeParams` | `uint256 amountOutMin`, `address token`, `address to`, `uint256 deadline` |
| `BuyWithPermitParams` | `uint256 amountIn`, `uint256 amountOutMin`, `uint256 amountAllowance`, `address token`, `address to`, `uint256 deadline`, `uint8 v`, `bytes32 r`, `bytes32 s` |
| `SellParams` | `uint256 amountIn`, `uint256 amountOutMin`, `address token`, `address to`, `uint256 deadline` |
| `SellToNativeParams` | `uint256 amountIn`, `uint256 amountOutMin`, `address token`, `address to`, `uint256 deadline` |
| `SellWithPermitParams` | `uint256 amountIn`, `uint256 amountOutMin`, `uint256 amountAllowance`, `address token`, `address to`, `uint256 deadline`, `uint8 v`, `bytes32 r`, `bytes32 s` |
| `SellToNativeWithPermitParams` | `uint256 amountIn`, `uint256 amountOutMin`, `uint256 amountAllowance`, `address token`, `address to`, `uint256 deadline`, `uint8 v`, `bytes32 r`, `bytes32 s` |
| `ExactOutBuyParams` | `uint256 amountInMax`, `uint256 amountOut`, `address token`, `address to`, `uint256 deadline` |
| `ExactOutBuyWithNativeParams` | `uint256 amountOut`, `address token`, `address to`, `uint256 deadline` |
| `ExactOutSellParams` | `uint256 amountInMax`, `uint256 amountOut`, `address token`, `address to`, `uint256 deadline` |
| `ExactOutSellToNativeParams` | `uint256 amountInMax`, `uint256 amountOut`, `address token`, `address to`, `uint256 deadline` |

`amountAllowance`는 EIP-2612 서명 허용량이며 `amountIn` 이상이어야 한다. 기존 allowance가 충분하면 Router는 `permit` 호출을 건너뛰므로, 제3자가 동일 서명을 먼저 제출해도 거래를 계속할 수 있다.

## 토큰 생성

| 함수 | 상태 변경 | 반환값 | 동작 |
|---|---|---|---|
| `create(CreateParams params)` | nonpayable | `(address token, uint256 tokenOut)` | 선택한 ERC-20 quote 토큰으로 `deployFee + buyQuoteAmount`를 가져와 `BondingCurve.create`를 호출한다. |
| `createWithNative(CreateParams params)` | payable | `(address token, uint256 tokenOut)` | 네이티브 화폐로 동일 작업을 수행한다. `quoteToken`은 `wrappedNative()`와 같아야 하며 초과 `msg.value`는 환불한다. |

생성 흐름은 한 transaction에서 Token clone 배포, canonical V3 pool 생성·등록, creator vault allocation 설정, curve state 저장을 수행한다.

## Exact-input 거래

| 함수 | 반환값 | Quote 자산 |
|---|---|---|
| `buy(BuyParams params)` | `uint256 amountOut` | 등록 ERC-20 quote 토큰 |
| `buyWithNative(BuyWithNativeParams params)` | `uint256 amountOut` | wrapped-native quote 토큰에 한해 네이티브 |
| `buyWithPermit(BuyWithPermitParams params)` | `uint256 amountOut` | EIP-2612 승인 ERC-20 quote 토큰 |
| `sell(SellParams params)` | `uint256 amountOut` | 등록 ERC-20 quote 토큰 |
| `sellToNative(SellToNativeParams params)` | `uint256 amountOut` | wrapped-native quote 토큰에 한해 네이티브 |
| `sellWithPermit(SellWithPermitParams params)` | `uint256 amountOut` | EIP-2612 승인 ERC-20 quote 토큰 |
| `sellToNativeWithPermit(SellToNativeWithPermitParams params)` | `uint256 amountOut` | EIP-2612 승인 네이티브 출력 |

`amountOutMin`은 Router V3 프로토콜 수수료 차감 후 출력에 적용된다. V3 exact-input은 가격 한도에서 부분 체결될 수 있으며, 실제 출력량을 반환하고 사용하지 않은 호출 단위 입력을 환불한다.

## Exact-output 거래

| 함수 | 반환 의미 |
|---|---|
| `exactOutBuy(ExactOutBuyParams params)` | V3 프로토콜 수수료를 포함해 사용한 quote 토큰 입력을 반환한다. 남은 `amountInMax`는 환불한다. |
| `exactOutBuyWithNative(ExactOutBuyWithNativeParams params)` | 수수료를 포함해 사용한 네이티브 입력을 반환하고 남은 `msg.value`를 환불한다. |
| `exactOutSell(ExactOutSellParams params)` | 수수료 차감 후 `amountOut` quote 토큰을 전달하기 위해 사용한 launch 토큰 입력을 반환한다. |
| `exactOutSellToNative(ExactOutSellToNativeParams params)` | 사용한 launch 토큰 입력을 반환한다. 졸업한 V3 경로는 수수료 차감 후 정확히 `amountOut` native를 전달하고, curve 경로는 정수 반올림으로 요청량 이상을 전달할 수 있다. |

졸업한 V3 exact-output은 부분 출력을 허용하지 않는다. 본딩 커브 경로는 정수 반올림으로 요청 output 이상을 반환할 수 있다. `amountInMax`는 호출자의 절대 상한이다.

## 견적 및 의존성 getter

| 함수 | 상태 변경 | 설명 |
|---|---|---|
| `isGraduated(address token)` | view | BondingCurve 졸업 상태를 읽는다. |
| `getAmountOut(address token, uint256 amountIn, bool isBuy)` | nonpayable | 졸업 전 BondingCurve, 졸업 후 QuoterV2를 사용하는 통합 견적. |
| `getAmountIn(address token, uint256 amountOut, bool isBuy)` | nonpayable | 생명주기별 필요 입력 견적. |
| `getBondingCurveAmountOut(address token, uint256 amountIn, bool isBuy)` | view | BondingCurve 전용 출력 견적. |
| `getBondingCurveAmountIn(address token, uint256 amountOut, bool isBuy)` | view | BondingCurve 전용 입력 견적. |
| `getDexAmountOut(address token, uint256 amountIn, bool isBuy)` | nonpayable | 정식 V3 exact-input 견적. |
| `getDexAmountIn(address token, uint256 amountOut, bool isBuy)` | nonpayable | 정식 V3 exact-output 견적. 전체 출력을 채울 수 없으면 revert한다. |
| `bondingCurve()` / `tokenRegistry()` | view | 설정된 생명주기/메타데이터 의존성. |
| `wrappedNative()` | view | 네이티브 경로에 사용할 WNATIVE 호환 토큰. |
| `v3SwapAdapter()` / `quoterV2()` | view | V3 실행/견적 의존성. |

정식 QuoterV2는 revert 기반으로 스왑을 시뮬레이션하므로 quote 함수는 Solidity `view`가 아니다. 클라이언트는 `eth_call`로 호출해야 한다. 실제 거래 함수는 QuoterV2를 호출하지 않는다.

## 이벤트

| 이벤트 | 의미 |
|---|---|
| `Create(token, creator)` | 호출자를 생성자로 기록한 토큰 생성. |
| `RouterBuy(buyer, token, amountIn, amountOut, graduated)` | 졸업 후 `amountIn`은 Router protocol fee 포함 입력이다. |
| `RouterSell(seller, token, amountIn, amountOut, graduated)` | 졸업 후 `amountIn`은 사용한 launch token, `amountOut`은 fee 차감 후 quote output이다. |

## 에러

- 금액/기한: `ExpiredDeadline`, `InvalidAmountIn`, `InvalidAmountOut`, `InsufficientOutput`, `ExcessiveInput`.
- 토큰/경로: `TokenNotFound`, `TokenNotGraduated`, `InvalidV3Pool`, `InvalidV3Quote`, `InvalidNativeQuoteToken`.
- 수신/승인: `InvalidRecipient`, `InvalidAllowance`, `NativeTransferFailed`, `UnexpectedNative`.
- 설정/회계: `InvalidDependency`, `InvalidDexFeeRate`, `InvalidBalanceDelta`.

`TokenNotGraduated`는 선택한 함수가 졸업된 token을 요구할 때 사용한다.

## 관련 문서

- [YachaRouter](../router/YachaRouter.md)
- [V3SwapAdapter](../adapters/V3SwapAdapter.md)
- [프로토콜 흐름](../../../PROTOCOL_FLOW.ko.md)
