# NadFun V2 — Project Guide

Bonding curve token launchpad (Solidity 0.8.24 / Foundry / Monad).

**Do not assume direction.** For every issue or recommendation: explain concrete tradeoffs, give an opinionated recommendation, then ask for input before proceeding.

---

## 🔴 Absolute rule — Test-Driven Development

**Every code change goes through TDD via `superpowers:test-driven-development` (or `/tdd`). No "add tests later".** Only doc/config/pure-scaffold changes (no code) are exempt.

- Coverage target: meaningful assertions on all paths — prefer too many tests over too few.
- Pre-commit: `superpowers:verification-before-completion` — run `forge build && forge test` before claiming completion.
- Role split under model routing (next section): **the orchestrator writes the failing tests (RED); Codex implements to green (GREEN)**. The TDD discipline itself is unchanged.

This rule overrides every other workflow rule in this file.

---

## 🔴 Absolute rule — Model routing (Fable-GPT: orchestrator / executor)

Adopted 2026-07-16 (Fable-GPT setup), replacing the previous "plan = Opus 4.8, code = Codex" routing. Fable 5 orchestrates; Codex (GPT-5.6) executes. The two systems still cross-check each other; **neither reviews or grades its own output.**

**You (the main session, Fable 5) are the orchestrator:**
- Use Fable 5 for planning, repo understanding, architecture decisions, task decomposition, and final review.
- Use codex-rescue as the executor when a task needs heavy implementation, debugging, test fixing, refactoring, or multi-file code edits.
- When delegating to Codex, use `/codex:rescue` (or `codex exec` per the delegation contract below).
- Prefer GPT-5.6 Sol medium as the daily driver for implementation tasks.
- Keep Codex tasks focused and specific.
- After Codex finishes, inspect the result yourself before accepting it (`forge build && forge test` after Codex returns). Do not blindly trust Codex output.

**GPT-5.6 tier selection:**
- **Sol medium** — daily driver. Handles ~80% of execution work. Fast, cheap, accurate enough for most implementation tasks.
- **Sol extra high** — serious reasoning: architecture decisions, task decomposition, complex debugging.
- **Terra / Luna** — pure execution once the plan is locked. Fast, minimal bugs, high-quality output on well-defined tasks.

**3-model workflow (maximum output quality at minimum cost):**
1. **Plan** with GPT-5.6 Sol extra high — full task/session/project planning, architecture, decomposition, edge cases.
2. **Critique** with Fable 5 high — find loopholes, patch loose ends, challenge assumptions. Pure reasoning, no implementation cost.
3. **Execute** with GPT-5.6 Terra/Luna — implement the battle-tested plan. Fast, clean, no waste.

The orchestrator thinks. The critic patches. The executor builds. The user reviews.

**Operating tips:**
- For heavy long-horizon tasks, pair this workflow with a goal: set the goal, let the orchestrator-executor loop run until done, surface for review.
- Run 5–7 parallel subagents on independent tasks (Codex 20x Pro plan).
- Context rot is real: after 4 `/compact` cycles, write the handoff and start the new session from it.

Artifact classification (retained):

- **Codex-owned (implementation):** `src/**` Solidity source, deployment scripts, `foundry.toml`, CI workflow files.
- **Orchestrator-owned (design/RED):** test files, test fixtures/mocks/helpers, NatSpec/comments/docs, `docs/plans/`, `tasks/` files. Tests are design artifacts — the orchestrator writes them, runs them, confirms they fail for the right reason.
- Ambiguous file → Codex (strict path) and note the call in the commit.

### Codex delegation contract (retained)

```bash
codex exec -s workspace-write \
  -c 'model="<GPT-5.6 tier per the selection above — verify the exact model id in ~/.codex/config.toml>"' \
  "<prompt>"
```

Every delegation prompt MUST contain:

1. Filesystem boundary: do NOT read `~/.claude/`, `.claude/`, or `agents/`.
2. Pointers **by repo path** to the plan/spec and the pre-written failing tests.
3. "Make the listed failing tests pass. **Do NOT modify any test file, test fixture, mock, or shared test helper.** If any looks wrong, stop and report."
4. "Before reporting done: run `forge fmt`, `forge build`, `forge test` on touched scope — all clean."
5. Scope guard: only named files/behavior, match existing conventions, list every file touched.

**Fallback:** if Codex CLI is unavailable or the same delegation fails twice, the orchestrator implements in-session and says so loudly in commit message and PR body.

---

## 🔴 Absolute rule — Cross-model review before every PR

**The model that did NOT author an artifact reviews it.**

