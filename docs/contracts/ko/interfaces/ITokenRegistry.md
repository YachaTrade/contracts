# ITokenRegistry

**Path:** `src/interfaces/ITokenRegistry.sol`
**Type:** Interface

토큰 메타데이터 레지스트리 인터페이스. 레거시 pair, canonical V3 pool/reverse lookup, quote token, DEX type, fee tier와 유지 중인 DexType별 adapter 레지스트리를 관리한다.

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
    address pair;       // 레거시 DEX pair 주소
    address pool;       // canonical Uniswap V3 pool
    address quoteToken; // 기축 토큰 주소
    DexType dexType;    // DEX 버전
    uint24 feeTier;     // canonical V3 fee tier
}
```

---

## 함수 시그니처

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `register(token, pair, quoteToken, dexType)` | — | 토큰 메타데이터 등록 (BondingCurve가 호출) |
| `registerV3(token, pool, quoteToken, feeTier)` | — | canonical V3 metadata와 reverse pool mapping 등록 |
| `getPair(token)` | `address` | DEX 페어 주소 조회 |
| `getPool(token)` | `address` | canonical V3 pool 주소 조회 |
| `getTokenByPool(pool)` | `address` | canonical V3 pool로 launch token 역조회 |
| `getQuoteToken(token)` | `address` | quote 토큰 주소 조회 |
| `getDexType(token)` | `DexType` | DEX 타입 조회 |
| `getTokenInfo(token)` | `TokenInfo` | 전체 토큰 정보 조회 |
| `isRegistered(token)` | `bool` | 토큰 등록 여부 |
| `getAdapter(dexType)` | `IDexAdapter` | DEX 타입의 어댑터 조회 |
| `setAdapter(dexType, adapter)` | — | 유지 중인 DexType별 IDexAdapter lane 설정 (implementation restricted) |
