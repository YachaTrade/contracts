# Vault 싱글톤 아키텍처 전환 — 진행 상태

## 브랜치: `refactor/vault-singleton-migration`

## 현재 상태: Phase 8 (CreatorFeeProcessor 싱글톤) 완료

---

## 완료된 작업 (Phase 1~6)

### Phase 1: IVault 인터페이스 ✅
- `src/interfaces/IVault.sol` — `initialize(InitParams)` 제거, `afterDeposit(token, quoteToken, amount)` 시그니처, `setup()` 추가 완료

### Phase 2: Vault 싱글톤 구현 ✅
- `src/vault/BurnVault.sol` — immutable constructor(tokenRegistry), indexed 이벤트, setup() no-op
- `src/vault/LPVault.sol` — immutable constructor(tokenRegistry), indexed 이벤트, setup() no-op
- `src/vault/CreatorFeeVault.sol` — mapping(token→recipient), setup(), authorized caller

### Phase 3: VaultRegistry ✅
- `src/interfaces/IVaultRegistry.sol` — VaultType enum (Custom, Burn, LP, Transfer), VaultInfo에 vaultType 필드 추가
- `src/vault/VaultRegistry.sol` — register(vault, name, description, vaultType), getVaultType(), onlyOwner

### Phase 4: BondingCurve ✅
- `src/interfaces/IBondingCurve.sol` — VaultAllocation: vault(싱글톤 주소), bps, setupData
- `src/core/BondingCurve.sol` — _setupVaults() (clone 제거), VaultRegistry.isActive() 체크, setup() 호출

### Phase 5: CreatorFeeProcessor ✅
- `src/token/CreatorFeeProcessor.sol` — afterDeposit(token, quoteToken, amount) 호출
- `src/interfaces/ICreatorFeeProcessor.sol` — VaultCallbackFailed 이벤트

### Phase 6: 테스트 ✅
- `forge build` 통과
- `forge test` 254 tests 전체 통과 (0 failed)

---

## Phase 7: 문서 업데이트 ✅

17개 문서 파일 전부 싱글톤 패턴으로 업데이트 완료.

### 변경 필요한 핵심 키워드
- "EIP-1167 Clone" → "Singleton" (BurnVault, LPVault, CreatorFeeVault만. Token, CreatorFeeProcessor는 여전히 clone)
- "initialize(InitParams)" → "constructor(immutable) + setup()"
- "vault clone 배포" → "싱글톤 vault 주소 직접 사용"
- "implementation 주소" → "싱글톤 vault 주소"
- "비허가 vault 템플릿 레지스트리" → "관리자 전용 싱글톤 vault 레지스트리"
- "vault clone들" → "싱글톤 vault들"
- "afterDeposit(quoteToken, amount)" → "afterDeposit(token, quoteToken, amount)"
- DividendVault 참조 모두 제거 (더 이상 존재하지 않음)
- VaultInfo에 vaultType 필드 추가 반영
- VaultRegistry register() 시그니처에 VaultType 파라미터 추가 반영

### 업데이트 필요한 파일 목록

#### 주요 문서
1. `docs/ARCHITECTURE.md` — Vault Layer 섹션, 클론 배포 순서, Contract Map, Deployment Order, Security
2. `docs/PROTOCOL_FLOW.md` — Phase 1 토큰 생성, Phase 5 크리에이터 수수료 분배, Phase 6 수익 분배, Contract Interaction Map
3. `docs/PROTOCOL_FLOW.ko.md` — 위와 동일 (한국어)
4. `docs/CONTRACTS.md` — Contract Patterns 테이블, IVault/IVaultRegistry 설명
5. `PRODUCT.md` — VaultRegistry 설명, 폴더 구조, CreateTokenParams

#### Vault 문서 (en)
6. `docs/contracts/en/vault/BurnVault.md` — Pattern: Singleton, constructor, afterDeposit 시그니처
7. `docs/contracts/en/vault/LPVault.md` — 동일
8. `docs/contracts/en/vault/CreatorFeeVault.md` — 동일 + setup/mapping
9. `docs/contracts/en/vault/VaultRegistry.md` — VaultType, onlyOwner register
10. `docs/contracts/en/interfaces/IVault.md` — 새 인터페이스 반영
11. `docs/contracts/en/interfaces/IVaultRegistry.md` — VaultType enum, register 시그니처

#### Vault 문서 (ko)
12. `docs/contracts/ko/vault/BurnVault.md`
13. `docs/contracts/ko/vault/LPVault.md`
14. `docs/contracts/ko/vault/CreatorFeeVault.md`
15. `docs/contracts/ko/vault/VaultRegistry.md`
16. `docs/contracts/ko/interfaces/IVault.md`
17. `docs/contracts/ko/interfaces/IVaultRegistry.md`

### 검증 ✅
1. `forge build` 통과 확인 ✅
2. `forge test` 254 tests 전체 통과 (0 failed) ✅
3. 문서 내용이 실제 코드와 일치하는지 검증 ✅

---

## Phase 8: CreatorFeeProcessor 싱글톤 전환 ✅

### 변경 내용
- `ICreatorFeeProcessor.sol` — InitParams/initialize() 제거, setup(token, vaults) + processCreatorFee(token, ...) 3인자
- `CreatorFeeProcessor.sol` — constructor(immutable) + mapping(token => VaultSlot[]) 싱글톤 재작성
- ~~`TaxToken.sol`~~ (v2에서 제거됨 — Token으로 대체, settlement 로직 불필요)
- `IBondingCurve.sol` — Curve struct에서 creatorFeeProcessor 필드 제거
- `BondingCurve.sol` — MODULE_CREATOR_FEE_PROCESSOR 모듈 통합, clone 배포 제거
- `Deploy.s.sol` — 배포 순서 변경 (BC → CreatorFeeProcessor singleton → setModule)
- 전체 테스트 20개 파일 업데이트
- 문서 15개 파일 업데이트

### 검증 ✅
1. `forge build` 통과 ✅
2. `forge test` 257 tests 전체 통과 (0 failed) ✅
3. 문서 업데이트 완료 ✅