| Artifact | Author | Reviewer |
|---|---|---|
| Specs / design docs / written plans | Orchestrator | **Codex review** before implementation |
| Code diff (default path) | Codex | **Orchestrator deep review** — pre-PR gate, procedure below |
| Code diff (fallback path only) | Orchestrator | **`/codex review`** (gstack skill) before PR |

**Orchestrator deep-review procedure:** read the FULL diff (`git diff origin/main...HEAD`) hunk by hunk — correctness, safety, test intent, naming conventions — via `/code-review` skill (high effort) or equivalent. **Record verdict + findings in PR body.** A review with no written findings does not count.

- Apply AUTO-FIX items immediately.
- For ASK items, confirm with user before applying.

---

## 🔴 Absolute rule — Test session cleanup

**When a test-involving task wraps up (before commit / before PR / before hand-off), run:**

```bash
# Stop any hanging forge/test processes
pkill -f 'forge test' 2>/dev/null || true
pkill -f 'target/debug/deps/' 2>/dev/null || true
```

`forge build` artifacts stay warm — do NOT run `forge clean` unless explicitly instructed.

---

## Quick Reference

```shell
forge build                    # 빌드
forge test                     # 전체 테스트
forge test -vvv                # 상세 로그
forge test --match-path test/fee/FeeCollector.t.sol    # 특정 파일
forge test --match-test test_settle_splitsCorrectly    # 특정 함수
forge fmt                      # 포맷 (푸시 전 필수)
```

### Document Map

| 파일 | 용도 |
|------|------|
| `README.md` | 프로젝트 개요, 아키텍처, 컨트랙트 목록 |
| `PRODUCT.md` | 프로덕트 스펙, 수수료 구조, Vault 시스템 |
| `TEST.md` | 테스트 구조, setUp 패턴, Mock 목록 |
| `docs/ARCHITECTURE.md` | 시스템 설계, 보안 매트릭스, 상태 머신 |
| `docs/PROTOCOL_FLOW.md` | Phase별 프로토콜 흐름 (영문) |
| `docs/PROTOCOL_FLOW.ko.md` | Phase별 프로토콜 흐름 (한글) |
| `docs/CONTRACTS.md` | 컨트랙트 인덱스 + 개별 문서 링크 |
| `docs/contracts/en/`, `ko/` | 컨트랙트별 상세 문서 (영문/한글) |
| `docs/plans/` | 설계 플랜 문서 (`YYYY-MM-DD-<topic>-design.md`) |
| `tasks/todo.md` | 로드맵, 현재 상태, 다음 작업, 블로커 |
| `tasks/lessons.md` | 교훈 기록 (같은 실수 방지) |

### Contract Patterns

| 패턴 | 컨트랙트 |
|------|----------|
| UUPS Proxy | BondingCurve, ProtocolManager, LPManager, TokenRegistry, VaultRegistry, FeeCollector, NadFunRouter |
| EIP-1167 Clone | Token (토큰마다 1개), NadFunPair (pair마다 1개) |
| Singleton | CreatorFeeProcessor, BurnVault, LPVault, CreatorFeeVault, NadFunFactory |
| Stateless | NadSwapAdapter |

---

## Engineering Preferences (hard constraints)

- DRY — flag repetition aggressively.
- Well-tested code is non-negotiable — prefer too many tests over too few.
- **Tests must verify real functionality, not just pass.** If a test passes too easily, question whether it's actually testing anything meaningful.
- "Engineered enough": not under-engineered (fragile, hacky) and not over-engineered (premature abstraction, unnecessary complexity).
- Handle more edge cases, not fewer — thoughtfulness > speed.
- Bias toward explicit over clever.
- **Document every feature addition.** Undocumented features are considered incomplete.
- **Documentation First.** Always update relevant documentation BEFORE modifying code. Documentation captures design intent; code implements it.

### Variable Naming Convention (Solidity)

**기본 규칙**

| 규칙 | 예시 | 설명 |
|------|------|------|
| token/quote + In/Out 구분 | `quoteIn`, `tokenOut` | 자산 종류 + 방향을 명시 |
| Amount 접미사 제거 | `quoteIn` (not `quoteAmountIn`) | 간결하게 |
| 복수형 제거 | `tokenOut` (not `tokensOut`) | 단수형 통일 |
| 정제 로직 Before/After | `quoteInAfterProtocolFee`, `tokenOutBeforeCreatorFee` | 수수료 적용 전후 명시 |
| 추상 수식어 제거 | (not `effective`, `gross`, `expected`, `total`, `net`, `actual`) | 구체적 이름 사용 |
| 약어 금지, 풀네임 사용 | `reserve0` (not `r0`), `config` (not `cfg`), `feeCollector` (not `fc`) | 가독성 우선. 축약하지 않음 |
| `_` 접미사: shadowing 방지만 | `token0_` (param), `token0` (local) | state var과 겹치는 파라미터만. local var에는 사용 금지 |
| 이벤트도 동일 규칙 | `protocolFee` (not `protocolAmount`) | 이벤트 파라미터도 변수 네이밍과 동일 규칙 |

