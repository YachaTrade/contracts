# BurnVault

**Path:** `src/vault/BurnVault.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

바이백 앤 번(Buyback & Burn) Vault. CreatorFeeProcessor로부터 quoteToken을 받아 token으로 스왑한 후 `0xdead`로 전송하여 영구 소각. 본딩 phase에서는 YachaRouter.buy()를 사용해 clamped buy 환불/잔액 보존 로직을 타고, 졸업 후에는 등록 DEX 어댑터를 통해 스왑. singleton UUPS proxy로 배포되어 모든 token에 대해 하나의 인스턴스가 공유됨.

---

## 상수

| 상수 | 값 | 용도 |
|------|---|------|
| `BURN_ADDRESS` | `address(0xdead)` | 영구 소각 주소 (알려진 프라이빗 키 없음) |

---

## 상태 변수

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `tokenRegistry` | `ITokenRegistry` | public | 페어/어댑터 조회용 TokenRegistry |
| `creatorFeeProcessor` | `address` | public | afterDeposit 호출 권한 |
| `bondingCurve` | `IBondingCurve` | public | 본딩 phase에서 직접 매수용 |

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `initialize(protocolManager, tokenRegistry, creatorFeeProcessor, bondingCurve, router)` | initializer | UUPS 프록시 초기화 |
| `setup(token, data)` | external | no-op (BurnVault는 토큰별 설정 불필요) |
| `afterDeposit(token, quoteToken, amount)` | external | 졸업 여부에 따라 스왑 경로 선택 후 0xdead로 전송 |

---

## 핵심 로직: afterDeposit

```
CreatorFeeProcessor -> transfer(quoteToken, vault, amount)
CreatorFeeProcessor -> vault.afterDeposit(token, quoteToken, amount)
  |-- balanceOf(quoteToken) 확인 → 0이면 return
  |-- isGraduated() 체크:
  |   |-- true (졸업 후):
  |   |   |-- TokenRegistry.getTokenInfo(token) -> pair, dexType
  |   |   |-- TokenRegistry.getAdapter(dexType) -> adapter
  |   |   |-- quoteToken을 adapter로 전송
  |   |   +-- adapter.swap(pair, quoteToken, token, amount, this, "")
  |   |-- false (본딩 phase):
  |   |   |-- quoteToken을 bondingCurve로 전송
  |   |   +-- bondingCurve.buy(this, token)
  |-- token -> 0xdead 전송
  +-- emit Burn
```

`afterDeposit`은 pending quote를 기록한 뒤 `executePendingBuyback`을 self-call `try/catch`로 실행한다. swap/buy 실패는 self-call만 롤백되고 catch되며, pending quote는 이후 재시도를 위해 유지되어 상위 creator-fee settlement는 완료될 수 있다.

---

## 에러

| 에러 | 설명 |
|------|------|
| `NotAuthorized()` | creatorFeeProcessor가 아닌 호출자 |

---

## 이벤트

| 이벤트 | 매개변수 |
|--------|----------|
| `Burn` | `address indexed token, uint256 quoteIn, uint256 tokenBurned` |
