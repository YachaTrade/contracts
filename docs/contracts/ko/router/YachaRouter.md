# YachaRouter

**경로:** `src/router/YachaRouter.sol`
**패턴:** UUPS 프록시
**상속:** `IYachaRouter`, `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

`YachaRouter`는 토큰 생성과 생명주기별 거래를 위한 사용자 진입점이다. 졸업 전에는 가격 계산과 실행을 `BondingCurve`에 위임한다. 졸업 후에는 정식 Uniswap V3 메타데이터만 허용하고 `V3SwapAdapter`를 통해 실행한다.

전체 파라미터와 함수 시그니처는 [IYachaRouter](../interfaces/IYachaRouter.md), 풀 콜백 인증은 [V3SwapAdapter](../adapters/V3SwapAdapter.md)를 참고한다.

## 초기화와 의존성

```solidity
initialize(
    address protocolManager,
    address bondingCurve,
    address tokenRegistry,
    address wrappedNative,
    address v3SwapAdapter,
    address quoterV2
)
```

여섯 주소는 모두 코드가 있어야 한다. adapter의 registry는 `tokenRegistry`와 같아야 하며 QuoterV2 factory는 adapter factory와 같아야 한다. 구현 컨트랙트의 생성자는 initializer를 비활성화한다.

| Getter | 용도 |
|---|---|
| `authority()` | ProtocolManager. 접근 정책, 활성 quote 검사, quote별 V3 수수료율, 현재 feeReceiver의 원천이다. |
| `bondingCurve()` | 졸업 전 상태, 실행, 생명주기 상태. |
| `tokenRegistry()` | quote 토큰, pool, 역방향 pool 매핑, DEX 유형, V3 fee tier. |
| `wrappedNative()` | 네이티브 경로가 허용하는 유일한 quote 토큰. |
| `v3SwapAdapter()` | 정식 V3 실행 의존성. |
| `quoterV2()` | 졸업 후 견적에만 사용하는 의존성. |

`setAuthority`는 항상 revert한다. UUPS 업그레이드는 고정된 ProtocolManager authority의 `restricted` 정책을 사용한다.

## 생명주기 라우팅

```text
YachaRouter
├─ curve.graduated == false
│  └─ BondingCurve 견적 및 실행
└─ curve.graduated == true
   ├─ TokenRegistry 메타데이터와 활성 quote 검증
   ├─ factory.getPool(token, quote, feeTier) 검증
   └─ V3SwapAdapter exactInput / exactOutput
