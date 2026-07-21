# IBondingCurve

**Path:** `src/interfaces/IBondingCurve.sol`
**Type:** Interface

BondingCurve 컨트랙트의 공개 인터페이스. 구조체, 이벤트, 에러, 함수 시그니처 정의.

---

## Enums

```solidity
enum CurveVersion {
    V1  // Initial version: bonding curve + Anti-Sniping
}
```

---

## Structs

### Curve — 토큰별 본딩커브 상태

| Field | Type | Purpose |
|-------|------|---------|
| `token` | `address` | Token 주소 |
| `creator` | `address` | 토큰 생성자 |
| `quoteToken` | `address` | 견적 토큰 주소 |
| `virtualQuoteReserve` | `uint256` | 가상 견적 리저브 |
| `virtualTokenReserve` | `uint256` | 가상 토큰 리저브 |
| `k` | `uint256` | 생성 시 고정된 constant-product invariant |
| `minTokenReserve` | `uint256` | 졸업 임계값 |
| `initialQuoteReserve` | `uint256` | 초기 virtual quote reserve |
| `initialTokenReserve` | `uint256` | 초기 virtual token reserve |
| `createdAtBlock` | `uint64` | 생성 블록 번호 (anti-sniping 인덱스 = `block.number - createdAtBlock`) |
| `graduated` | `bool` | 졸업 여부 |
| `creatorFeeRate` | `uint16` | creator fee rate (BPS) |
| `version` | `CurveVersion` | V1 |
| `dexType` | `ITokenRegistry.DexType` | DEX 유형 (V2/V3/V4) |
| `pair` | `address` | DEX pair 주소 |
| `graduateFee` | `uint256` | 커브에 저장된 quote 단위 졸업 수수료 |

### VaultAllocation — 토큰 생성 시 vault 배분

| Field | Type | Purpose |
|-------|------|---------|
| `vault` | `address` | VaultRegistry에 등록된 singleton vault 주소 |
| `bps` | `uint16` | Basis points 배분 (> 0) |
| `setupData` | `bytes` | Vault별 setup 데이터 |

### CreateTokenParams — 토큰 생성 파라미터

| Field | Type | Purpose |
|-------|------|---------|
| `name` | `string` | 토큰 이름 |
| `symbol` | `string` | 토큰 심볼 |
| `tokenURI` | `string` | 토큰 metadata URI |
| `quoteToken` | `address` | 견적 토큰 주소 |
| `creatorFeeRate` | `uint16` | 크리에이터 수수료율 (BPS) |
| `vaults` | `VaultAllocation[]` | Vault 배분 (최대 5개, bps 합계 = 10000) |
| `salt` | `bytes32` | CREATE2 salt |
| `dexType` | `ITokenRegistry.DexType` | DEX 유형 선택 (V2/V3/V4) |
| `creator` | `address` | 토큰 creator |
| `buyQuoteAmount` | `uint256` | 명시적 optional 초기 매수 quote 금액 |

> `sum(vaults[i].bps) == 10000` 필수. 최대 5개 vault.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `create(CreateTokenParams)` payable | `(address token, uint256 tokenOut)` | 토큰 생성 + 명시적 optional 초기 매수 |
| `buy(to, token)` | `uint256 tokensOut` | 본딩커브 매수 (잔액 감지) |
| `sell(to, token)` | `uint256 quoteOut` | 본딩커브 매도 (잔액 감지) |
| `getCurve(token)` | `Curve memory` | 커브 정보 조회 |
| `getQuoteToken(token)` | `address` | 견적 토큰 주소 조회 |
| `isHalted()` | `bool` | 정지 상태 확인 |
| `getAmountOut(token, amountIn, isBuy)` | `uint256 amountOut` | 출력 수량 계산 |
| `getAmountIn(token, amountOut, isBuy)` | `uint256 amountIn` | 입력 수량 계산 |
| `getSnipingPenalty(token)` | `uint256 penaltyBps` | anti-sniping 패널티 조회 |
| `setModule(moduleId, module)` | — | 모듈 등록/교체 |
| `halt(halted)` | — | 긴급 정지/해제 |

---

## Events

| Event | Parameters |
|-------|------------|
| `Create` | `creator, token, pair, quoteToken, name, symbol, tokenURI, virtualQuoteReserve, virtualTokenReserve, minTokenReserve` |
| `Buy` | `address indexed token, address indexed buyer, uint256 quoteIn, uint256 tokenOut` |
| `Sell` | `address indexed token, address indexed seller, uint256 tokenIn, uint256 quoteOut` |
| `Graduate` | `address indexed token, address indexed pair` |
| `SnipingPenalty` | `address indexed token, address indexed buyer, uint256 snipingFee, uint256 penaltyBps` |
| `Sync` | `token, realQuoteReserve, realTokenReserve, virtualQuoteReserve, virtualTokenReserve` |
| `ModuleUpdate` | `bytes32 indexed moduleId, address indexed module` |
| `Halt` | `bool halted` |

## Errors

| Error | Description |
|-------|-------------|
| `TokenNotFound()` | 토큰 미등록 |
| `AlreadyGraduated()` | 이미 졸업 |
| `InvalidKValue()` | 유효하지 않은 K 값 |
| `ProtocolHalted()` | 프로토콜 정지 |
| `UnsupportedVersion()` | 지원하지 않는 curve version |
| `ZeroModule()` | module 주소가 zero |
| `ModuleAlreadySet(bytes32)` | module ID가 이미 설정됨 |
| `InsufficientTokenOut()` | 초기 매수 token output이 없음 |
| `DuplicateVault()` | vault allocation 중복 |
