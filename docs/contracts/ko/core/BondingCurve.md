# BondingCurve

**경로:** `src/core/BondingCurve.sol`
**패턴:** UUPS proxy
**상속:** `IBondingCurve`, `AccessControlUpgradeable`, `ReentrancyGuard`

BondingCurve는 졸업 전 token inventory와 quote reserve를 보유한다. V3 기반 launch를 생성하고 virtual-reserve 거래를 실행하며, 졸업 시 permanent V3 liquidity를 원자적으로 배치한다.

## 역할

| 역할 | 책임 |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | Module 설정, role 관리, UUPS upgrade |
| `GUARDIAN_ROLE` | 생성과 거래 halt/resume |
| `ROUTER_ROLE` | `create`, `buy`, `sell` 호출 |

## 모듈

| 모듈 | 책임 |
| --- | --- |
| `TokenRegistry` | Canonical V3 metadata 등록 |
| `LPManager` | 졸업 유동성 배치 |
| `V3PoolDeployer` | Canonical pool 생성과 초기화 |
| `CreatorFeeProcessor` | Launch token의 vault slot 설정 |

Module은 admin이 설정하며 배포 과정에서 authority wiring을 검증한다.

## 생명주기

### `create(params)`

1. ProtocolManager에서 active quote 설정을 읽는다.
2. 현재 `feeReceiver`에 `deployFee`를 전송한다.
3. Deterministic salt로 Token implementation을 clone한다.
4. Canonical V3 pool을 생성 또는 검증하고 목표 가격으로 초기화한다.
5. Pool 주소를 포함해 Token을 초기화한다.
6. `registerV3`로 token, quote, pool, V3 fee tier를 등록한다.
7. Creator vault slot을 설정한다.
8. Virtual reserve와 tracked reserve를 저장한다.
9. 선택적 initial buy를 anti-sniping penalty 없이 실행한다.

### `buy(to, token, quoteIn)`

- `ROUTER_ROLE` 전용이다.
- Router에서 정확한 `quoteIn`을 pull한다.
- `curveProtocolFeeRate`를 적용한다.
- 일반 buy에는 block별 anti-sniping penalty를 적용한다.
- `BondingCurveLibrary`로 token output을 계산한다.
- Tracked/virtual reserve를 갱신한다.
- Fee는 `feeReceiver`, token은 `to`로 전송한다.
- 최소 virtual token reserve에 도달하면 졸업을 실행한다.

### `sell(to, token, tokenIn)`

- `ROUTER_ROLE` 전용이다.
- 정확한 token input을 pull한다.
- Virtual reserve로 quote output을 계산한다.
- `curveProtocolFeeRate`만 적용하며 sell에는 anti-sniping penalty가 없다.
- Tracked/virtual reserve를 갱신한다.
- Protocol fee와 quote output을 전송한다.

### 졸업

Curve와 Token을 graduated 상태로 만들고 `graduateFee`를 차감한다. Tracked launch asset을 LPManager로 보내 `allocate()`를 호출하면 LPManager와 V3LiquidityActor가 두 permanent V3 position을 만든다. 미사용 asset은 `feeReceiver`로 보낸다.

## 회계 보장

- 호출 단위 balance delta로 donation을 제외한다.
- 지원하지 않는 token version과 inactive quote를 거부한다.
- 생성, 거래, 졸업은 non-reentrant다.
- Token은 한 번만 졸업할 수 있다.
- Token은 졸업 전 canonical pool 직접 전송을 차단한다.
- UUPS upgrade에는 `DEFAULT_ADMIN_ROLE`이 필요하다.

## 이벤트

주요 lifecycle 이벤트는 `CurveCreate`, `CurveBuy`, `CurveSell`, `CurveGraduate`, `ModuleUpdate`, `Halt`다.
