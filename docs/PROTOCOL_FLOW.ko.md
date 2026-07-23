# 프로토콜 흐름 — GiwaRouter 런타임과 유지 중인 생명주기

## 개요

```
Token Creation → Bonding Curve Trading → Graduation → DEX Trading → Fee Settlement → Distribution
```

> **통합 경계:** `GiwaRouter`와 `V3SwapAdapter`는 현재 canonical Uniswap V3 사용자 런타임을 구현합니다. 기본 배포 스크립트의 토큰 생성/졸업은 여전히 NadFun V2 factory/LPManager 경로에 연결되어 있으므로 end-to-end V3 생명주기는 아닙니다. V2로 졸업한 메타데이터는 GiwaRouter의 졸업 후 경로에서 거부됩니다.

---

## 1단계: 토큰 생성

**진입점:** `GiwaRouter.create(params)` → `BondingCurve.create(params)` [ROUTER_ROLE 필요]

```
User ──► GiwaRouter.create() ──► BondingCurve.create()  [ROUTER_ROLE]
              │
              ├── 배포 수수료(quote별) ──► feeReceiver (quote token, 0보다 큰 경우)
              │
              ├── 1. Token 클론 (EIP-1167, 순수 ERC20)
              ├── 2. NadFunFactory.createPair(token, quoteToken)
              │      + TokenRegistry.register(token, pair, quoteToken)
              ├── 3. FeeCollector.setup(pair, token, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)
              ├── 4. 싱글톤 Vault 설정 (VaultRegistry에서 등록된 싱글톤 vault 주소 조회)
              │      각 VaultAllocation마다 vault.setup(token, data) 호출
              │
              ├── 5. 초기화:
              │      싱글톤 CreatorFeeProcessor.setup(token, vaults[]) (MODULE_CREATOR_FEE_PROCESSOR로 주소 조회)
              │      Token.initialize(name, symbol, uri, bondingCurve, pair)
              │      (10억 토큰이 Token.initialize에서 BondingCurve에게 민팅)
              │
              └── 6. 커브 상태 초기화:
                    curve.k = virtualQuoteReserve × virtualTokenReserve
                    curve.creatorFeeRate = creatorFeeRate
                    graduated = false
```

**크리에이터 수수료율:** ProtocolManager owner가 구성한 허용목록 검증 (기본 정책 1%/3%/5%)

**참고:** `snipingPenaltyTable`(블록 단위 BPS 배열, 인덱스 = `block.number - createdAtBlock`)과 quoteToken별 `settlementThreshold`는 `ProtocolManager`에서 가져온다. `FeeCollector`는 페어별 수수료 설정, 페어별 누적 creator fee, quoteToken별 tracked balance, 정산 중 `_settling` 플래그를 저장한다.

---

## 1B단계: 초기 매수 포함 생성

`BondingCurve.create()`는 통합 함수 — deployFee(quoteToken) 이후 잔여 quote가 감지되면 sniping 면제 초기 매수를 자동 실행한다.

```
User → GiwaRouter.create(params{buyQuoteAmount: X})
       ├── safeTransferFrom(User → BC, deployFee(quoteToken) + buyQuoteAmount)
       └── BC.create(params{creator: User})  [ROUTER_ROLE 필요]
            ├── balance detection: totalIn = 잔액 - _totalQuoteReserved
            ├── safeTransfer(feeReceiver, deployFee(quoteToken))
            ├── _create(params, creator=User)
            └── 잔여 quote → _initialBuy(to=User) — sniping penalty 없음
```

---

## 2단계: 본딩커브 거래

### 매수 (Quote → Token)