**Fee 네이밍 규칙**

| 규칙 | 예시 | 설명 |
|------|------|------|
| Fee 종류를 명시 | `protocolFee`, `creatorFee` | `feeAmount`, `protocolAmount` 금지. fee 종류를 직접 명시 |
| Before/After에 fee 종류 포함 | `quoteInAfterProtocolFee` | `quoteInAfterFee`처럼 어떤 fee인지 생략 금지 |

**Fee 종류 목록 (프로젝트 전체)**

| Fee | 변수명 | 위치 | 설명 |
|-----|--------|------|------|
| LP Fee | `lpFee` | NadFunPair | LP 수수료 (0.25% BPS), pair에 남음 |
| Protocol Fee | `protocolFee` | BondingCurve, FeeCollector | 프로토콜 수수료 → feeReceiver |
| Creator Fee | `creatorFee` | BondingCurve, FeeCollector | 크리에이터 수수료 → CreatorFeeProcessor → vaults |
| Sniping Fee | `snipingFee` | BondingCurve | 스나이핑 방지 패널티 |
| Deploy Fee | `deployFee` | BondingCurve | 토큰 생성 수수료 |
| Graduate Fee | `graduateFee` | BondingCurve | 졸업 수수료 |

---

## Language

- Code / commit messages: English.
- **PR descriptions (titles + bodies): always Korean, written so anyone — not just the engineer who wrote the diff — can understand what changed and why.** Keep code identifiers, paths, commands, and commit hashes verbatim.
- Documentation under `docs/`: Korean preferred. Code identifiers, API paths, contract names, commands stay verbatim.
- User-facing conversation: Korean.
- This file (`CLAUDE.md`): English.

---

## Workflow Rules (always-on)

### 1) Plan First

- Non-trivial tasks (3+ steps or architectural decisions): write plan to `docs/plans/YYYY-MM-DD-<topic>-design.md` before coding.
- If something goes sideways: **STOP** and re-plan immediately — don't keep pushing.
- Write detailed specs upfront to reduce ambiguity.

### 2) Subagent Strategy

- Use subagents liberally to keep the main context window clean.
- Offload research, exploration, and parallel analysis to subagents.
- **One task per subagent** for focused execution.

### 3) Self-Improvement Loop

- After ANY correction: update `tasks/lessons.md` with the pattern.
- Write rules that prevent the same mistake.
- Review relevant lessons at session start.

### 4) Changelog After Merge

- After every PR merge, update `CHANGELOG.md` with the changes under the `[Unreleased]` section.
- Group entries by theme (Architecture, Code Quality, Testing, Security, Documentation, etc.).
- Each entry: one-line bold summary + brief explanation + PR number reference (e.g., `(#41)`).
- When cutting a release, move `[Unreleased]` entries into a new versioned section with date and tagline.

### 4.1) Git Merge Policy

- **Never squash merge.** Do not use `gh pr merge --squash`, GitHub squash merge, or any squash-equivalent flow unless the user explicitly requests it for that specific PR.
- Default PR merge mode is a normal merge commit that preserves the branch commits.
- Before merging any PR, state the intended merge mode and confirm it matches the repository/user expectation.
- If history must be repaired, do not improvise. Stop, inspect the graph, identify the exact unwanted commits/refs, then use `--force-with-lease` only after confirming the target history.

### 5) Verification Before Done

- Never mark a task complete without proving it works.
- `forge build && forge test` must pass before claiming completion.
- Ask yourself: "Would a staff engineer approve this?"

### 6) Demand Elegance (Balanced)

- For non-trivial changes: pause and ask "is there a more elegant way?"
- Skip this for simple, obvious fixes — don't over-engineer.

### 7) Autonomous Bug Fixing

- When given a bug report: just fix it. Don't ask for hand-holding.
- Point at logs, errors, failing tests — then resolve them.
- Zero context switching required from me.

---

## Branch Concept Doc

