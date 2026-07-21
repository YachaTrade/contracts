# Lessons Learned

교정/실수/발견 사항을 기록하여 같은 실수를 반복하지 않기 위한 문서.
CLAUDE.md §3 "Self-Improvement Loop" 규칙에 따라 유지.

---

## 아키텍처

### Clone → Singleton 전환 시 체크리스트
- **날짜:** 2026-03-21
- **맥락:** CreatorFeeProcessor를 EIP-1167 clone에서 singleton으로 전환
- **교훈:**
  1. `initialize(InitParams)` → `constructor(immutable) + setup(token, config)` 패턴으로 변경 시, 모든 테스트 파일의 setUp()도 동시에 변경해야 함 (20개 파일 영향)
  2. push 패턴(transfer → call) → pull 패턴(approve → transferFrom) 전환 시, `vm.expectEmit`의 위치가 중요 — approve 이벤트가 먼저 발생하므로 expectEmit은 approve 이후에 배치
  3. `predictAddresses()`처럼 clone 주소를 예측하는 유틸도 싱글톤 반영 필요 (놓치기 쉬움)
  4. Forge는 `--match-path`로 특정 파일만 테스트해도 **전체 파일을 컴파일**하므로, 하나의 파일만 고치고 테스트할 수 없음 — 관련 파일 전부 동시에 수정해야 함

### Vault에 권한 체크 추가 시
- **날짜:** 2026-03-21
- **맥락:** BurnVault/LPVault/CreatorFeeVault의 afterDeposit에 CreatorFeeProcessor 권한 체크 추가
- **교훈:**
  1. IVault에 IERC165 상속 추가 시, 모든 IVault 구현체(프로덕션 + 테스트 mock)에 `supportsInterface()` 추가 필요
  2. VaultRegistry 테스트에서 `makeAddr()`로 만든 주소는 코드가 없어 ERC165 체크 실패 — 실제 mock contract 배포 필요

---

## 테스트

### Mock 패턴
- MockSwapDexAdapter: 1:1 스왑 시뮬레이션 (가장 자주 사용)
- MockTokenRegistry: adapter 매핑 + register/getTokenInfo
- NoopVault: afterDeposit no-op (권한 테스트용)
- 테스트에서 `vm.prank(authorized)` → `setup()` / `vm.prank(token)` → `processCreatorFee()` 패턴 반복

---

## 워크플로우

### PR merge 방식
- **날짜:** 2026-04-15
- **맥락:** PR을 merge하면서 기본값을 확인하지 않고 squash merge를 사용해 dev 히스토리를 오염시켰고, 이후 force-with-lease로 normal merge 히스토리를 재구성해야 했음.
- **교훈:**
  1. PR merge 시 squash merge는 금지. 사용자가 해당 PR에 대해 명시적으로 요청한 경우에만 가능.
  2. 기본 merge 방식은 branch commit을 보존하는 normal merge commit.
  3. merge 실행 전 `gh pr merge` 옵션을 명확히 확인하고, 의도한 merge mode를 사용자에게 말한 뒤 진행.
  4. 히스토리 수습이 필요하면 먼저 graph/ref를 정확히 확인하고, 대상 히스토리를 확정한 뒤 `--force-with-lease`만 사용.

### PR 분리
- **날짜:** 2026-03-21
- **교훈:** 하나의 브랜치에 관련 없는 2개 작업을 쌓지 말 것. 나중에 PR을 분리하려면 별도 브랜치를 만들어 cherry-pick해야 해서 번거로움. 처음부터 작업 단위로 브랜치를 분리하는 게 효율적.

### 문서 우선
- CLAUDE.md 규칙: "Documentation First" — 코드 전에 문서 업데이트
- 실제로 지켜짐: 모든 PR에서 문서 업데이트 포함

