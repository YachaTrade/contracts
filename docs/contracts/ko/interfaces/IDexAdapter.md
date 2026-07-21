# IDexAdapter

**Path:** `src/interfaces/IDexAdapter.sol`
**Type:** Interface

플러그형 DEX 어댑터 인터페이스. 각 DEX 버전(V2, V3, V4)이 이 인터페이스를 구현. 핵심 컨트랙트가 DEX별 세부 구현을 알 필요 없이 동일한 인터페이스로 상호작용. 전략 패턴(Strategy Pattern) — TokenRegistry에 등록되어 DexType별로 동적 선택.

---

## 함수 시그니처

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `deployPair(tokenA, tokenB)` | `address pair` | 새 거래 페어/풀 배포 |
| `swap(pair, tokenIn, tokenOut, amountIn, to, data)` | `uint256 amountOut` | 스왑 실행 (호출자가 tokenIn을 먼저 전송해야 함). `data`는 INadFunCallee 콜백을 통한 flash swap 지원. |
| `getAmountOut(pair, tokenIn, amountIn)` | `uint256 amountOut` | 주어진 입력에 대한 예상 출력량 (view) |
| `getAmountIn(pair, tokenOut, amountOut)` | `uint256 amountIn` | 원하는 출력을 위한 필요 입력량 (view) |
| `addLiquidity(pair, tokenA, tokenB, amountA, amountB, to)` | `uint256 liquidity` | 유동성 추가 (호출자가 두 토큰 모두 먼저 전송해야 함) |
| `removeLiquidity(pair, liquidity, to)` | `uint256 amount0, uint256 amount1` | 유동성 제거 |
| `claimableFees(pair, liquidity)` | `uint256 amount0, uint256 amount1` | 수령 가능 수수료 조회 (view) |
| `claimFees(pair, liquidity, to)` | `uint256 amount0, uint256 amount1` | 누적 거래 수수료 수령 |

---

## 구현체

| 구현체 | 설명 |
|--------|------|
| `NadSwapAdapter` | NadFunPair 전용 얇은 래퍼 — AMM view를 pair에 위임, 스왑 실행 및 유동성 처리 |

---

## 사용처

BondingCurve (페어 배포), NadFunRouter (졸업 후 스왑), LPManager (졸업 유동성), BurnVault/LPVault/GiftVault 등 vault에서 사용.
