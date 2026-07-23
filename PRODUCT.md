# GIWA Launchpad — Product Specification

> This document records product-level design decisions and current protocol behavior.
> Read it before starting a new implementation or review session.

---

## Overview

Bonding-curve token launchpad for Monad. `GiwaRouter` is the current user entry point for creation, bonding-curve trading, and canonical Uniswap V3 trading of registered graduated tokens.

V2 removes fee-on-transfer tokens. Token is a plain ERC20 with ERC20Permit, and the custom NadFunPair handles pair-level DEX fees.

**Current integration boundary:** the runtime V3 router path is implemented, but the retained `Deploy.s.sol` creation/graduation wiring still configures the legacy NadFun V2 lifecycle. It does not create an end-to-end V3 launch. Tokens created through that wiring receive V2 metadata at graduation, which `GiwaRouter` rejects on its graduated path until deployment and lifecycle wiring are migrated to `V3PoolDeployer`.

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
| Legacy DEX (NadFunPair) | `dexProtocolFeeRate` from quote via FeeCollector | 1%/3%/5% from quote via FeeCollector | 0.25% stays in reserves | Sum |
| Canonical V3 through GiwaRouter | `dexProtocolFeeRate` on quote side, sent to current `feeReceiver` | - | configured pool fee tier | Router fee + pool execution |

**BondingCurve:** curve protocol fee, anti-sniping penalty, and creator fee are charged from quote. The combined protocol+creator fee is sent to FeeCollector; FeeCollector forwards the active protocol share immediately and accumulates the creator share.
**NadFunPair:** LP fee is enforced in the invariant and remains in reserves. The DEX protocol fee + creator fee is transferred to FeeCollector.
**GiwaRouter V3:** the router applies only the current quote token's `dexProtocolFeeRate`; creator-fee settlement remains part of the retained V2/FeeCollector flow. Direct `V3SwapAdapter` calls do not add the router protocol fee.

### 3. FeeCollector

FeeCollector is deployed as a **UUPS Proxy** and centralizes protocol/creator fee accounting.

- **Per-pair fee config:** `FeeConfig { baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate }`
- **Fee collection:** NadFunPair and BondingCurve transfer quoteToken to FeeCollector, then call `collectFee(pair, protocolFee, creatorFee)`; the received balance delta must cover both declared components.
- **Immediate protocol split:** FeeCollector chooses the active protocol rate by caller (curve vs DEX), forwards the protocol share to `feeReceiver`, and accumulates only creator fees.
- **Restricted settlement:** once accumulated creator fees reach the quote token's `settlementThreshold`, an authorized settler calls `settle(pair, minAmountOut)`.
  - Creator fee → CreatorFeeProcessor.processCreatorFee() → vault distribution

### 4. CreatorFeeProcessor Pipeline (Singleton Composable Vault System)

CreatorFeeProcessor is a **singleton** shared by all tokens. It receives quoteToken from FeeCollector and distributes it to the configured vaults. Swap/buyback logic lives inside each vault.

```
FeeCollector.settle(pair, minAmountOut)
  └── accumulated creator fee → CreatorFeeProcessor.processCreatorFee(token, quoteToken, amount)
       └── Distribute to each vault[i] by BPS:
            ├── transfer(vault[i], amount)
            └── vault[i].afterDeposit(token, quoteToken, amount)
                 ├── BurnVault — buy token and burn to 0xdead
                 ├── LPVault — zap into LP and burn LP to 0xdead
                 ├── GiftVault — claimable gift balance, then burn after expiry
                 └── CreatorFeeVault — per-token accrual; configured creator claims ERC-20 or WNATIVE-unwrapped native
```

**BPS constraint:** `sum(vaults[i].bps) = 10,000` (max 5 vaults)

### 5. VaultRegistry + VaultAllocation

- **VaultRegistry** (UUPS): authority-restricted singleton vault registry. The ProtocolManager owner or selector-authorized operators can register or deactivate vault implementations, grouped by `VaultType`.
- `CreateTokenParams.vaults` = `VaultAllocation[]` (최대 5개, BPS 합계 = 10000)
- 각 VaultAllocation은 싱글톤 vault 주소 (레지스트리에서 조회) + `bps` + `setupData`
- BondingCurve에서 VaultRegistry를 통해 싱글톤 vault 주소를 조회하고 vault.setup(token, data) 호출

### 6. LP Management

- On graduation, BondingCurve transfers token + quote liquidity to LPManager.
- LPManager adds liquidity through the configured IDexAdapter and receives the LP tokens into LPManager custody.
- LPManager intentionally exposes no liquidity-removal path. Graduation LP is permanent protocol launch liquidity.
- `V3PoolDeployer` and `V3LiquidityActor` provide the V3 pool/position infrastructure, but the retained deployment script has not yet replaced the legacy BondingCurve → LPManager V2 graduation wiring.

### 7. CreateTokenParams

```
name, symbol          — token name and symbol
tokenURI              — token metadata URI
quoteToken            — quote token (WNATIVE, USDC, etc.)
creatorFeeRate        — owner-configured allowlisted creator fee rate
vaults[]              — VaultAllocation[] (vault + bps + setupData, max 5, BPS sum = 10000)
salt                  — CREATE2 salt
dexType               — registry DEX type selected for the lifecycle
creator               — token creator
buyQuoteAmount        — explicit optional initial-buy quote amount
```