```

졸업 후 metadata는 `DexType.UniswapV3`, `pair == pool`, 0이 아닌 fee tier, 올바른 역방향 registry 항목, canonical factory pool을 모두 만족해야 한다. Noncanonical metadata는 `InvalidV3Pool`로 거부한다.

ERC-20 경로는 활성 상태로 등록된 모든 quote 토큰을 지원한다. 네이티브 경로는 permit 또는 자산 이동 전에 `_requireNativeQuoteToken`을 실행하며 등록 quote가 `wrappedNative()`와 같아야 한다.

## 졸업 후 V3 수수료 네 가지 흐름

Router는 실행 시점에 `ProtocolManager.dexProtocolFeeRate(quoteToken)`과 `feeReceiver()`를 읽는다. 수수료율은 BPS이며 `10_000`보다 작아야 한다. 수수료는 항상 등록 quote 토큰으로 지불하며 `FullMath.mulDivRoundingUp`으로 올림한다.

이 Router V3 protocol fee는 BondingCurve 분기에 적용되지 않는다. BondingCurve는 별도의 curve protocol fee와 anti-sniping penalty를 적용한다. `V3SwapAdapter` 직접 호출에도 Router fee가 없다.

### Exact-input 매수

호출자의 `amountIn`은 프로토콜 수수료를 포함한 최대 quote 지출이다.

```text
protocolFeeMax = ceil(amountIn × rate / 10_000)
poolQuoteInMax = amountIn - protocolFeeMax
```

가격 한도 때문에 풀이 `poolQuoteInMax`보다 적게 소비하면 이미 한 번 올림한 최대 수수료를 실제 사용량에 비례해 계산한다.

```text
protocolFee = ceil(protocolFeeMax × poolQuoteIn / poolQuoteInMax)
quoteSpent   = poolQuoteIn + protocolFee
refund       = amountIn - quoteSpent
```

함수 반환값은 launch 토큰 출력이다. `Buy` 이벤트의 `amountIn`은 `quoteSpent`다.

### Exact-input 매도

Adapter는 최대 launch 토큰보다 적게 사용할 수 있고, Router 수수료 차감 전 quote 출력을 반환한다.

```text
protocolFee = ceil(quoteOutBeforeProtocolFee × rate / 10_000)
quoteOut    = quoteOutBeforeProtocolFee - protocolFee
```

사용하지 않은 launch 토큰은 환불한다. `amountOutMin`은 수수료 차감 후 `quoteOut`에 적용된다. 함수는 이 quote 순출력을 반환한다.

### Exact-output 매수

Adapter가 정확한 launch 토큰 출력을 위해 필요한 pool quote 입력을 반환하면 Router가 수수료를 역산한다.

```text
quoteInWithProtocolFee = ceil(poolQuoteIn × 10_000 / (10_000 - rate))
protocolFee            = quoteInWithProtocolFee - poolQuoteIn
```

총 입력은 `amountInMax` 이하여야 하며 나머지는 환불한다. 함수 반환값과 `Buy` 이벤트 입력은 수수료 포함 quote 입력이다.

### Exact-output 매도

요청 `amountOut`은 수신자가 수수료 차감 후 정확히 받을 quote 수량이다. Router는 풀에 더 큰 총 출력을 요청한다.

```text
quoteOutBeforeProtocolFee = ceil(amountOut × 10_000 / (10_000 - rate))
protocolFee               = quoteOutBeforeProtocolFee - amountOut
```

Adapter는 총 출력을 모두 전달해야 한다. 함수는 quote 출력이 아니라 실제 사용한 launch 토큰 입력을 반환하며 사용하지 않은 `amountInMax`를 환불한다.

## 부분 체결, 환불, allowance

Exact-input V3 호출은 방향별 유효 극한 가격을 사용한다. 유동성이 그 한도에서 끝나면 adapter의 실제 입력/출력이 기준이며 Router는 사용하지 않은 호출 입력을 환불한다.

Exact-output은 요청 출력을 정확히 채워야 하며 부분 출력은 revert한다. 사용자의 `amountInMax`와 `amountOutMin`은 항상 최종 상한/하한이다.

Router는 현재 호출의 최대량만 가져오고 pool 최대 입력만 adapter에 approve한 뒤 allowance를 0으로 되돌린다. 정확한 잔액 감소/증가 검사는 fee-on-transfer, 추가 차감, rebase, 수신 부족 토큰을 거부한다. Router나 adapter에 기존에 기부된 잔액은 sweep하지 않는다.

## 네이티브 경로

- 네이티브 생성/매수는 현재 호출에 필요한 quote만 래핑한다.
- 졸업 후 네이티브 매수는 `msg.value`를 래핑하고 계산된 현재 호출 환불액만 언래핑한다.
- 네이티브 매도는 Router가 WNATIVE를 받고 quote 수수료를 WNATIVE로 지급한 뒤 현재 호출 순출력만 언래핑하여 `to`로 보낸다.
- `receive()`는 설정된 wrapped-native 컨트랙트의 `withdraw` 전송만 허용한다.
- 언래핑, 환불, 수신자 전송이 실패하면 스왑, 수수료 지급, permit, 토큰 이동이 모두 원자적으로 되돌아간다.

기존 Router WNATIVE/네이티브 잔액은 환불 계산에서 제외된다.

## 견적

BondingCurve 전용 견적은 `view`다. 생명주기 통합 및 V3 전용 견적은 정식 QuoterV2가 Solidity view 컨트랙트가 아니므로 nonpayable이다. 프론트엔드는 `eth_call`로 시뮬레이션해야 한다.

V3 exact-input 견적은 실제 실행과 동일하게 매수 입력 또는 매도 출력 방향으로 수수료를 적용한다. Exact-output 매수는 Quoter의 pool 입력을 역산하고, 매도는 원하는 quote 순출력을 역산한 뒤 QuoterV2를 호출한다. Exact-output 견적은 `sqrtPriceLimitX96 = 0`을 사용하여 채울 수 없는 부분 출력을 거부한다. 실제 거래 함수는 QuoterV2를 호출하지 않는다.

## 스토리지와 크기

| 슬롯 | 필드 |
|---:|---|
| 0 | `_bondingCurve` |
| 1 | `_tokenRegistry` |
| 2 | `_wrappedNative` |
| 3 | `_v3SwapAdapter` |
| 4 | `_quoterV2` |

OpenZeppelin upgradeable 기반 상태는 namespaced storage를 사용한다. 현재 런타임은 23,916바이트로 EIP-170 한도 24,576바이트보다 660바이트 작다. 구현 변경 시 크기 회귀 테스트와 storage 호환성 검사를 다시 실행해야 한다.

## 배포 상태

`Deploy.s.sol`은 quote별 V3 설정, canonical pool 생성, `registerV3`, 2개 포지션의 영구 유동성, V3 라우팅, LP fee 수집까지 전체 canonical-V3 생명주기를 구성한다. V3SwapAdapter, 정식 QuoterV2, 6개 인자 YachaRouter 프록시를 배포한 뒤 해당 라우터에 BondingCurve router role을 부여한다.

현재 GIWA Sepolia 배포에서는 `DeployYachaRouter.s.sol`로 새 YachaRouter 프록시를 배포하고, `MigrateYachaRouterRole.s.sol`로 새 role 부여, Lens 재배포, 이전 router role 회수 순서로 전환했다. 이전 라우터의 permissionless 졸업 후 V3 진입점은 계속 호출될 수 있으므로 integration은 `README.md`의 현재 YachaRouter와 Lens 주소를 사용해야 한다.

`UpgradeYachaRouter.s.sol`은 앞으로 이미 배포된 YachaRouter 프록시를 업그레이드할 때만 사용한다. 새 프록시로 교체할 때는 staged deploy, grant, integration migration, revoke 순서를 따른다.

## 관련 문서

- [IYachaRouter](../interfaces/IYachaRouter.md)
- [V3SwapAdapter](../adapters/V3SwapAdapter.md)
- [아키텍처](../../../ARCHITECTURE.md)
- [프로토콜 흐름](../../../PROTOCOL_FLOW.ko.md)
