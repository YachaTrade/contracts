# IVault

**Path:** `src/interfaces/IVault.sol`
**Type:** Interface

크리에이터 수수료 분배를 위한 최소 ERC-165 호환 vault 인터페이스. 내장 vault 구현체는 clone이 아닌 싱글톤 UUPS 프록시로 배포된다. CreatorFeeProcessor가 quoteToken을 전송한 뒤 `afterDeposit()`을 호출하며, `setup()`으로 토큰별 초기 설정을 수행한다.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `afterDeposit(token, quoteToken, amount)` | — | CreatorFeeProcessor가 quoteToken 전송 후 호출. token을 기준으로 처리 로직 수행 |
| `setup(token, data)` | — | 토큰별 초기 설정. Vault에 따라 no-op이거나 data에서 필요한 파라미터를 디코딩하여 등록 |
| `metadataURI()` | `string memory` | Vault 구현체의 오프체인 메타데이터 URI (이름/아이콘/설명 JSON 링크). Vault 레벨 값으로 `initialize()`에서 한 번만 설정되며 토큰별이 아님 |
| `supportsInterface(interfaceId)` | `bool` | IERC165에서 상속한 ERC-165 지원 여부 조회 |

---

IVault 자체는 공통 이벤트를 선언하지 않는다. 각 구현체가 동작별 이벤트를 별도로 정의한다.

---

## Known Implementations

| Implementation | VaultType | Description |
|----------------|-----------|-------------|
| `BurnVault` | Burn | 바이백 소각: quoteToken으로 token을 스왑 후 0xdead로 전송. setup은 no-op |
| `LPVault` | LP | quoteToken 절반을 token으로 스왑, 유동성 추가, LP 소각. setup은 no-op |
| `CreatorFeeVault` | Creator | 토큰별 creator를 설정하고 quoteToken을 누적한 뒤 creator가 claim |
| `GiftVault` | Gift | Platform-id (GitHub/X) 기반 **claim 모델** gift vault. 3상태: Accumulating → `restricted setReceiver` 호출 시 Active / bind window 만료 후 deposit 수신 시 Burned. Active receiver는 `claim(token)`으로 누적분 인출, 반복 가능. Rotate 시 누적 잔액은 이전 receiver에게 sweep |
| `DividendVault` | Dividend | 설정 비율로 입금을 나누고, 승인된 경로로 pending quote를 변환한 뒤 누적 Merkle claim으로 확정 잔액을 분배 |