### 브랜치 베이스 확인
- **날짜:** 2026-05-07
- **맥락:** sniping 페널티 구조 변경 작업을 시작할 때 사용자에게 베이스를 묻지 않고 dev에서 바로 브랜치를 땄다가, 사용자가 audit/zenith를 원해 다시 베이스를 갈아야 했음. dev와 audit/zenith는 ProtocolManager / Deploy 등 손대는 파일에서 diff가 100라인 이상.
- **교훈:**
  1. 작업 시작 시 작업 베이스(audit/zenith vs dev vs main)는 항상 사용자에게 확인.
  2. 베이스가 다르면 코드의 시그니처/필드 이름까지 다를 수 있어서 사전 grep을 베이스에서 다시 돌려야 함.

### 곡선/공식 변경 시 의존 가정 전수 점검
- **날짜:** 2026-05-07
- **맥락:** sniping 페널티 곡선을 99% peak → 80% peak로 낮추니 `totalFeeRate >= BPS`를 가정하던 기존 revert 테스트(`test_attack_flashLoanGraduation_penaltyMakesUnprofitable`, `test_getAmountIn_buy_withSnipingPenalty`, `test_exactOutBuy_withSnipingPenalty`, `test_buy_protocolFeePlusCreatorFeePlusSnipingPenalty`)들이 모두 깨짐. peak가 86.5% → buy가 revert 안 함.
- **교훈:**
  1. 페널티/수수료 max 값을 변경할 때 `totalFeeRate >= BPS` / `quoteInAfterFees == 0` 가정에 의존하던 테스트를 모두 grep으로 찾아 의도를 재정의.
  2. "공격이 막힌다"의 표현을 "buy가 revert한다"가 아니라 "공격자에게 비경제적이다(수수료가 입력의 대부분을 가져간다)"로 옮기는 편이 곡선 튜닝에 강건함.

### 시간/블록 단위 변경 시 테스트 전체 검색
- **날짜:** 2026-05-07
- **맥락:** sniping 윈도우를 `block.timestamp` 기반에서 `block.number` 기반으로 옮기면서 `vm.warp(block.timestamp + 100 minutes)`만으로 sniping을 건너뛰던 테스트들이 silently 깨짐 (warp는 block.number를 움직이지 않음). 22 군데 발견되어 일괄로 `vm.roll(block.number + N)`을 추가해야 했음.
- **교훈:**
  1. anti-X 윈도우의 단위(시간 ↔ 블록)를 바꿀 때는 테스트가 사용한 skip 방식(`vm.warp` / `vm.roll`)도 같이 바꿔야 함. 한쪽만 바꾸면 컴파일은 통과하면서 의도와 다른 상태로 테스트가 도는 위험.
  2. `_skipAntiSniping()` 같은 단일 helper로 skip 로직을 모아두면 단위 전환 시 1곳만 손대면 됨. 단, 인라인 `vm.warp(...)` 호출들도 잡아야 하므로 grep으로 직접 검색.

## 2026-06-11: codex exec 프롬프트의 백틱은 쌍따옴표 안에서 셸 치환됨
- **증상:** `codex exec "...\`bool active;\`..."` 형태로 위임 시 zsh가 백틱을 command substitution으로 실행 → 프롬프트 변형, codex가 빈 작업으로 exit 0 (출력 파일엔 "(eval): command not found"만 남음).
- **규칙:** codex 위임 프롬프트는 반드시 quoted heredoc(`<< 'EOF'`)으로 /tmp 파일에 쓰고 `"$(cat file)"`로 전달. 프롬프트 안에 백틱·$()를 자유롭게 쓸 수 있게 됨.
- **검증 습관:** codex exit 0이어도 보고 본문과 `git diff --stat`로 실작업 여부를 항상 확인 (이번에 diff stat 비교로 잡음).

