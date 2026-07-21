# Token

**Path:** `src/token/Token.sol`
**Pattern:** EIP-1167 Clone
**Inheritance:** `ERC20Upgradeable`, `ERC20PermitUpgradeable`, `IToken`

NadFun V2 단순 ERC20 토큰. BondingCurve가 ERC-1167 클론으로 배포. 이전 TaxToken의 fee-on-transfer 방식을 대체하며, 수수료 수집은 NadFunPair와 BondingCurve 레벨에서 처리한다.

---

## 상수

| 상수 | 값 | 설명 |
|------|---|------|
| `TOTAL_SUPPLY` | `1_000_000_000 ether` (1B) | 고정 총 발행량 |

---

## 상태 변수

| 변수 | 타입 | 설명 |
|------|------|------|
| `bondingCurve` | `address` | 이 토큰을 배포한 BondingCurve |
| `pair` | `address` | 이 토큰의 NadFunPair 주소 |
| `isGraduated` | `bool` | 졸업 여부 (본딩 커브 → DEX 마이그레이션 완료) |

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `initialize(name, symbol, tokenURI, bondingCurve, pair)` | initializer | 클론 초기화. ERC20 설정 + tokenURI 저장 + TOTAL_SUPPLY를 bondingCurve에 민팅 |
| `tokenURI()` | view | 토큰 메타데이터 URI 반환 |
| `setIsGraduated()` | external | 졸업 플래그 설정 (bondingCurve만 호출 가능) |

---

## 에러

| 에러 | 설명 |
|------|------|
| `AlreadyInitialized()` | 이미 초기화됨 |
| `NotBondingCurve()` | bondingCurve가 아닌 호출자 |
| `AlreadyGraduated()` | 이미 졸업됨 |
| `TransferToPairBeforeGraduation()` | 졸업 전 pair 주소로의 전송 차단 |

---

## 아키텍처 역할

1. **BondingCurve.create()** 시 ERC-1167 클론으로 배포
2. 총 발행량(1B)을 BondingCurve에 민팅
3. `_update` 오버라이드로 졸업 전 pair 주소로의 토큰 전송을 차단 (`TransferToPairBeforeGraduation`) — 리저브 오염 방지
4. 졸업 시 `isGraduated` 플래그만 설정 (상태 머신 없음) — pair로의 전송 가드 해제
5. ERC20Upgradeable + ERC20PermitUpgradeable 사용 — clone은 constructor가 호출되지 않으므로 initializer 패턴 필요
