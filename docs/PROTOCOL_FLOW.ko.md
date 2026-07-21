# 프로토콜 흐름 — 전체 생명주기

## 개요

```
Token Creation → Bonding Curve Trading → Graduation → DEX Trading → Fee Settlement → Distribution
```

---

## 1단계: 토큰 생성

**진입점:** `NadFunRouter.create(params)` → `BondingCurve.create(params)` [ROUTER_ROLE 필요]

```
User ──► NadFunRouter.create() ──► BondingCurve.create()  [ROUTER_ROLE]
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
              │      Token.initialize(name, symbol, uri, pair)
              │      (10억 토큰이 Token.initialize에서 BondingCurve에게 민팅)
              │
              └── 6. 커브 상태 초기화:
                    curve.k = virtualQuoteReserve × virtualTokenReserve
                    curve.creatorFeeRate = creatorFeeRate
                    graduated = false
```

**크리에이터 수수료율:** 허용목록 검증 (1%/3%/5%만 허용, ProtocolManager)

**참고:** `snipingPenaltyTable`(블록 단위 BPS 배열, 인덱스 = `block.number - createdAtBlock`)과 quoteToken별 `settlementThreshold`는 `ProtocolManager`에서 가져온다. `FeeCollector`는 페어별 수수료 설정, 페어별 누적 creator fee, quoteToken별 tracked balance, 정산 중 `_settling` 플래그를 저장한다.

---

## 1B단계: 초기 매수 포함 생성

`BondingCurve.create()`는 통합 함수 — deployFee(quoteToken) 이후 잔여 quote가 감지되면 sniping 면제 초기 매수를 자동 실행한다.

```
User → NadFunRouter.create(params{buyQuoteAmount: X})
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
User ──► NadFunRouter.buy(params)
              │
              ├── getAmountOut() → 수수료 포함 출력량 사전 계산
              ├── require(expectedOut >= minTokensOut) → 슬리피지 사전 검증
              ├── quoteToken.transferFrom(User, BondingCurve, amount)
              │
              └── BondingCurve.buy(to, token)  ← 잔액 감지, 금액 파라미터 없음
                    │
                    ├── 1. 잔액 감지: quoteAmount = balanceOf(this) - 이전 잔액
                    ├── 2. 프로토콜 수수료 ──► feeReceiver (quote에서)
                    ├── 3. 스나이핑 방지 페널티 ──► feeReceiver
                    ├── 4. 크리에이터 수수료 ──► FeeCollector.collectFee() (quote에서)
                    ├── 5. 유효 금액 → 커브 계산 (x·y=k)
                    ├── 6. _totalQuoteReserved += effectiveQuoteIn
                    ├── 7. 토큰 전송 → 사용자 (순수 ERC20, creator fee hook 없음)
                    │
                    └── 8. 졸업 확인:
                          virtualTokenReserve == minTokenReserve → _graduate()
```

### 매도 (Token → Quote)

```
User ──► NadFunRouter.sell(params)
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
                    ├── 4. 프로토콜 수수료 ──► feeReceiver
                    ├── 5. 크리에이터 수수료 ──► FeeCollector.collectFee()
                    └── 6. 순 quoteOut ──► 사용자
```

---

## 3단계: 졸업 (DEX 마이그레이션)

**트리거:** `virtualTokenReserve == curve.minTokenReserve` (자동)

```
BondingCurve._graduate()
    │
    ├── 1. curve.graduated = true
    ├── 2. _totalQuoteReserved 해제
    ├── 3. 졸업 수수료(quote별) ──► feeReceiver
    ├── 4. 초과 토큰 소각 (DEX 가격 = 커브 가격 맞춤)
    │
    ├── 5. LPManager.addLiquidity()
    │       ├── token + quoteToken → LPManager
    │       ├── IDexAdapter.addLiquidity() → NadFunPair.mint()
    │       └── LP 토큰은 LPManager가 영구 launch liquidity로 보관
    │
    └── 6. Token.setIsGraduated()
```

---

## 4단계: DEX 거래 (NadFunPair)

### 거래 흐름

```
User ──► NadFunRouter.buy() / sell()
              │
              ├── 토큰 ──► DEX adapter (TokenRegistry 경유)
              │
              └── adapter.swap() ──► NadFunPair.swap()
                    │
                    ├── FeeCollector.getFeeConfig(pair) 조회
                    │
                    ├── LP fee (0.25%) → reserve에 잔류
                    │
                    ├── Protocol fee + Creator fee → FeeCollector
                    │     fee = quoteAmount × (creatorFeeRate + dexProtocolFeeRate) / BPS
                    │     transfer(feeCollector, fee)
                    │     FeeCollector.collectFee(pair)  // balance delta 방식, amount 파라미터 없음
                    │
                    ├── k invariant 검증
                    │
                    └── 나머지 → 사용자
```

---

## 5단계: 수수료 정산 및 분배

**트리거:** `FeeCollector.accumulatedFee(pair) >= settlementThreshold`

본딩 단계와 졸업 후 단계 모두에서 정산이 동작한다. `_settling` 플래그는 FeeCollector에 `mapping(address pair => bool)`로 저장되며, 정산 중 BondingCurve는 수수료 0을 반환하여 재귀적 수수료 누적을 방지한다.

