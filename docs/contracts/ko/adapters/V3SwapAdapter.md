# V3SwapAdapter

**경로:** `src/adapters/V3SwapAdapter.sol`
**패턴:** factory와 registry를 immutable로 보관하는 비업그레이드 컨트랙트

`V3SwapAdapter`는 launch 토큰에 등록된 정식 Uniswap V3 단일 풀에서 exact-input/exact-output 스왑을 실행한다. Router 프로토콜 수수료를 부과하지 않고, 관리자 출금 API가 없으며, 실제 콜백 지급액을 호출자에게서 풀로 직접 가져간다.

## 생성자와 getter

```solidity
constructor(address factoryAddress, address tokenRegistryAddress)
function factory() external view returns (address)
function tokenRegistry() external view returns (address)
```

두 생성자 인자는 모두 코드가 있어야 하며 주소는 immutable이다.

## 파라미터와 함수

| 구조체 | 필드 |
|---|---|
| `ExactInputParams` | `address token`, `address tokenIn`, `uint256 amountIn`, `uint256 amountOutMin`, `address recipient`, `uint160 sqrtPriceLimitX96`, `uint256 deadline` |
| `ExactOutputParams` | `address token`, `address tokenIn`, `uint256 amountOut`, `uint256 amountInMax`, `address recipient`, `uint160 sqrtPriceLimitX96`, `uint256 deadline` |

`token`은 `TokenRegistry.TokenInfo`를 조회할 launch 토큰이다. `tokenIn`은 해당 launch 토큰 또는 등록된 quote 토큰이어야 하며 반대편 자산이 `tokenOut`이 된다.

| 함수 | 반환값 | 동작 |
|---|---|---|
| `exactInput(params)` | `(uint256 amountIn, uint256 amountOut)` | `amountIn` 이하를 스왑한다. 실제 출력이 `amountOutMin` 이상이면 가격 한도 부분 체결을 허용한다. 실제 사용 입력과 수신 출력을 반환한다. |
| `exactOutput(params)` | `(uint256 amountIn, uint256 amountOut)` | `amountInMax` 이하로 정확히 `amountOut`을 요청한다. 부분 출력은 revert한다. |
| `uniswapV3SwapCallback(amount0Delta, amount1Delta, data)` | 없음 | 인증된 단일 adapter 스왑이 활성 상태일 때만 허용되는 V3 콜백이다. |

호출자는 가능한 입력량을 adapter에 approve해야 한다. 출력은 풀이 `recipient`에게 직접 보낸다. 직접 호출에는 Router 수수료가 없지만, 정식 풀의 Uniswap V3 LP 수수료는 그대로 적용된다.

## 정식 풀 검증

스왑 전과 콜백 중에 다음을 모두 확인한다.

- `TokenInfo.dexType == UniswapV3`;
- `pair == pool`이며 풀 주소에 코드가 존재;
- launch/quote 토큰이 정렬된 `token0`/`token1`과 일치;
- 풀 수수료가 등록 `feeTier`와 일치;
- `pool.factory()`가 immutable factory와 일치;
- `factory.getPool(token, quoteToken, feeTier)`가 동일 풀 반환;
- `TokenRegistry.getTokenByPool(pool)`이 동일 launch 토큰 반환.

호출 중 이 관계가 변경되어도 전체 트랜잭션이 revert한다.

## 콜백 및 회계 방어

각 스왑은 풀, payer, 입력/출력 자산, 최대 입력, nonce가 결합된 콜백 데이터 해시를 active context에 기록한다. 콜백은 caller와 데이터 해시를 먼저 검증하고, 정식 메타데이터를 다시 확인한 뒤, 정확히 한쪽만 양수인 지급 delta와 저장된 최대 입력을 검사한다.

`safeTransferFrom(payer, pool, amountOwed)` 전에 active context를 삭제하므로 같은 풀 호출 안에서도 재사용할 수 없다. 별도 재진입 플래그는 중첩 `exactInput`/`exactOutput`을 차단한다.

풀이 반환한 뒤에는 콜백이 context를 소비했는지, delta 부호가 올바른지, payer 입력 감소와 recipient 출력 증가가 반환값과 정확히 같은지 확인한다. 이 검사는 fee-on-transfer, 추가 차감, rebase, 수신 부족 토큰을 거부한다. adapter에 미리 기부된 잔액은 지급이나 환불에 사용하지 않는다.

## 스토리지

| 스토리지 | 슬롯 | 용도 |
|---|---:|---|
| `_activeSwap` | 0–5 | 일시적인 인증 콜백 context |
| `_swapNonce` | 6 | 콜백 데이터를 현재 스왑에 결합 |
| `_entered` | 7 | 로컬 재진입 방지 플래그 |

factory와 registry는 bytecode immutable이며 스토리지 슬롯이 아니다.

## 에러

- 입력/한도: `ExpiredDeadline`, `InvalidAmountIn`, `InvalidAmountOut`, `InvalidPriceLimit`, `InvalidRecipient`, `InsufficientOutput`, `ExcessiveCallbackAmount`.
- registry/pool: `InvalidFactory`, `InvalidRegistry`, `InvalidPool`, `InvalidTokenIn`.
- 콜백 생명주기: `NoActiveSwap`, `InvalidCallback`, `CallbackNotConsumed`, `ReentrantCall`.
- 토큰 회계: `InvalidBalanceDelta`.

## 관련 문서

- [IGiwaRouter](../interfaces/IGiwaRouter.md)
- [GiwaRouter](../router/GiwaRouter.md)
- [프로토콜 흐름](../../../PROTOCOL_FLOW.ko.md)
