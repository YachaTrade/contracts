# NadFun V2 — Product Specification

> This document records product-level design decisions and current protocol behavior.
> Read it before starting a new implementation or review session.

---

## Overview

Bonding-curve token launchpad for Monad. The protocol manages the full lifecycle:
token creation → bonding-curve trading → DEX graduation → fee collection → creator-fee distribution.

V2 removes fee-on-transfer tokens. Token is a plain ERC20 with ERC20Permit, and the custom NadFunPair handles pair-level DEX fees.

---

## Key Design Decisions

### 1. ProtocolManager

FeeManager, AdminModule, and QuoteManager are consolidated into **ProtocolManager**.

Managed configuration:
- **Fees:** `curveProtocolFeeRate`, `dexProtocolFeeRate`, `deployFee`, `graduateFee`, `feeReceiver`
- **Creator fee allowlist:** `allowedCreatorFeeRates` (1%/3%/5%)
- **Anti-sniping:** `snipingPenaltyTable` (per-block BPS lookup, indexed by `block.number - createdAtBlock`)
- **Quote tokens:** per-token `QuoteConfig` including virtual reserves, graduation reserve, fees, and `settlementThreshold`

### 2. Fee Structure

All protocol/creator fees are charged in the quote token.

| Phase | Protocol Fee | Creator Fee | LP Fee | User Cost |
|-------|--------------|-------------|--------|-----------|
| Bonding curve | `curveProtocolFeeRate` from quote | 1%/3%/5% from quote | - | Sum |
| DEX (NadFunPair) | `dexProtocolFeeRate` from quote via FeeCollector | 1%/3%/5% from quote via FeeCollector | 0.25% stays in reserves | Sum |

**BondingCurve:** curve protocol fee, anti-sniping penalty, and creator fee are charged from quote. The combined protocol+creator fee is sent to FeeCollector; FeeCollector forwards the active protocol share immediately and accumulates the creator share.
**NadFunPair:** LP fee is enforced in the invariant and remains in reserves. The DEX protocol fee + creator fee is transferred to FeeCollector.

### 3. FeeCollector

FeeCollector is deployed as a **UUPS Proxy** and centralizes protocol/creator fee accounting.

- **Per-pair fee config:** `FeeConfig { baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate }`
- **Fee collection:** NadFunPair and BondingCurve transfer quoteToken to FeeCollector, then call `collectFee(pair)`.
- **Immediate protocol split:** FeeCollector chooses the active protocol rate by caller (curve vs DEX), forwards the protocol share to `feeReceiver`, and accumulates only creator fees.
- **Restricted settlement:** once accumulated creator fees reach the quote token's `settlementThreshold`, an authorized settler calls `settle(pair)`.
  - Creator fee → CreatorFeeProcessor.processCreatorFee() → vault distribution

### 4. CreatorFeeProcessor Pipeline (Singleton Composable Vault System)

CreatorFeeProcessor is a **singleton** shared by all tokens. It receives quoteToken from FeeCollector and distributes it to the configured vaults. Swap/buyback logic lives inside each vault.

```
FeeCollector.settle()
  └── accumulated creator fee → CreatorFeeProcessor.processCreatorFee(token, quoteToken, amount)
       └── Distribute to each vault[i] by BPS:
            ├── transfer(vault[i], amount)
            └── try vault[i].afterDeposit(token, quoteToken, amount)
                 ├── BurnVault — buy token and burn to 0xdead
                 ├── LPVault — zap into LP and burn LP to 0xdead
                 ├── GiftVault — claimable gift balance, then burn after expiry
                 └── CreatorFeeVault — direct transfer to configured recipient
```

**BPS constraint:** `sum(vaults[i].bps) = 10,000` (max 5 vaults)

### 5. VaultRegistry + VaultAllocation

- **VaultRegistry** (UUPS): admin-controlled singleton vault registry. Only the owner can register or deactivate vault implementations, grouped by `VaultType`.
- `CreateTokenParams.vaults` = `VaultAllocation[]` (최대 5개, BPS 합계 = 10000)
- 각 VaultAllocation은 싱글톤 vault 주소 (레지스트리에서 조회) + `bps` + `initData`
- BondingCurve에서 VaultRegistry를 통해 싱글톤 vault 주소를 조회하고 vault.setup(token, data) 호출

### 6. LP Management

- On graduation, BondingCurve transfers token + quote liquidity to LPManager.
- LPManager adds liquidity through the configured IDexAdapter and receives the LP tokens into LPManager custody.
- LPManager intentionally exposes no liquidity-removal path. Graduation LP is permanent protocol launch liquidity.

### 7. CreateTokenParams

```
name, symbol          — token metadata
quoteToken            — quote token (WMON, USDC, etc.)
creatorFeeRate        — creator fee rate (allowlist: 1%/3%/5%)
vaults[]              — VaultAllocation[] (vault + bps + setupData, max 5, BPS sum = 10000)
salt                  — CREATE2 솔트
creator               — token creator
```

**Protocol-managed fields (ProtocolManager / FeeCollector):**
- snipingPenaltyTable (per-block BPS lookup, indexed by `block.number - createdAtBlock`)
- curveProtocolFeeRate / dexProtocolFeeRate (ProtocolManager quote config, copied into FeeCollector per-pair config on creation)
- settlementThreshold (ProtocolManager quote config)

### 8. ExactOut Support (BondingCurve + DEX)

NadFunRouter는 exactIn과 exactOut 두 가지 모드를 지원:
- **ExactIn**: 유저가 넣을 금액 지정, 받을 최소량 설정 (slippage protection)
- **ExactOut**: 유저가 받을 금액 지정, 넣을 최대량 설정 (slippage protection)