Every non-trivial side branch (`feat/*`, `fix/*`, ad-hoc names — anything that isn't `main`) keeps a one-page concept doc at `branches/<branch-name>.md` (repo root).

- **Purpose** — what this branch is for (1–3 lines). Written at branch creation.
- **Changes** — running list of what was added / fixed / removed as the branch progresses.
- **Outcome** — at PR / merge: final summary + key commit hashes + PR link.

The doc commits alongside code in the same branch. Single-commit trivial branches (typo, style, comment-only) may skip the doc.

---

## Task Management Protocol

1. **Plan First**: Write plan to `docs/plans/` or `tasks/todo.md`.
2. **Verify Plan**: Check in with me before starting implementation.
3. **Track Progress**: Mark items complete as you go.
4. **Explain Changes**: High-level summary at each batch.
5. **Document Results**: Update relevant docs + `tasks/todo.md`.
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections.

Core principles:

- **Simplicity First**: Make every change as simple as possible; minimize code impact.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.

---

## Review Framework

### 1) Architecture Review

- Overall system design and component boundaries
- Dependency graph and coupling concerns
- Data flow patterns (특히 자금 흐름: push vs pull, approve 체인)
- Upgrade safety (UUPS 스토리지 슬롯 충돌, 하위 호환)
- Security: access control, reentrancy, front-running

### 2) Code Quality Review

- Code organization and module structure
- DRY violations — be aggressive here
- Error handling patterns and missing edge cases (call these out explicitly)
- Technical debt hotspots
- Areas that are over-engineered or under-engineered

### 3) Test Review

- Test coverage gaps (unit, integration, attack)
- Test quality and assertion strength
- Missing edge case coverage — be thorough
- Untested failure modes and error paths
- **Test relevance check**: "Does this test break if and only if the feature is broken?"

### 4) Gas & Security Review

- Storage layout efficiency (packing, cold/warm access)
- Unnecessary SLOAD/SSTORE
- External call chain depth (gas cascade)
- ERC-20 approval patterns (infinite approve risks, frontrunning)
- Reentrancy vectors in callback patterns (afterDeposit, NadFunPair swap)
- Access control completeness (every state-changing function)

---

## Output Format Requirements (strict)

For each issue (bug, smell, design concern, or risk):

- Provide **Issue #** with a clear title.
- Describe the problem concretely (include file + line refs when available).
- Present **2–3 options**, including "Do nothing" where reasonable.
- For each option, specify: **implementation effort, risk, impact, maintenance burden**.
- Give an **opinionated recommendation** mapped to my preferences.
- Then explicitly ask whether I agree or want a different direction **before proceeding**.

**Number issues** (1,2,3,...) and label options with letters (A,B,C...).
Always list the recommended option **first**.

---

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health

---

# 12-rule behavioral contract (Karpathy + Chang baseline)

These rules apply to every task in this project unless explicitly overridden.
Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.

## Rule 1 — Think Before Coding
State assumptions explicitly. If uncertain, ask rather than guess.
Present multiple interpretations when ambiguity exists.
Push back when a simpler approach exists.
Stop when confused. Name what's unclear.

## Rule 2 — Simplicity First
Minimum code that solves the problem. Nothing speculative.
No features beyond what was asked. No abstractions for single-use code.
Test: would a senior engineer say this is overcomplicated? If yes, simplify.

## Rule 3 — Surgical Changes
Touch only what you must. Clean up only your own mess.
Don't "improve" adjacent code, comments, or formatting.
Don't refactor what isn't broken. Match existing style.

## Rule 4 — Goal-Driven Execution
Define success criteria. Loop until verified.
Don't follow steps. Define success and iterate.
Strong success criteria let you loop independently.

## Rule 5 — Use the model only for judgment calls
Use me for: classification, drafting, summarization, extraction.
Do NOT use me for: routing, retries, deterministic transforms.
If code can answer, code answers.

## Rule 6 — Token budgets are not advisory
Per-task: 4,000 tokens. Per-session: 30,000 tokens.
If approaching budget, summarize and start fresh.
Surface the breach. Do not silently overrun.

## Rule 7 — Surface conflicts, don't average them
If two patterns contradict, pick one (more recent / more tested).
Explain why. Flag the other for cleanup.
Don't blend conflicting patterns.

## Rule 8 — Read before you write
Before adding code, read exports, immediate callers, shared utilities.
"Looks orthogonal" is dangerous. If unsure why code is structured a way, ask.

## Rule 9 — Tests verify intent, not just behavior
Tests must encode WHY behavior matters, not just WHAT it does.
A test that can't fail when business logic changes is wrong.

## Rule 10 — Checkpoint after every significant step
Summarize what was done, what's verified, what's left.
Don't continue from a state you can't describe back.
If you lose track, stop and restate.

## Rule 11 — Match the codebase's conventions, even if you disagree
Conformance > taste inside the codebase.
If you genuinely think a convention is harmful, surface it. Don't fork silently.

## Rule 12 — Fail loud
"Completed" is wrong if anything was skipped silently.
"Tests pass" is wrong if any were skipped.
Default to surfacing uncertainty, not hiding it.
