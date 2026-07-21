# NadFun V2 — 로드맵 & 태스크 트래커

> 새 세션에서 이 파일을 읽으면 현재 상태와 다음 할 일을 즉시 파악할 수 있어야 한다.

---

## 현재 상태 요약 (2026-03-31)

- **브랜치:** feat/v2-custom-dex (pair native views + adapter thin wrapper)
- **테스트:** 344 tests ALL PASS
- **완료된 주요 작업:** v2.0.0 Custom DEX 전환 완료, NadFunPair AMM views 추가, NadSwapAdapter thin wrapper 리팩터링
- **다음 우선순위:** NadFun DEX Periphery (Phase 1)

---

## Phase 1: NadFun DEX Periphery ✅ (2026-06-02)

**목적:** Uniswap V2 포크에 맞는 표준 Periphery Router 배포. 외부 프로토콜/aggregator 연동 및 향후 커뮤니티 LP 지원 기반.

**블로커:** 없음. NadFunFactory/NadFunPair(core) 완료.

- [x] `NadFunRouter02` (UUPS Proxy, `src/router/NadFunRouter02.sol`) — UniswapV2Router02-compatible 독립 컨트랙트로 출시. addLiquidity/removeLiquidity(permit 지원) + 수수료 인식 멀티홉 스왑 + `createPair` + WMON 래핑/언래핑 포함.
- [x] WMON 래핑/언래핑 지원 (`addLiquidityETH`, `swapExactETHForTokens` 등 `...ETH` 변형)
- [x] optimal quote 계산 (`quote()`) — `NadFunLibrary`로 구현
- [x] 역할 분리: `NadFunRouter`(본딩커브 라이프사이클)와 `NadFunRouter02`(졸업 후 유동성 + 스왑) 분리. EIP-170 24KB 제한으로 인한 분리.
- [x] 테스트: `test/router/RouterLiquidity.t.sol`, `test/router/RouterSwap.t.sol`, `test/libraries/NadFunLibrary.t.sol`
- [x] 배포 스크립트: `script/DeployRouter02.s.sol` (퍼미션리스 신규 배포, 기존 컨트랙트 업그레이드 불필요)

---

## Phase 2: LP 마이그레이션

**목적:** 졸업 후 LP를 다른 DEX로 마이그레이션하는 기능.

**왜 필요한가:** 더 좋은 DEX가 등장했을 때 유동성을 이전할 수 있어야 함. 현재는 LP가 0xdead로 영구 잠금.

**블로커:** 없음. 바로 시작 가능.

- [ ] LP 마이그레이션 기능 구현 — LPManager에서 LP 회수 → 새 DEX에 재배치
- [ ] 마이그레이션 권한 구조 결정 — onlyOwner / AccessControl(MIGRATOR_ROLE) / 타임락
- [ ] 마이그레이션 전 유동성 선점 공격 방어

---

## Phase 3: Vault Marketplace 상품화

**목적:** Vault를 프로덕트로 상품화. 사용자가 vault를 선택하고 조합할 수 있는 마켓플레이스.

**블로커:** 프론트엔드 개발 필요. 컨트랙트 측은 VaultRegistry가 이미 준비됨.

- [ ] Vault Marketplace 프론트엔드
- [ ] 킬러 vault 추가 개발 (예: DividendVault, StakingVault)
- [ ] VaultInfo 메타데이터 확장
- [ ] Vault 운영 봇/유저 수익화 모델

---

## 완료된 Phase

### v2.0.0 Custom DEX 전환 ✅ (2026-03-30)

fee-on-transfer를 제거하고, 자체 Custom DEX(NadFunFactory/NadFunPair)로 전환. 설계 문서: `docs/plans/2026-03-30-v2-custom-dex-design.md`

- [x] Task 1: NadFunPair — Vanilla V2 Pair Fork (Solidity 0.8.24)
- [x] Task 2: NadFunFactory — V2 Factory Fork (CREATE2)
- [x] Task 3: FeeCollector — Fee Config + Collection + Settlement
- [x] Task 4: NadFunPair Fee Integration (swap() 내 fee 차감)
- [x] Task 5: CreatorFeeProcessor Simplification (swap 제거, quoteToken 직접 분배)
- [x] Task 6: Vault Updates (BurnVault + LPVault → NadFunPair 경유)
- [x] Task 7: BondingCurve Modifications (Token + NadFunFactory + creator fee → FeeCollector)
- [x] Task 8: Router & LPManager Updates (NadFunPair + FeeCollector 대응)
- [x] Task 9: Cleanup — TaxToken, V2DexAdapter, IDexAdapter, ITaxToken 등 v1 아티팩트 제거
- [x] Task 10: Integration E2E Test
- [x] Task 11: Documentation Update

### 테스트 아키텍처 리팩토링 ✅ (2026-03-21)

- [x] SetUp.t.sol 공유 베이스 컨트랙트 생성 (full stack 배포 + 헬퍼)
- [x] 24개 테스트 파일 마이그레이션 (core 10, token 4, vault 5, module 2, integration 3)
- [x] MockDexAdapter, MockLPManager, MockSwapDexAdapter, MockTokenRegistry 전부 삭제 → real 컨트랙트 사용

### CreatorFeeProcessor 싱글톤 전환 ✅ (2026-03-21)

- [x] CreatorFeeProcessor 싱글톤 아키텍처 전환 — clone → singleton
- [x] 자금 흐름 pull 패턴 전환 — push(transfer) → pull(approve + transferFrom)
- [x] Vault afterDeposit CreatorFeeProcessor 권한 체크 추가
- [x] VaultRegistry ERC-165 인터페이스 검증 추가

### Vault 싱글톤 전환 ✅ (2026-03-21)

- [x] BurnVault, LPVault, CreatorFeeVault — clone → singleton (constructor immutable)
- [x] VaultRegistry 도입 (관리자 전용, VaultType 분류)

---

## 미결정 사항

- [ ] **creator override 허용 여부** — creatorFeeRate를 creator가 프로토콜 범위 내에서 커스텀 가능하게 할지
- [ ] **CreatorFeeProcessor vault 비율 변경 가능 여부** — 생성 후 vault BPS 비율을 변경할 수 있게 할지