```
User ──► GiwaRouter.buy(params)
              │
              ├── getAmountOut() → 수수료 포함 출력량 사전 계산
              ├── require(expectedOut >= minTokensOut) → 슬리피지 사전 검증
              ├── quoteToken.transferFrom(User, BondingCurve, amount)
              │
              └── BondingCurve.buy(to, token)  ← 잔액 감지, 금액 파라미터 없음
                    │
                    ├── 1. 잔액 감지: quoteAmount = balanceOf(this) - 이전 잔액
                    ├── 2. creatorFee > 0이면 protocol + creator fee → FeeCollector
                    │      └── collectFee가 protocol 전달, creator fee 누적
                    │      (creatorFee == 0이면 protocol fee는 feeReceiver로 직접 전송)
                    ├── 3. 스나이핑 방지 페널티 ──► feeReceiver
                    ├── 4. 유효 금액 → 커브 계산 (x·y=k)
                    ├── 5. _totalQuoteReserved += effectiveQuoteIn
                    ├── 6. 토큰 전송 → 사용자 (순수 ERC20, creator fee hook 없음)
                    │
                    └── 7. 졸업 확인:
                          virtualTokenReserve == minTokenReserve → _graduate()
```

### 매도 (Token → Quote)

```
User ──► GiwaRouter.sell(params)
              │
              ├── getAmountOut() → 수수료 포함 출력량 사전 계산
              ├── require(expectedOut >= minQuoteOut) → 슬리피지 사전 검증
              ├── token.transferFrom(User, BondingCurve, amount)
              │
              └── BondingCurve.sell(to, token)  ← 잔액 감지, 금액 파라미터 없음
                    │
                    ├── 1. 잔액 감지: tokenAmount
                    ├── 2. 커브 계산 (x·y=k)
                    ├── 3. _totalQuoteReserved -= grossQuoteOut
                    ├── 4. creatorFee > 0이면 protocol + creator fee → FeeCollector
                    │      └── collectFee가 protocol 전달, creator fee 누적
                    │      (creatorFee == 0이면 protocol fee는 feeReceiver로 직접 전송)
                    └── 5. 순 quoteOut ──► 사용자
```

---

## 3단계: 졸업 (현재 기본 배선: 레거시 V2)

**트리거:** `virtualTokenReserve == curve.minTokenReserve` (자동)

```
BondingCurve._graduate()
    │
    ├── 1. curve.graduated = true
    ├── 2. _totalQuoteReserved 해제
    ├── 3. 졸업 수수료(quote별) ──► feeReceiver
    ├── 4. 초과 토큰 → feeReceiver (DEX 가격 = 커브 가격 맞춤)
    │
    ├── 5. LPManager.addLiquidity()
    │       ├── token + quoteToken → LPManager
    │       ├── IDexAdapter.addLiquidity() → NadFunPair.mint()
    │       └── LP 토큰은 LPManager가 영구 launch liquidity로 보관
    │
    └── 6. Token.setIsGraduated()
```

---

## 4A단계: GiwaRouter를 통한 canonical V3 거래

커브가 졸업했고 TokenRegistry 메타데이터가 canonical factory pool과 등록 fee tier를 가진 `DexType.UniswapV3`인 경우 이 런타임이 적용됩니다.

```
User ──► GiwaRouter.buy()/sell()/exactOutBuy()/exactOutSell()
              │
              ├── BondingCurve.getCurve()에서 졸업 상태 조회
              ├── TokenRegistry에서 V3 pool/quote/fee metadata 검증
              ├── pool budget 또는 gross-output target 계산
              └── V3SwapAdapter.exactInput()/exactOutput()
                    ├── canonical factory pool 재계산
                    ├── nonce-bound 단일 callback context 설정
                    ├── pool.swap() → 인증 callback
                    ├── delta/input cap 검증; context 삭제; pool 지급
                    └── callback 소비 및 balance delta 검증
              ├── adapter allowance를 0으로 초기화
              ├── 실제 quote-side dexProtocolFeeRate 계산
              ├── 프로토콜 수수료 → 현재 feeReceiver
              └── output + 호출 범위 미사용 입력 refund → user
```