**Protocol-managed fields (ProtocolManager / FeeCollector):**
- snipingPenaltyTable (per-block BPS lookup, indexed by `block.number - createdAtBlock`)
- curveProtocolFeeRate / dexProtocolFeeRate (ProtocolManager quote config, copied into FeeCollector per-pair config on creation)
- settlementThreshold (ProtocolManager quote config)

### 8. Exact-input / Exact-output Routing (BondingCurve + canonical V3)

`GiwaRouter`는 exact-input과 exact-output 두 가지 모드를 지원:
- **ExactIn**: 유저가 넣을 금액 지정, 받을 최소량 설정 (slippage protection)
- **ExactOut**: 유저가 받을 금액 지정, 넣을 최대량 설정 (slippage protection)

**BondingCurve ExactOut Buy 역산:**
1. 커브 역산: `getAmountIn(amountOut)` → effectiveAmountIn
2. Anti-sniping 역산: `effectiveAmountIn * 10000 / (10000 - penaltyBps)`
3. Creator fee 역산: `afterPenalty * 10000 / (10000 - creatorFeeRate)`
4. Protocol fee 역산: `afterCreatorFee * 10000 / (10000 - protocolFee)`

**V3 ExactOut:** buy는 풀 quote 입력에 대해 `ceil(poolQuoteIn × BPS / (BPS - dexProtocolFeeRate))`로 사용자 최대 quote를 검증하고, sell은 사용자가 받을 정확한 net quote를 기준으로 풀 gross output을 역산합니다. graduated V3 exact-output은 부분 체결을 허용하지 않습니다.

`GiwaRouter` 함수는 Params 구조체 기반이며 남은 call-scoped 입력은 유저에게 refund합니다. 졸업 여부는 `BondingCurve.getCurve`에서, DEX metadata는 `ITokenRegistry`에서 조회합니다. 졸업 전에는 BondingCurve를 호출하고, 졸업 후 `DexType.UniswapV3`만 `V3SwapAdapter`로 라우팅합니다.

### Router 패턴

`GiwaRouter`는 token registry 상태에 따라 두 실행 패턴을 사용합니다:
1. **Bonding phase:** 기존 balance-delta Core 패턴으로 quote/token을 전달하고 `BondingCurve.buy/sell`을 호출합니다.
2. **Graduated V3:** canonical pool metadata와 quote 방향을 검증하고, quote-side router fee를 계산한 뒤 정확한 pull/push balance delta로 `V3SwapAdapter.exactInput/exactOutput`을 호출합니다.
3. exact-input V3는 price limit에 의한 부분 체결과 미사용 입력 refund를 지원합니다. exact-output V3는 전량 체결을 요구합니다.
4. native quote는 등록 quote가 configured wrapped-native와 같은 경우에만 허용되며, 호출 범위의 금액만 wrap/unwrap/refund합니다.

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
├── core/           BondingCurve, ProtocolManager, LPManager, TokenRegistry, V3PoolDeployer, FeeCollector, Treasury (UUPS), CreatorFeeProcessor (singleton)
├── router/         GiwaRouter (UUPS, BondingCurve + canonical V3 routing)
├── adapters/       V3SwapAdapter plus retained V2/external adapters
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
BondingCurve Phase → Graduated (registered DEX phase)

BondingCurve Phase: 본딩커브 거래, creator fee는 quote에서 차감 → FeeCollector
Graduated V3:       GiwaRouter가 quote-side dex protocol fee 차감 → feeReceiver; V3 pool swap
Legacy graduated:   retained NadFunPair/FeeCollector path (GiwaRouter V3 path에서는 거부)
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
- Vault callback atomicity: `afterDeposit` failure reverts the full creator-fee processing/settlement transaction
- VaultRegistry deactivated vault type 검증
- Canonical V3 callback caller/context/delta 검증, missing/double callback 방어
- ERC-20/native 부분 체결 refund 및 pre-existing router balance 비침범

---

## Remaining V3 Integration Work

- [x] Canonical V3 exact-input/exact-output routing, quoting, callback authentication, and native quote handling
- [x] V3 pool deployment and initial-liquidity building blocks
- [ ] Replace retained `Deploy.s.sol` V2 creation/graduation registration with the V3 lifecycle
- [ ] Validate production quote-token/pool-fee configuration and deployment addresses per network
- [ ] Add the missing LP-principal-lock invariant suite referenced by the release validation plan

---

## 기술 스택

- Solidity 0.8.24, EVM target: london
- Framework: Foundry
- Dependencies: OpenZeppelin (contracts + upgradeable), Solady
- Chain: Monad
- 패턴: UUPS Proxy (core/router/registry/treasury 및 singleton vault 배포), EIP-1167 Clone (Token), non-upgradeable Singleton (CreatorFeeProcessor, V3SwapAdapter), Custom DEX compatibility (NadFunFactory/NadFunPair)

---

## 컨벤션

- Tests: `forge test` is the source of truth for the current test count
- Attack 테스트: `test/**/*Attack.t.sol`
- Commit: conventional commits (feat/fix/refactor/docs/test)
- 브랜치: `feat/`, `refactor/`, `fix/` prefix
- 문서: en/ko 쌍으로 유지 (`docs/contracts/en/`, `docs/contracts/ko/`)
- immutability: 새 객체 반환, 기존 변경 금지
- 파일 크기: 200-400줄 일반, 800줄 최대
