# NadFunRouter

**Path:** `src/router/NadFunRouter.sol`
**Pattern:** UUPS 업그레이드
**Inheritance:** `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

모든 토큰 거래를 위한 통합 라우터. 단일 진입점으로 졸업 전에는 BondingCurve, 졸업 후에는 DEX 거래를 직접 처리 — 중간 서브라우터 없음. 네이티브 래핑, 수수료 계산, 슬리피지 보호를 모두 이 단일 진입점에서 처리.

---

## 의존성

| 의존성 | 용도 |
|--------|------|
| `IBondingCurve` | 졸업 전 커브 상태 & 거래 |
| `ITokenRegistry` | 졸업 후 pair/adapter 조회 |
| `IDexAdapter` | DEX 스왑 실행 (dexType별) |
| `IProtocolManager` | 수수료율, 수수료 수신자, 배포 수수료 |
| `IWrappedNative` | 네이티브 화폐 래핑/언래핑 (WMON) |
| `FixedPointMathLib` | 정밀 수수료 계산 (mulDivUp) |
| `BPS` 상수 | 베이시스 포인트 분모 (10000) |

---

## 상태 변수

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `_bondingCurve` | `IBondingCurve` | private | 졸업 전 거래용 BondingCurve 참조 |
| `_tokenRegistry` | `ITokenRegistry` | private | 졸업 후 pair/adapter 조회용 TokenRegistry (slot 1, 기존 `_dexRouter`) |
| `_wrappedNative` | `IWrappedNative` | private | 네이티브 화폐 래핑/언래핑용 WMON |
| `__gap_slot3` | `uint256` | private | UUPS 레이아웃 보존용 스토리지 갭 (기존 `_bondingCurveRouter`) |

---

## 함수

### ExactIn 매수

| 함수 | 설명 |
|------|------|
| `buy(BuyParams)` | ERC20 quote 토큰으로 매수 |
| `buyWithNative(BuyWithNativeParams)` | 네이티브 화폐로 매수 (자동 래핑) |
| `buyWithPermit(BuyWithPermitParams)` | EIP-2612 가스리스 승인으로 매수 |

### ExactIn 매도

| 함수 | 설명 |
|------|------|
| `sell(SellParams)` | ERC20 quote 토큰으로 수령하는 매도 |
| `sellToNative(SellToNativeParams)` | 네이티브 화폐로 수령하는 매도 (자동 언래핑) |
| `sellWithPermit(SellWithPermitParams)` | EIP-2612 permit을 사용한 매도 |
| `sellToNativeWithPermit(SellToNativeWithPermitParams)` | permit을 사용하여 네이티브로 수령하는 매도 |

### ExactOut 매수

| 함수 | 설명 |
|------|------|
| `exactOutBuy(ExactOutBuyParams)` | 정확한 토큰 수량 매수, 미사용 quote 환불 |
| `exactOutBuyWithNative(ExactOutBuyWithNativeParams)` | 네이티브로 정확한 토큰 수량 매수, 미사용분 환불 |

### ExactOut 매도

| 함수 | 설명 |
|------|------|
| `exactOutSell(ExactOutSellParams)` | 정확한 quote 수량 수령 매도, 미사용 토큰 환불 |
| `exactOutSellToNative(ExactOutSellToNativeParams)` | 정확한 네이티브 수량 수령 매도, 미사용 토큰 환불 |

### 생성(Create) 함수

| 함수 | 설명 |
|------|------|
| `create(CreateParams) returns (address token, uint256 tokenOut)` | 토큰 생성 (`buyQuoteAmount > 0`이면 초기 매수 포함) |
| `createWithNative(CreateParams) payable returns (address token, uint256 tokenOut)` | 네이티브 MON으로 동일 (래핑 -> 생성 -> 잔여 환불) |

**CreateParams:** `name, symbol, tokenURI, quoteToken, creatorFeeRate, vaults, salt, dexType, buyQuoteAmount, deadline`

**핵심 설계:**
- `BondingCurve.create()`는 `ROUTER_ROLE` 필요 — NadFunRouter가 토큰 생성의 유일한 진입점
- 단일 `create()` 함수 — `buyQuoteAmount > 0`이면 sniping 면제 초기 매수 자동 실행
- NadFunRouter가 BondingCurve를 직접 호출 (서브라우터 경유 없음)
- `creator: msg.sender`를 전달하여 실제 사용자가 토큰 생성자로 기록됨
- 슬리피지 보호 불필요 — 첫 매수는 원자적 (가격 확정적)

### 조회

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `isGraduated(token)` | `bool` | 토큰이 DEX로 졸업했는지 여부 |
| `getBondingCurveAmountOut(token, amountIn, isBuy)` | `uint256` | 졸업 전 출력량 (모든 수수료 포함: 프로토콜 수수료 + 스나이핑 페널티 + 크리에이터 수수료) |
| `getBondingCurveAmountIn(token, amountOut, isBuy)` | `uint256` | 졸업 전 필요 입력량 (모든 수수료 포함) |
| `getDexAmountOut(token, amountIn, isBuy)` | `uint256` | 졸업 후 출력량. pair 없으면 `TokenNotGraduated` revert |
| `getDexAmountIn(token, amountOut, isBuy)` | `uint256` | 졸업 후 필요 입력량. pair 없으면 `TokenNotGraduated` revert |
| `bondingCurve()` | `address` | BondingCurve 주소 |
| `tokenRegistry()` | `address` | TokenRegistry 주소 |
| `wrappedNative()` | `address` | WMON 주소 |
| `authority()` | `address` | ProtocolManager 주소 (AccessManagedUpgradeable에서 상속) |

### 관리자

| 함수 | 접근 | 설명 |
|------|------|------|
| `_authorizeUpgrade(address)` | restricted | UUPS 업그레이드 권한 |
| `setAuthority(address)` | — | 항상 revert (초기화 후 authority 변경 불가) |

---

## 라우팅 로직

모든 buy/sell 함수는 `curve.graduated`를 확인:
- **미졸업**: BondingCurve에 대해 직접 거래 실행 (잔액 감지 패턴). 내부 헬퍼: `_bondingCurveBuy`, `_bondingCurveSell`, `_bondingCurveExactOutBuy`, `_bondingCurveExactOutSell`.
- **졸업 완료**: `ITokenRegistry`에서 조회한 `IDexAdapter`를 통해 DEX pair에 직접 거래 실행. 내부 헬퍼: `_dexBuy`, `_dexSell`, `_dexExactOutBuy`, `_dexExactOutSell`.

슬리피지 보호는 NadFunRouter 레벨에서 적용; 내부 호출 시 `minOut=0` / `deadline=block.timestamp` 전달.

---

## 이벤트

| 이벤트 | 매개변수 |
|--------|----------|
| `Buy` | `address indexed buyer, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated` |
| `Sell` | `address indexed seller, address indexed token, uint256 amountIn, uint256 amountOut, bool graduated` |
| `Create` | `address indexed token, address indexed creator` |

## 에러

| 에러 | 설명 |
|------|------|
| `ExpiredDeadline()` | 트랜잭션 유효기한 만료 |
| `InvalidAmountIn()` | 입력량이 0 |
| `InvalidAmountOut()` | 출력량이 0 |
| `InsufficientOutput()` | 출력이 최소값 미만 (슬리피지 초과) |
| `ExcessiveInput()` | 입력이 최대값 초과 (ExactOut) |
| `TokenNotFound()` | BondingCurve에 등록되지 않은 토큰 |
| `TokenNotGraduated()` | DEX pair가 없는 토큰 (DEX 조회/스왑 함수에서 사용) |
| `NativeTransferFailed()` | 네이티브 화폐 전송 실패 |
