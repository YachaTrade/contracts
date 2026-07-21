# NadFunRouter02

**Path:** `src/router/NadFunRouter02.sol`
**Pattern:** UUPS 업그레이드
**Inheritance:** `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

졸업한 NadFunPair를 위한 독립형 UniswapV2Router02 호환 페리퍼리. 유동성 관리(추가/제거, permit 지원)와 수수료 인식 멀티홉 스왑을 처리한다. EIP-170 24KB 컨트랙트 크기 제한을 준수하기 위해 `NadFunRouter`에서 분리된 독립 컨트랙트다. `NadFunRouter`(본딩커브 라이프사이클 + 매수/매도)는 변경 없이 그대로 유지되며, 졸업 전 거래와 토큰 생성의 유일한 진입점이다.

`WETH()`는 WMON 주소를 반환한다. `...ETH` / `WETH()` 네이밍은 UniswapV2Router02 ABI를 기대하는 aggregator와 SDK(Sushi/PancakeSwap 관례)와의 드롭인 호환성을 위해 그대로 유지한다.

---

## 의존성

| 의존성 | 용도 |
|--------|------|
| `INadFunFactory` | `getPair`를 통한 pair 조회; 퍼미션리스 `createPair` |
| `INadFunPair` | LP 민팅/소각; 수수료 인식 view 함수 `getAmountOut`/`getAmountIn` |
| `IWrappedNative` | `...ETH` 함수에서 WMON 래핑/언래핑 |
| `NadFunLibrary` | `pairFor`(`factory.getPair` 경유 조회), `quote`, `getAmountsOut`, `getAmountsIn` |

---

## 상태 변수

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `_factory` | `INadFunFactory` | private | pair 조회 및 생성을 위한 NadFunFactory 참조 |
| `_wrappedNative` | `IWrappedNative` | private | WMON 주소; `WETH()`가 반환 |

---

## 함수

### 초기화

| 함수 | 설명 |
|------|------|
| `initialize(protocolManager, factory, wmon)` | 프록시 초기화. `_factory`와 `_wrappedNative` 설정; `AccessManagedUpgradeable`을 `protocolManager`에 연결 |

### 유동성

#### Pair 생성

| 함수 | 설명 |
|------|------|
| `createPair(tokenA, tokenB) returns (address pair)` | `factory.createPair`를 통한 퍼미션리스 pair 생성. 역할이나 멀티시그 불필요; 누구나 호출 가능 |

#### 유동성 추가

| 함수 | 설명 |
|------|------|
| `addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline) returns (amountA, amountB, liquidity)` | ERC20/ERC20 유동성 추가. 현재 리저브 기준 최적 수량 계산, 최솟값 강제, LP 토큰을 `to`에 민팅 |
| `addLiquidityETH(token, amountTokenDesired, amountTokenMin, amountETHMin, to, deadline) returns (amountToken, amountETH, liquidity)` payable | 토큰/네이티브 유동성 추가. `msg.value`를 WMON으로 래핑, 최적 비율 계산, 미사용 네이티브 환불 |

#### 유동성 제거

| 함수 | 설명 |
|------|------|
| `removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline) returns (amountA, amountB)` | LP 토큰 소각, ERC20/ERC20 회수. 출력 최솟값 강제 |
| `removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline) returns (amountToken, amountETH)` | LP 토큰 소각, 토큰 + 네이티브 회수. WMON을 네이티브로 언래핑 후 전달 |
| `removeLiquidityWithPermit(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline, approveMax, v, r, s)` | LP 토큰 permit 승인 후 `removeLiquidity` 실행 |
| `removeLiquidityETHWithPermit(token, liquidity, amountTokenMin, amountETHMin, to, deadline, approveMax, v, r, s)` | LP 토큰 permit 승인 후 `removeLiquidityETH` 실행 |
| `removeLiquidityETHSupportingFeeOnTransferTokens(token, liquidity, amountTokenMin, amountETHMin, to, deadline) returns (amountETH)` | base 토큰이 fee-on-transfer를 적용할 수 있는 경우의 유동성 제거; 실제 수신 잔액을 측정 |
| `removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(token, liquidity, amountTokenMin, amountETHMin, to, deadline, approveMax, v, r, s)` | 위 함수의 permit 변형 |

**졸업 전 가드:** NadFun의 `Token.sol`은 졸업 전 pair 주소로의 토큰 전송을 차단한다(`TransferToPairBeforeGraduation` 에러). 따라서 졸업 전 pair에 유동성을 추가하면 토큰 레이어에서 revert되며, 라우터 레벨의 별도 가드가 필요 없다.

### 스왑

모든 스왑 함수는 멀티홉 라우팅을 위한 `path[]` 토큰 주소 배열을 받는다. 각 홉은 해당 토큰 쌍의 NadFunPair를 통해 라우팅된다.

**수수료 인식:** `getAmountsOut`/`getAmountsIn`은 홉별로 `NadFunPair.getAmountOut`/`getAmountIn`에 위임하여 LP 수수료, 프로토콜 수수료, 크리에이터 수수료(매수/매도 비대칭)를 모두 반영한다. 단순 0.3% 고정 수수료로 계산하면 pair의 k 불변식 검사를 통과하지 못해 스왑이 revert된다.

#### Exact-In

| 함수 | 설명 |
|------|------|
| `swapExactTokensForTokens(amountIn, amountOutMin, path[], to, deadline) returns (amounts[])` | `path`를 따라 정확한 ERC20 입력 스왑; 최소 출력 강제 |
| `swapExactETHForTokens(amountOutMin, path[], to, deadline) returns (amounts[])` payable | 네이티브를 WMON으로 래핑 후 `path`를 따라 정확한 네이티브 입력 스왑 |
| `swapExactTokensForETH(amountIn, amountOutMin, path[], to, deadline) returns (amounts[])` | `path`를 따라 정확한 ERC20 입력 스왑; 최종 WMON을 네이티브로 언래핑 |

#### Exact-Out

| 함수 | 설명 |
|------|------|
| `swapTokensForExactTokens(amountOut, amountInMax, path[], to, deadline) returns (amounts[])` | 정확한 ERC20 출력에 필요한 입력 계산; 최대 입력 상한 강제 |
| `swapETHForExactTokens(amountOut, amountInMax, path[], to, deadline) returns (amounts[])` payable | 정확한 토큰 출력에 필요한 네이티브 계산; 미사용 네이티브 환불 |
| `swapTokensForExactETH(amountOut, amountInMax, path[], to, deadline) returns (amounts[])` | 정확한 네이티브 출력에 필요한 토큰 입력 계산; 전달 시 WMON 언래핑 |

#### Fee-on-Transfer 변형

| 함수 | 설명 |
|------|------|
| `swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, amountOutMin, path[], to, deadline)` | Exact-in 스왑; 홉별로 실제 수신 잔액을 측정하여 fee-on-transfer 토큰 수용 |
| `swapExactETHForTokensSupportingFeeOnTransferTokens(amountOutMin, path[], to, deadline)` payable | 네이티브 exact-in 변형; 동일한 잔액 델타 측정 |
| `swapExactTokensForETHSupportingFeeOnTransferTokens(amountIn, amountOutMin, path[], to, deadline)` | 토큰 exact-in → 네이티브; 실제 수신 잔액으로 WMON 언래핑 |

### 조회

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `factory()` | `address` | NadFunFactory 주소 |
| `WETH()` | `address` | WMON 주소 (Router02 ABI 호환성을 위해 `WETH`로 명명) |
| `quote(amountA, reserveA, reserveB)` | `uint256 amountB` | LP 비율 기준 견적: `amountB = amountA * reserveB / reserveA`. 순수 산술 계산, 수수료 없음 |
| `getAmountOut(amountIn, reserveIn, reserveOut)` | `uint256 amountOut` | LP 수수료만 반영한 출력 견적 (0.25% LP 수수료, 프로토콜/크리에이터 수수료 미포함). **주의:** `NadFunPair.swap`의 실제 출력은 추가 프로토콜 및 크리에이터 수수료를 차감하므로, 종단간 라우팅 견적에는 `getAmountsOut` 사용 권장 |
| `getAmountIn(amountOut, reserveIn, reserveOut)` | `uint256 amountIn` | LP 수수료만 반영한 입력 견적. `getAmountOut`과 동일한 주의사항 |
| `getAmountsOut(amountIn, path[])` | `uint256[] amounts` | 멀티홉 경로를 따른 수수료 인식 출력 수량; 홉별로 `NadFunPair.getAmountOut`에 위임 |
| `getAmountsIn(amountOut, path[])` | `uint256[] amounts` | 멀티홉 경로를 따른 수수료 인식 필요 입력 수량; 홉별로 `NadFunPair.getAmountIn`에 위임 |

### 관리자

| 함수 | 접근 | 설명 |
|------|------|------|
| `setFactory(address)` | restricted | NadFunFactory 참조 업데이트. `FactoryUpdated` 이벤트 발행 |
| `_authorizeUpgrade(address)` | restricted | UUPS 업그레이드 권한 |

---

## NadFunLibrary

**Path:** `src/libraries/NadFunLibrary.sol`

`NadFunRouter02`가 사용하는 헬퍼 라이브러리. 표준 UniswapV2Library와의 핵심 차이: `pairFor`는 CREATE2 init-code-hash를 재계산하는 방식 대신 `INadFunFactory.getPair(tokenA, tokenB)`로 pair 주소를 조회한다. NadFunPair가 EIP-1167 minimal proxy clone으로 배포되기 때문에 init-code-hash 트릭은 유효하지 않다.

| 함수 | 설명 |
|------|------|
| `pairFor(factory, tokenA, tokenB)` | `factory.getPair`를 통해 pair 주소 반환; pair가 없으면 revert |
| `getReserves(factory, tokenA, tokenB)` | `(tokenA, tokenB)` 순서에 맞게 정렬된 `(reserveA, reserveB)` 반환 |
| `quote(amountA, reserveA, reserveB)` | 순수 LP 비율 견적 |
| `getAmountsOut(factory, amountIn, path[])` | 각 홉에서 `NadFunPair.getAmountOut`에 위임 |
| `getAmountsIn(factory, amountOut, path[])` | 각 홉에서 `NadFunPair.getAmountIn`에 위임 |

---

## 이벤트

| 이벤트 | 매개변수 |
|--------|----------|
| `AddLiquidity` | `address indexed pair, address indexed to, uint256 amountA, uint256 amountB, uint256 liquidity` |
| `RemoveLiquidity` | `address indexed pair, address indexed to, uint256 amountA, uint256 amountB, uint256 liquidity` |
| `Swap` | `address indexed pair, address indexed to, uint256 amountIn, uint256 amountOut` |
| `FactoryUpdated` | `address indexed oldFactory, address indexed newFactory` |

## 에러

| 에러 | 설명 |
|------|------|
| `ExpiredDeadline()` | 트랜잭션 유효기한 만료 |
| `InvalidPath()` | path에 토큰이 2개 미만 |
| `InsufficientOutputAmount()` | 출력이 최소값 미만 (슬리피지 초과) |
| `ExcessiveInputAmount()` | 입력이 최대값 초과 (exact-out) |
| `InsufficientLiquidity()` | pair 리저브 부족 |
| `InsufficientAAmount()` | 유동성 제거 시 토큰 A 출력이 최소값 미만 |
| `InsufficientBAmount()` | 유동성 제거 시 토큰 B 출력이 최소값 미만 |
| `NativeTransferFailed()` | 네이티브 환불 또는 전달 실패 |