**BondingCurve ExactOut Buy 역산:**
1. 커브 역산: `getAmountIn(amountOut)` → effectiveAmountIn
2. Anti-sniping 역산: `effectiveAmountIn * 10000 / (10000 - penaltyBps)`
3. Creator fee 역산: `afterPenalty * 10000 / (10000 - creatorFeeRate)`
4. Protocol fee 역산: `afterCreatorFee * 10000 / (10000 - protocolFee)`

**DEX ExactOut:** pair-level fee 포함 역산 공식 사용.

NadFunRouter 함수는 Params 구조체 기반. 남은 입력은 유저에게 refund.
NadFunRouter는 ITokenRegistry로 graduation 상태를 조회하여 BondingCurve 직접 호출 또는 IDexAdapter를 통한 DEX 라우팅을 자동 수행.

### Router 패턴

NadFunRouter는 사전 계산 → 슬리피지 체크 → 전송 → Core 호출 패턴:
1. `getAmountOut(token, amountIn, isBuy)` — fee/penalty/creator fee 포함 net output 계산
2. 슬리피지 체크 (expectedOut vs minOut)
3. `safeTransferFrom(user, target, amount)`
4. `Core.buy(to, token)` / `Core.sell(to, token)` — balance 변화 감지

BondingCurve Core는 amount 파라미터 없이 balance 변화로 입금량 결정 (Uniswap V2 Pair 패턴).

### 9. 커브 수학

- `curve.k = virtualQuoteReserve × virtualTokenReserve` (초기값의 곱)
- virtualTokenReserve는 ProtocolManager의 QuoteConfig에서 설정 (하드코딩 아님)
- Token 실제 발행량은 1B 고정
- `curve.initialTokenReserve` 구조체 필드로 초기값 저장 (졸업 체크용)

---

## 폴더 구조

```
src/
├── core/           BondingCurve, ProtocolManager, LPManager, TokenRegistry, FeeCollector (UUPS), CreatorFeeProcessor (singleton)
├── router/         NadFunRouter (UUPS, direct BondingCurve calls + IDexAdapter DEX routing)
├── dex/            NadFunFactory (singleton), NadFunPair (per-pair)
├── token/          Token (EIP-1167 clone, ERC20 + Permit)
├── vault/          VaultRegistry (UUPS), BurnVault, LPVault, CreatorFeeVault (singletons)
├── interfaces/
└── libraries/      BondingCurveLibrary, Math, UQ112x112, Constants
```

---

## Token State

v2에서는 v1의 4단계 상태 머신이 제거됨. Token은 순수 ERC20이며, 졸업 여부만 추적:

```
BondingCurve Phase → Graduated (DEX Phase)

BondingCurve Phase: 본딩커브 거래, creator fee는 quote에서 차감 → FeeCollector
Graduated:          NadFunPair 거래, fee는 pair swap()에서 차감 → FeeCollector
```

Creator fee는 영구적 (만료 없음).

---

## Anti-Sniping

- 블록 단위 룩업 테이블 (`ProtocolManager.snipingPenaltyTable`). 인덱스 = `block.number - curve.createdAtBlock`. 길이를 벗어나면 페널티 0
- `block.timestamp`가 아니라 `block.number` 기반이므로 검증자의 타임스탬프 미세 조작에 면역
- 기본 곡선 (BPS): `[8000, 4000, 2000, 1500, 1000, 1000, 500]` — 블록 0=80%, 1=40%, 2=20%, 3=15%, 4=10%, 5=10%, 6=5%, 7+=0%
- 패널티분은 feeReceiver로 전송
- Flash loan 졸업 공격을 경제적으로 불가능하게 만듦 (생성 블록에서 80% 페널티)
- 관리자가 ProtocolManager의 `setSnipingPenaltyTable(uint256[])`로 곡선 자체를 갱신 가능 (컨트랙트 업그레이드 불필요)

---

## Security

공격 벡터 테스트 완료 (attack test 파일):
- Cross-curve reserve theft (`_totalQuoteReserved`)
- Direct buy without transfer
- Flash loan graduation
- Reentrancy during graduation (`nonReentrant`)
- Post-graduation buy/sell (`AlreadyGraduated`)
- NadFunPair fee bypass 방어 (k invariant 검증)
- Double LP, extreme fees, disallowed creator fee rates
- Vault callback failure resilience (try/catch — vault 실패 시 CreatorFeeProcessor 중단 안 함)
- VaultRegistry deactivated vault type 검증

---

## Phase 2 TODO

`tasks/todo.md` 참조:
- [ ] LP 마이그레이션 기능 (NadFunPair → 자체 DEX V3)
- [ ] 마이그레이션 권한 구조 (onlyOwner / AccessControl / 타임락)
- [ ] 마이그레이션 선점 공격 방어
- [ ] creator override 허용 여부 (creatorFeeRate 등)

---

## 기술 스택

- Solidity 0.8.24, EVM target: london
- Framework: Foundry
- Dependencies: OpenZeppelin (contracts + upgradeable), Solady
- Chain: Monad
- 패턴: UUPS Proxy (core/modules/FeeCollector), EIP-1167 Clone (Token), Singleton (CreatorFeeProcessor, vault layer: BurnVault, LPVault, CreatorFeeVault), Custom DEX (NadFunFactory/NadFunPair)

---

## 컨벤션

- Tests: `forge test` is the source of truth for the current test count
- Attack 테스트: `test/**/*Attack.t.sol`
- Commit: conventional commits (feat/fix/refactor/docs/test)
- 브랜치: `feat/`, `refactor/`, `fix/` prefix
- 문서: en/ko 쌍으로 유지 (`docs/contracts/en/`, `docs/contracts/ko/`)
- immutability: 새 객체 반환, 기존 변경 금지
- 파일 크기: 200-400줄 일반, 800줄 최대
