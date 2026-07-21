# TokenRegistry

**Path:** `src/core/TokenRegistry.sol`
**Pattern:** UUPS 업그레이드
**Inheritance:** `ITokenRegistry`, `UUPSUpgradeable`, `AccessManagedUpgradeable`

토큰 메타데이터 레지스트리 및 DexType-to-adapter 매핑. 토큰별 DEX 페어, quote 토큰, DEX 타입을 저장한다. 등록 권한은 로컬 allowlist가 아니라 현재 authority 정책으로 제어된다.

---

## 상태 변수

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `_tokens` | `mapping(address => TokenInfo)` | private | 토큰 주소 → 메타데이터 (pair, quoteToken, dexType) |
| `_adapters` | `mapping(DexType => IDexAdapter)` | private | DEX 타입 → 어댑터 컨트랙트 |

---

## 함수

### ITokenRegistry

| 함수 | 접근 | 설명 |
|------|------|------|
| `register(token, pair, quoteToken, dexType)` | restricted | 토큰 메타데이터 등록 (일회성, 재등록 불가) |
| `getPair(token)` | view | 토큰의 DEX 페어 주소 조회 |
| `getQuoteToken(token)` | view | quote 토큰 주소 조회 |
| `getDexType(token)` | view | DEX 타입 조회 (V2, V3, V4) |
| `getTokenInfo(token)` | view | 전체 TokenInfo 구조체 조회 |
| `isRegistered(token)` | view | 토큰 등록 여부 (pair != address(0)) |
| `getAdapter(dexType)` | view | DEX 타입의 어댑터 컨트랙트 조회 |

### 관리자

| 함수 | 접근 | 설명 |
|------|------|------|
| `setAdapter(dexType, adapter)` | restricted | DEX 타입의 어댑터 설정 |
| `_authorizeUpgrade(address)` | restricted | UUPS 업그레이드 권한 |

---

## 에러

| 에러 | 설명 |
|------|------|
| `AlreadyRegistered()` | 이미 등록된 토큰 |
