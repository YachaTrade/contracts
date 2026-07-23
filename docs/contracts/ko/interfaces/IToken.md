# IToken

**Path:** `src/interfaces/IToken.sol`
**Type:** Interface

BondingCurve가 EIP-1167 clone으로 배포하는 단순 ERC-20 launch-token interface다. Fee-on-transfer 동작은 없다.

---

## 함수 시그니처

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `initialize(name, symbol, tokenURI, bondingCurve, pair)` | — | 클론 초기화 (BondingCurve가 1회 호출). pair 주소 저장으로 졸업 전 전송 가드 활성화 |
| `setIsGraduated()` | — | 졸업 플래그 설정 (BondingCurve만 호출) |
| `isGraduated()` | `bool` | 졸업 여부 |
| `bondingCurve()` | `address` | 배포한 BondingCurve 주소 |
| `pair()` | `address` | Canonical V3 pool 주소 |
| `tokenURI()` | `string` | 토큰 메타데이터 URI |
| `TOTAL_SUPPLY()` | `uint256` | 고정 총 발행량 (1e27 wei = 1B tokens) |

---

## 에러

| 에러 | 설명 |
|------|------|
| `AlreadyInitialized()` | 이미 초기화됨 |
| `NotBondingCurve()` | bondingCurve가 아닌 호출자 |
| `AlreadyGraduated()` | 이미 졸업됨 |
| `TransferToPairBeforeGraduation()` | 졸업 전 pair 주소로의 전송 차단 |