- exact-input은 non-zero price limit에서 부분 체결될 수 있으며 미사용 입력을 refund합니다.
- exact-output은 pool이 요청 출력을 전량 제공해야 합니다.
- native 경로는 token quote가 configured wrapped-native와 같아야 하며, `receive()`는 wrapped-native withdraw만 받습니다.
- `getDexAmountOut`/`getDexAmountIn`은 QuoterV2 기반 non-view Solidity 호출이므로 클라이언트는 `eth_call`을 사용합니다. 실제 swap 실행은 QuoterV2에 의존하지 않습니다.

## 4B단계: 유지 중인 레거시 V2 DEX 거래

### 거래 흐름

```
User ──► 명시적 레거시 adapter / NadFunPair
              │
              └── NadSwapAdapter.swap() ──► NadFunPair.swap()
                    │
                    ├── FeeCollector.getFeeConfig(pair) 조회
                    │
                    ├── LP fee (0.25%) → reserve에 잔류
                    │
                    ├── Protocol fee + Creator fee → FeeCollector
                    │     fee = quoteAmount × (creatorFeeRate + dexProtocolFeeRate) / BPS
                    │     transfer(feeCollector, fee)
                    │     FeeCollector.collectFee(pair, protocolFee, creatorFee)
                    │
                    ├── k invariant 검증
                    │
                    └── 나머지 → 사용자
```

---

## 5단계: 수수료 정산 및 분배

**트리거:** `FeeCollector.accumulatedFee(pair) >= settlementThreshold`

이 유지 중인 creator-fee 정산 경로는 본딩 단계와 레거시 졸업 후 단계에서 동작합니다. canonical V3 GiwaRouter protocol fee는 현재 feeReceiver로 직접 전송되며 이 creator-fee pipeline에 들어가지 않습니다. `_settling` 플래그는 FeeCollector에 `mapping(address pair => bool)`로 저장되며, 정산 중 BondingCurve는 수수료 0을 반환하여 재귀적 수수료 누적을 방지합니다.

```
FeeCollector.settle(pair, minAmountOut)  [authorized settler only, restricted]
    │
    ├── 1. 누적된 크리에이터 수수료가 threshold 이상인지 확인
    ├── 2. _settling[pair] = true (vault 작업을 위한 수수료 면제 모드)
    ├── 3. 크리에이터 수수료 ──► CreatorFeeProcessor.processCreatorFee(token, quoteToken, creatorFeeAmount)
    │       │
    │       └── 각 vault[i]에 BPS 비율로 분배:
    │             ├── amount = creatorFeeAmount × vault[i].bps / BPS
    │             ├── transfer(vault[i], amount)
    │             └── vault[i].afterDeposit(token, quoteToken, amount)
    │                 (실패하면 전체 분배/settlement 트랜잭션 revert)
    │
    └── 4. _settling[pair] = false
```

---

## 6단계: 수익 분배

### 싱글톤 Vault (조합형, 단계별 동작)

각 싱글톤 vault는 CreatorFeeProcessor로부터 quoteToken을 받은 후 자체 로직을 처리한다.
졸업 여부에 따라 vault 동작이 달라진다:

```
BurnVault:
  본딩 단계:         quoteToken → GiwaRouter.buy() + burn → 0xdead
  졸업 후:           quoteToken → 등록 adapter 스왑 + burn → 0xdead

GiftVault:
  본딩 단계:         quoteToken → GiwaRouter.buy() + burn → 0xdead
  졸업 후:           quoteToken → 등록 adapter 스왑 + burn → 0xdead

LPVault:
  본딩 단계:         early return (누적만, 작업 없음)
  졸업 후:           quoteToken → 절반을 token으로 스왑 → addLiquidity → LP → 0xdead

CreatorFeeVault:     quoteToken → 토큰별 누적 → creator가 ERC-20 또는 WNATIVE-unwrapped native로 claim (단계 무관)
```

---

## 수수료 요약