```
FeeCollector.settle(pair)  [authorized settler only, restricted]
    │
    ├── 1. 누적된 크리에이터 수수료가 threshold 이상인지 확인
    ├── 2. _settling[pair] = true (vault 작업을 위한 수수료 면제 모드)
    ├── 3. 크리에이터 수수료 ──► CreatorFeeProcessor.processCreatorFee(token, quoteToken, creatorFeeAmount)
    │       │
    │       └── 각 vault[i]에 BPS 비율로 분배:
    │             ├── amount = creatorFeeAmount × vault[i].bps / BPS
    │             ├── transfer(vault[i], amount)
    │             └── try vault[i].afterDeposit(token, quoteToken, amount)
    │                 (vault 동작은 졸업 단계에 따라 다름 — 6단계 참조)
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
  본딩 단계:         quoteToken → BondingCurve.buy() + burn → 0xdead
  졸업 후:           quoteToken → NadSwapAdapter 스왑 + burn → 0xdead

GiftVault:
  본딩 단계:         quoteToken → BondingCurve.buy() + burn → 0xdead
  졸업 후:           quoteToken → NadSwapAdapter 스왑 + burn → 0xdead

LPVault:
  본딩 단계:         early return (누적만, 작업 없음)
  졸업 후:           quoteToken → 절반을 token으로 스왑 → addLiquidity → LP → 0xdead

CreatorFeeVault:     quoteToken → 수령인에게 직접 전송 (변경 없음, 단계 무관)
```

---

## 수수료 요약

| 수수료 | 금액 | 시점 | 수취인 |
|--------|------|------|--------|
| 배포 수수료 | quote별 설정값 | 토큰 생성 | feeReceiver |
| 커브 프로토콜 수수료 | curveProtocolFeeRate | 본딩커브 buy/sell | feeReceiver (quote에서) |
| 스나이핑 방지 페널티 | ProtocolManager 설정 가능 (기본: 99%→0% over 99분) | 본딩커브 buy | feeReceiver |
| 졸업 수수료 | quote별 설정값 | 졸업 시 | feeReceiver |
| 크리에이터 수수료 (커브) | 1%/3%/5% | 본딩커브 buy/sell | FeeCollector (quote에서) |
| LP 수수료 | 0.25% | NadFunPair swap | reserve에 잔류 |
| 프로토콜 수수료 (DEX) | dexProtocolFeeRate | NadFunPair swap | FeeCollector가 즉시 feeReceiver로 전달 |
| 크리에이터 수수료 (DEX) | 1%/3%/5% | NadFunPair swap | FeeCollector → CreatorFeeProcessor → Vault |

---

## 컨트랙트 상호작용 맵

```
                    ┌─────────────┐
                    │    User     │
                    └──────┬──────┘
                           │
                    ┌──────┴──────┐
                    │ NadFunRouter│
                    │ (create/    │
                    │  buy/sell)  │
                    └──┬──────┬───┘
                       │      │
          ┌────────────┘      └────────────┐
          ▼ (졸업 전)              (졸업 후) ▼
    ┌─────────────┐              ┌──────────────┐
    │BondingCurve │              │NadSwapAdapter │
    │  (create    │              │  (swap)       │
    │   buy/sell  │              └──────┬────────┘
    │  _graduate) │                     │
    └──┬───┬──────┘                     ▼
       │   │                     ┌──────────────┐
       │   │ creator fee         │NadFunPair    │
       │   │     ┌──────────────►│(swap + fee)  │
       │   └────►│               └──────┬───────┘
       │         │                      │ fee
       │         │                      │
       ▼         ▼                      ▼
    ┌─────────────────────────┐
    │    FeeCollector         │
    │  (config + 누적         │
    │   + 정산)               │
    └────┬───────┬────────────┘
         │       │
         │       ▼
         │  ┌─────────────────┐
         │  │  CreatorFeeProcessor   │
         │  │(vault 분배)     │
         │  └────┬────────────┘
         │       │
         │       └──► 싱글톤 Vault (BPS별):
         │            ├── BurnVault    → 바이백 소각
         │            ├── LPVault      → 유동성 추가 + LP 소각
         │            └── CreatorFeeVault     → 직접 전송
         │
         └──► 수수료 수신자 (프로토콜 수수료)

    ┌────────────────┐  ┌──────────┐  ┌──────────────┐
    │ProtocolManager │  │LPManager │  │NadFunFactory │
    │(수수료+creatorFee+   │  │(LP 잠금) │  │(pair 배포)   │
    │ 기축토큰 통합) │  └──────────┘  └──────────────┘
    └────────────────┘
```

---

## 핵심 불변 조건

1. **x·y=k**: `virtualQuoteReserve × virtualTokenReserve ≥ curve.k`
2. **리저브 격리**: `_totalQuoteReserved`로 커브 간 자금 탈취 방지
3. **졸업 비가역성**: `graduated = true` → 커브 거래 차단
4. **영구 graduation LP**: LPManager가 launch LP를 보관하며 remove-liquidity entrypoint 없음
5. **NadFunPair k invariant**: fee 차감 후 k가 감소하지 않음
6. **수수료 분할 비율**: `creatorFeeRate / (creatorFeeRate + activeProtocolFeeRate)` 비율이 `collectFee()`에서 유지됨
7. **크리에이터 수수료율 허용목록**: 1%/3%/5%만 허용 (ProtocolManager)
8. **크리에이터 수수료 영구**: 만료 없음 — 무기한 수수료 징수
9. **토큰 pair 전송 가드**: 졸업 전 pair 주소로의 전송 차단 (본딩 단계에서 직접 토큰 전송으로 인한 리저브 오염 방지)
