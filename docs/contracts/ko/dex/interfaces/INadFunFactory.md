# INadFunFactory

**Path:** `src/dex/interfaces/INadFunFactory.sol`
**Type:** Interface

NadFunFactory 인터페이스. 페어 생성, 조회, 프로토콜 수수료 설정 함수를 정의.

---

## 함수 시그니처

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `feeTo()` | `address` | 프로토콜 수수료 수령 주소 |
| `feeToSetter()` | `address` | 수수료 설정 권한 주소 |
| `feeCollector()` | `address` | FeeCollector 컨트랙트 주소 |
| `getPair(tokenA, tokenB)` | `address pair` | 두 토큰으로 페어 주소 조회 |
| `allPairs(index)` | `address pair` | 인덱스로 페어 주소 조회 |
| `allPairsLength()` | `uint256` | 전체 페어 수 |
| `createPair(tokenA, tokenB)` | `address pair` | 새 페어 생성 |
| `setFeeTo(address)` | — | 수수료 수령 주소 변경 |
| `setFeeToSetter(address)` | — | 수수료 설정 권한 이전 |

---

## 이벤트

| 이벤트 | 설명 |
|--------|------|
| `PairCreated(token0, token1, pair, pairCount)` | 새 페어 생성 시 발생 |
