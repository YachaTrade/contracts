# IVault

**Path:** `src/interfaces/IVault.sol`
**Type:** Interface

크리에이터 수수료 분배를 위한 최소 vault 인터페이스. 모든 vault 구현체가 이 인터페이스를 준수해야 함. CreatorFeeProcessor가 quoteToken을 전송한 후 `afterDeposit()`을 호출. Vault는 싱글톤으로 배포되며, `setup()`으로 토큰별 초기 설정을 수행.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `afterDeposit(token, quoteToken, amount)` | — | CreatorFeeProcessor가 quoteToken 전송 후 호출. token을 기준으로 처리 로직 수행 |
| `setup(token, data)` | — | 토큰별 초기 설정. Vault에 따라 no-op이거나 data에서 필요한 파라미터를 디코딩하여 등록 |
| `metadataURI()` | `string memory` | Vault 구현체의 오프체인 메타데이터 URI (이름/아이콘/설명 JSON 링크). Vault 레벨 값으로 `initialize()`에서 한 번만 설정되며 토큰별이 아님 |

---

## Events

| Event | Parameters | Description |
|-------|------------|-------------|
| `VaultExecuted` | `address indexed token, address indexed vault, uint256 amountIn, uint256 amountProcessed` | 모든 vault가 입금 처리 후 발행 |

---

## Known Implementations

| Implementation | Pattern | Description |
|----------------|---------|-------------|
| `BurnVault` | Singleton | 바이백 소각: quoteToken으로 token을 스왑 후 0xdead로 전송. setup은 no-op |
| `LPVault` | Singleton | quoteToken 절반을 token으로 스왑, 유동성 추가, LP 소각. setup은 no-op |
| `CreatorFeeVault` | Singleton | 사전 설정된 수령인 주소로 직접 전송. setup으로 token별 recipient 등록 |
| `GiftVault` | UUPS Proxy | Platform-id (GitHub/X) 기반 **claim 모델** gift vault. 3상태: Accumulating → `restricted setReceiver` 호출 시 Active / bind window 만료 후 deposit 수신 시 Burned. Active receiver는 `claim(token)`으로 누적분 인출, 반복 가능. Rotate 시 누적 잔액은 이전 receiver에게 sweep |