## 2026-06-13: fresh 토큰 졸업 헬퍼는 _skipAntiSniping 이후에
- **증상:** 통합 테스트에서 `_createTokenWith(...)` 직후 `_graduateToken(token)` 호출 → 졸업 buy가 80% sniping 페널티를 물어 800k quote로도 졸업 실패 ("Token should be graduated" revert). Codex GREEN 단계에서 발견.
- **규칙:** 테스트에서 갓 생성한 토큰에 대량 buy(졸업 포함)를 하기 전에는 반드시 `_skipAntiSniping()`을 먼저 호출. 하니스 setUp 끝의 글로벌 skip은 **그 이후 생성된 토큰**에는 효력이 없다 (sniping 윈도우는 토큰 생성 블록 기준).

## 2026-06-13: 코어 직접 호출 vs 라우터 재사용 판단 기준
- **맥락:** DividendVault 본딩 buy lane 설계에서 BondingCurve 직접 호출 어댑터를 제안했으나, 사용자 지적으로 NadFunRouter wrapper로 전환. 라우터가 졸업 분기(커브 vs DEX)와 exact-in 환불 계산을 이미 소유 → 직접 호출이면 이 로직을 중복 구현해야 했음.
- **규칙:** "라우터 거치지 않기"(FeeTo 77d70cd 방향)는 라우터 hop이 순수 오버헤드일 때만 옳다. 분기·환불 같은 실질 로직이 라우터에 있으면 wrapper 재사용이 DRY. 판단 기준은 "라우터를 빼면 어떤 로직을 복제하게 되는가".

## 2026-06-13: 상위 컴포넌트를 어댑터 인터페이스로 감싸지 말 것
- **맥락:** DividendVault V2 변환을 NadFunRouter로 처리하면서, 처음엔 `NadFunRouterAdapter`(IDexAdapter wrapper)로 감쌌다. 사용자가 "nadfunrouter는 dexadapter 형식 안 따르는데"라고 지적 → executeConversion hop 루프에 `hop.adapter == router` 직접 분기로 전환(Option C).
- **규칙:** 풀/페어용 저수준 인터페이스(IDexAdapter: push 패턴, pair 주소, 7-메서드)에 상위 라우터를 끼우려 하면 신호가 온다 — 7개 중 6개를 NotSupported로 revert, `pair` 같은 필드를 다른 의미로 오버로드. 그럴 땐 wrapper 대신 소비자(여기선 vault 루프)에 분기를 추가하는 게 더 정직하고 표면적도 작다(컨트랙트 1개 + reverting stub 제거).
- **판단 기준:** "이 추상화에 끼우려고 필드를 재해석하거나 메서드 대부분을 막아야 하나?" → yes면 추상화가 안 맞는 것. 분기로 풀어라.
- **부수효과:** wrapper 제거로 중계 단계(adapter→vault forward)도 사라짐 — router가 vault(msg.sender)에서 직접 pull/refund하므로 vault의 잔액-델타 회계가 그대로 성립.

## 2026-06-13: redund-해 보인다고 lane 들어내기 전에 입력 shape 전수 확인
- **증상:** executeBondingBuy를 router hop으로 통합하면서 "라우터가 졸업 V2를 커버하니 nadSwapAdapter lane은 redundant"라 판단해 통째로 삭제(Option C). 사용자가 "nadswapadapter 없애면 안 됐다, USDC↔WMON은 nadfunrouter로 안 된다"고 정정 → 복원.
- **근본 원인:** 라우터는 "토큰 주소"로만 시장을 해석한다(nad.fun V2 토큰 buy 전용). 일반 NadFunPair 풀(USDC/WMON, cross-quote 중간 다리)은 임의 pair를 받아야 하므로 라우터로 표현 불가 — nadSwapAdapter가 그 역할. 졸업 V2 토큰 하나만 보면 둘이 겹쳐 보이지만, **입력 shape(토큰 주소 vs 임의 pair 주소)가 다르다.**
- **규칙:** 컴포넌트가 "겹쳐 보인다"고 제거하기 전에, 그게 받는 **입력의 전체 집합**을 확인하라. 한 가지 케이스(졸업 토큰 buy)에서 겹친다고 전체가 redundant인 건 아니다. router=토큰 buy, nadSwap=임의 풀 swap, uni=외부 풀 — 역할이 입력으로 갈린다.
