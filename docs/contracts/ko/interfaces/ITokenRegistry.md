# ITokenRegistry

**Path:** `src/interfaces/ITokenRegistry.sol`
**Type:** Interface

토큰 메타데이터 레지스트리 인터페이스. 토큰별 pair/quoteToken/dexType 매핑을 저장하고 DexType별 adapter 레지스트리를 관리.

---

## 열거형

### DexType

```solidity
enum DexType { UniswapV2, UniswapV3, UniswapV4 }
```

---

## 구조체

### TokenInfo

```solidity
struct TokenInfo {
    address pair;       // DEX 페어/풀 주소
    address quoteToken; // 기축 토큰 주소
    DexType dexType;    // DEX 버전
}
```

---

## 함수 시그니처

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `register(token, pair, quoteToken, dexType)` | — | 토큰 메타데이터 등록 (BondingCurve가 호출) |
| `getPair(token)` | `address` | DEX 페어 주소 조회 |
| `getQuoteToken(token)` | `address` | quote 토큰 주소 조회 |
| `getDexType(token)` | `DexType` | DEX 타입 조회 |
| `getTokenInfo(token)` | `TokenInfo` | 전체 토큰 정보 조회 |
| `isRegistered(token)` | `bool` | 토큰 등록 여부 |
| `getAdapter(dexType)` | `IDexAdapter` | DEX 타입의 어댑터 조회 |