| 수수료 | 금액 | 시점 | 수취인 |
|--------|------|------|--------|
| 배포 수수료 | quote별 설정값 | 토큰 생성 | feeReceiver |
| 커브 프로토콜 수수료 | curveProtocolFeeRate | 본딩커브 buy/sell | feeReceiver (quote에서) |
| 스나이핑 방지 페널티 | 블록별 lookup (기본: 블록 0..6에 80/40/20/15/10/10/5%, 이후 0) | 본딩커브 buy | feeReceiver |
| 졸업 수수료 | quote별 설정값 | 졸업 시 | feeReceiver |
| 크리에이터 수수료 (커브) | 1%/3%/5% | 본딩커브 buy/sell | FeeCollector (quote에서) |
| LP 수수료 | 0.25% | NadFunPair swap | reserve에 잔류 |
| 프로토콜 수수료 (DEX) | dexProtocolFeeRate | NadFunPair swap | FeeCollector가 즉시 feeReceiver로 전달 |
| 크리에이터 수수료 (DEX) | 1%/3%/5% | NadFunPair swap | FeeCollector → CreatorFeeProcessor → Vault |
| GiwaRouter V3 프로토콜 수수료 | quote 측 dexProtocolFeeRate | canonical V3 경로 | 현재 feeReceiver |
| Uniswap V3 풀 수수료 | 등록 pool fee tier | canonical V3 pool swap | pool liquidity position 회계 |

---

## 컨트랙트 상호작용 맵

```
User → GiwaRouter
  ├─ 졸업 전 → BondingCurve
  │    ├─ anti-sniping penalty → feeReceiver
  │    ├─ protocol + creator fee → FeeCollector (creator fee 활성 시)
  │    │    ├─ protocol fee → feeReceiver
  │    │    └─ creator fee → CreatorFeeProcessor → singleton vault
  │    └─ 기본 졸업 → LPManager → 유지 중인 NadFunPair metadata
  │         └─ GiwaRouter는 졸업 후 이 V2 metadata를 거부
  │
  └─ 졸업 + UniswapV3 등록
       └─ V3SwapAdapter → canonical factory pool
            ├─ 인증 callback으로 정확한 pool input 지급
            └─ GiwaRouter quote-side protocol fee → 현재 feeReceiver

ProtocolManager는 quote별 curve/V3 fee 설정과 selector-scoped 권한을 제공합니다.
TokenRegistry는 졸업 pool, quote token, DEX type, V3 fee tier를 제공합니다.
```

---

## 핵심 불변 조건

1. **x·y=k**: `virtualQuoteReserve × virtualTokenReserve ≥ curve.k`
2. **리저브 격리**: `_totalQuoteReserved`로 커브 간 자금 탈취 방지
3. **졸업 비가역성**: `graduated = true` → 커브 거래 차단
4. **영구 graduation LP**: LPManager가 launch LP를 보관하며 remove-liquidity entrypoint 없음
5. **NadFunPair k invariant**: fee 차감 후 k가 감소하지 않음
6. **명시적 수수료 회계**: `collectFee(pair, protocolFee, creatorFee)`는 수신 balance delta가 두 구성요소를 충족해야 하며 초과분은 protocol receiver로 지급
7. **크리에이터 수수료율 허용목록**: 토큰 생성은 ProtocolManager owner가 현재 구성한 rate만 허용 (기본 정책 1%/3%/5%)
8. **크리에이터 수수료 영구**: 만료 없음 — 무기한 수수료 징수
9. **토큰 pair 전송 가드**: 졸업 전 pair 주소로의 전송 차단 (본딩 단계에서 직접 토큰 전송으로 인한 리저브 오염 방지)
10. **canonical V3 callback**: registry/factory-derived 활성 pool과 nonce-bound callback data만 swap context를 소비 가능
11. **exact-output 완전성**: 졸업한 V3 exact-output은 요청 output 전량을 제공해야 하며 부분 체결은 revert
12. **호출 범위 refund**: V3 ERC-20/native refund는 호출 이전에 존재한 router balance를 sweep할 수 없음
