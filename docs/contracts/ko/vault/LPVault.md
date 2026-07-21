# LPVault

**Path:** `src/vault/LPVault.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

유동성 주입(Liquidity Injection) Vault. CreatorFeeProcessor로부터 quoteToken을 받아 절반을 token으로 스왑하고, DEX에 유동성을 추가한 후, LP 토큰을 `0xdead`로 전송하여 영구 잠금. 본딩 phase에서는 quoteToken을 토큰별로 누적만 하고, 졸업 후 처리. 싱글톤으로 배포되어 모든 token에 대해 하나의 인스턴스가 공유됨.

---

## 상수

| 상수 | 값 | 용도 |
|------|---|------|
| `BURN_ADDRESS` | `address(0xdead)` | LP 토큰이 여기로 전송되면 영구 잠금 |

---

## 상태 변수

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `tokenRegistry` | `ITokenRegistry` | public | 페어/어댑터 조회용 TokenRegistry |
| `creatorFeeProcessor` | `address` | public | afterDeposit 호출 권한 |
| `_accumulatedQuote` | `mapping(address => uint256)` | private | 토큰별 누적 quoteToken 잔액 (본딩 phase 동안 축적) |

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `initialize(protocolManager, tokenRegistry, creatorFeeProcessor)` | initializer | UUPS 프록시 초기화 |
| `setup(token, data)` | external | no-op (LPVault는 토큰별 설정 불필요) |
| `afterDeposit(token, quoteToken, amount)` | external | 본딩 phase: 누적만. 졸업 후: 절반 스왑 + 유동성 추가 + LP 소각 |
| `accumulatedQuote(token)` | view | 토큰별 누적 quoteToken 잔액 조회 |

---

## 핵심 로직: afterDeposit

```
CreatorFeeProcessor -> transfer(quoteToken, vault, amount)
CreatorFeeProcessor -> try vault.afterDeposit(token, quoteToken, amount)
  |-- isGraduated() 체크:
  |   |-- false (본딩 phase):
  |   |   +-- _accumulatedQuote[token] += amount → return (누적만, 처리 지연)
  |   |-- true (졸업 후):
  |       |-- totalQuote = _accumulatedQuote[token] + amount (이전 누적분 + 현재 입금)
  |       |-- _accumulatedQuote[token] = 0
  |       |-- halfQuote = totalQuote / 2 (유동성용)
  |       |-- swapQuote = totalQuote - halfQuote (스왑용, 홀수 금액 처리)
  |       |-- TokenRegistry -> pair 정보 + adapter
  |       |-- swapQuote를 adapter로 전송
  |       |-- adapter.swap(quoteToken -> token)
  |       |-- tokenReceived == 0: return
  |       |-- tokenReceived + halfQuote를 adapter로 전송
  |       |-- adapter.addLiquidity(pair, token, quoteToken, ..., BURN_ADDRESS)
  |       +-- emit Inject
```

본딩 phase에서는 DEX pair에 유동성이 없으므로 스왑이 불가능 — quoteToken을 토큰별 `_accumulatedQuote` 매핑에 누적만 한다. 졸업 후 첫 afterDeposit 호출 시 누적분 + 현재 입금을 합쳐서 한번에 처리.

스왑/유동성 추가 실패 시 revert. CreatorFeeProcessor의 try/catch가 afterDeposit을 감싸므로 파이프라인은 보호됨.

---

## 에러

| 에러 | 설명 |
|------|------|
| `NotAuthorized()` | creatorFeeProcessor가 아닌 호출자 |

---

## 이벤트

| 이벤트 | 매개변수 |
|--------|----------|
| `Inject` | `address indexed token, uint256 quoteUsed, uint256 tokenUsed, uint256 lpBurned` |
