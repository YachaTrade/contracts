# GIWA Launchpad 컨트랙트

등록된 졸업 토큰을 canonical Uniswap V3 풀로 라우팅하는 본딩 커브 토큰 런치패드입니다. Monad용으로 구축되었습니다.

> **통합 상태:** `GiwaRouter`와 `V3SwapAdapter`가 현재 사용자 대상 V3 거래 경로를 제공합니다. 다만 유지 중인 `Deploy.s.sol`의 생성/졸업 배선은 아직 레거시 NadFun V2 경로를 등록하며, end-to-end V3 생명주기를 구성하지 않습니다. 새 토큰은 `GiwaRouter`를 통해 본딩 커브에서 거래할 수 있지만, 졸업 후 V2 메타데이터는 배포 배선이 마이그레이션될 때까지 V3 라우터 경로에서 거부됩니다.

## 아키텍처

```
src/
├── core/       BondingCurve, ProtocolManager, LPManager, TokenRegistry, V3PoolDeployer, FeeCollector, Treasury (UUPS); CreatorFeeProcessor (singleton)
├── router/     GiwaRouter (UUPS)
├── token/      Token (EIP-1167 clone)
├── dex/        NadFunFactory (singleton), NadFunPair (per-pair)
├── vault/      VaultRegistry, DividendVault, BurnVault, LPVault, CreatorFeeVault (singleton UUPS proxies)
├── adapters/   V3SwapAdapter, NadSwapAdapter, UniswapV2ExternalAdapter, UniswapV3ExternalAdapter
├── interfaces/
└── libraries/  BondingCurveLibrary, Math, UQ112x112, Constants
```

### 토큰 생명주기

1. **생성** -- 생성자가 `VaultAllocation[]`과 함께 `GiwaRouter.create()`를 호출합니다. 현재 BondingCurve 배포 경로는 Token 클론(일반 ERC20 + Permit)을 배포하고, 레거시 NadFunFactory/NadFunPair 메타데이터와 vault 설정을 구성하며 `deployFee`를 부과합니다.
2. **거래 (본딩 커브)** -- 졸업 전에는 사용자가 `GiwaRouter`를 통해 매수/매도합니다. 가격과 curve 프로토콜/크리에이터 수수료는 BondingCurve가 계산합니다. ERC-20 quote와 wrapped-native quote를 지원하며, native 호출은 토큰의 quote 토큰이 라우터에 설정된 wrapped-native와 같아야 합니다.
3. **졸업** -- 커브의 펀딩 목표에 도달하면 `BondingCurve._graduate()`가 실행됩니다: 유동성을 LPManager로 이전하고, LPManager가 직접 `pair.mint()`를 통해 NadFunPair에 유동성을 추가합니다. `graduateFee`가 차감됩니다.
4. **거래 (DEX)** -- `DexType.UniswapV3`로 등록된 졸업 토큰은 `GiwaRouter`가 `V3SwapAdapter`를 통해 canonical 풀의 exact-input/exact-output 매수·매도로 라우팅합니다. 라우터는 quote 토큰 측에 `dexProtocolFeeRate`를 적용하고, Uniswap V3 풀 LP 수수료는 풀 실행 가격에 포함됩니다. 레거시 V2 메타데이터는 이 경로에서 허용되지 않습니다.
5. **수수료 정산** -- FeeCollector는 수수료 수집 시 명시된 protocol fee와 초과분을 즉시 feeReceiver로 보내고 creator fee만 페어별로 누적합니다. 임계값에 도달하면 authorized `settle(pair, minAmountOut)`이 CreatorFeeProcessor로 전달합니다.

## 컨트랙트

### 핵심 (`src/core/`)

| 컨트랙트 | 업그레이드 방식 | 설명 |
|----------|---------------|------|
| `BondingCurve` | UUPS Proxy | 토큰 팩토리 + 본딩 커브 거래 엔진 |
| `ProtocolManager` | UUPS Proxy | 통합 프로토콜 설정: 수수료, 크리에이터 수수료 설정, quote 토큰 레지스트리 |
| `LPManager` | UUPS Proxy | 직접 `pair.mint()`를 통한 DEX 유동성 공급 |
| `TokenRegistry` | UUPS Proxy | 토큰 메타데이터 레지스트리 (pool/pair, quoteToken, DEX type) |
| `V3PoolDeployer` | UUPS Proxy | canonical Uniswap V3 풀 생성/재사용, 검증, 초기화, observation cardinality 설정 |
| `GiwaRouter` | UUPS Proxy | 생성, 커브 거래, canonical V3 exact-input/exact-output 거래, 견적, permit, native wrapping/refund 사용자 진입점 |
| `Treasury` | UUPS Proxy | V3 생명주기 인프라가 사용하는 프로토콜 treasury |
| `FeeCollector` | UUPS Proxy | 중앙 수수료 관리. `collectFee(pair, protocolFee, creatorFee)`는 수신 balance delta를 검증해 protocol fee와 초과분을 즉시 전달하고 creator fee만 누적합니다. `settle(pair, minAmountOut)`은 본딩 및 레거시 졸업 후 phase 모두에서 동작합니다. |
| `CreatorFeeProcessor` | Singleton | FeeCollector로부터 quoteToken을 수령하여 BPS 기준으로 조합형 싱글톤 vault들에 분배. |

### V3 라우팅 (`src/router/`, `src/adapters/`)

| 컨트랙트 | 업그레이드 방식 | 설명 |
|----------|---------------|------|
| `GiwaRouter` | UUPS Proxy | 등록 풀 메타데이터 조회, 라우터 프로토콜 수수료 계산, 사용자 슬리피지/refund 처리 |
| `V3SwapAdapter` | Singleton | canonical V3 풀 직접 스왑 및 활성 registry-backed 풀 컨텍스트에 한정된 콜백 지급 |

### 레거시 V2 DEX (`src/dex/`)

| 컨트랙트 | 패턴 | 설명 |
|----------|------|------|
| `NadFunFactory` | Singleton | Uniswap V2 포크 팩토리. CREATE2 페어 배포. |
| `NadFunPair` | Per-pair | Uniswap V2 포크 페어. `swap()`에서 수수료 차감. 수수료를 FeeCollector로 전송. |

### 토큰 (`src/token/`)

| 컨트랙트 | 패턴 | 설명 |
|----------|------|------|
| `Token` | EIP-1167 Clone | 일반 ERC20 + Burnable + Permit. fee-on-transfer 없음. |

### 볼트 (`src/vault/`)

| 컨트랙트 | 패턴 | 설명 |
|----------|------|------|
| `VaultRegistry` | UUPS Proxy | authority-restricted vault 레지스트리, ERC-165 인터페이스 검증 |
| `BurnVault` | Singleton UUPS Proxy | 단계별 라우팅을 통한 바이백 소각 |
| `LPVault` | Singleton UUPS Proxy | 설정 adapter를 통한 절반 스왑 + 유동성 추가 + LP 소각 |
| `CreatorFeeVault` | Singleton UUPS Proxy | 토큰별 quoteToken을 누적하고, 설정된 creator가 나중에 ERC-20 또는 설정된 WNATIVE quote의 native currency로 claim |
| `DividendVault` | Singleton UUPS Proxy | operator 변환 + 글로벌 Merkle root 기반 다중 dividend token 분배 |

## 수수료 시스템

### 수수료 구조

| 단계 | 크리에이터 수수료 (생성자 설정) | 프로토콜 수수료 | LP 수수료 | 사용자 총합 |
|------|-------------------|-------------|----------|-----------|
| 본딩 커브 | 1%/3%/5% (quote에서) | 1% (quote에서) | - | 2%/4%/6% |
| 레거시 DEX (NadFunPair) | 1%/3%/5% (quote에서) | 설정 가능 (quote에서) | 0.25% | 합산 |
| GiwaRouter를 통한 canonical V3 | - | `dexProtocolFeeRate` (quote 측) | 풀 fee tier | 라우터 수수료 + 풀 실행 |

- **크리에이터 수수료율**은 허용 목록으로 제한됩니다: 1%, 3%, 5% (`ProtocolManager`를 통해 관리자가 설정 가능)
- **본딩 커브**: `BondingCurve.buy()/sell()`에서 quote 토큰으로부터 프로토콜 수수료 + 크리에이터 수수료 차감
- **DEX**: LP 수수료(0.25%)는 리저브에 잔류, 프로토콜 수수료 + 크리에이터 수수료는 `NadFunPair.swap()`에서 FeeCollector로 전송
- **canonical V3 라우터 경로**: `GiwaRouter`는 실행 시점에 quote 토큰의 `dexProtocolFeeRate`와 현재 `feeReceiver`를 조회합니다. `V3SwapAdapter` 직접 호출에는 라우터 수수료가 추가되지 않습니다.
- **크리에이터 수수료는 영구적** -- 만료 없음 (v1의 TaxToken에 있던 creatorFeeExpirationTime과 달리)

### 수수료 정산 (FeeCollector -> CreatorFeeProcessor -> Vaults)

```
NadFunPair.swap() / BondingCurve.buy()/sell()
     |
     └── 수수료 (quoteToken) → FeeCollector.collectFee(pair, protocolFee, creatorFee)
              |
              └── 누적액 >= 임계값 도달 시:
                   FeeCollector.settle(pair, minAmountOut)
                    └── 누적 크리에이터 수수료 → CreatorFeeProcessor.processCreatorFee()
                         └── BPS 기준으로 싱글톤 vault들에 분배:
                              ├── BurnVault: quoteToken → token 스왑 → 0xdead 소각
                              ├── LPVault: 절반 스왑 + 유동성 추가 + LP 소각
                              └── CreatorFeeVault: 토큰별 누적 → creator claim (ERC-20 또는 WNATIVE → native)
```

## 주요 설계 결정

- **일반 ERC20 Token** (fee-on-transfer TaxToken 대신): 더 단순하고, 크리에이터 수수료 재진입 문제 없으며, 모든 DEX/프로토콜과 호환 가능
- **커스텀 NadFunPair** (외부 Uniswap V2 대신): 페어 단위 수수료 차감으로 프로토콜이 완전한 제어권 확보, fee-on-transfer 토큰 불필요
- **FeeCollector** 중앙 수수료 허브: 수수료 설정, 누적, 정산을 위한 단일 포인트. NadFunPair와 BondingCurve 모두 여기로 수수료 전송.
- **단순화된 CreatorFeeProcessor**: 더 이상 baseToken → quoteToken 스왑 불필요. FeeCollector로부터 quoteToken을 직접 수령. vault들에 분배만 담당.
- **통합 ProtocolManager** (별도의 FeeManager/AdminModule/QuoteManager 대신): 단일 배포, 크로스 컨트랙트 호출 감소, 전역 설정과 operator 권한 정책을 한 곳에서 관리
- **라우터 대신 직접 `pair.mint()`**: 유동성 추가 시 2개의 approve 작업 절약 (~40k 가스)
- **canonical V3 검증**: `V3SwapAdapter`는 설정된 factory와 등록 fee tier로 풀을 유도하고, 단일 활성 콜백 컨텍스트·델타 검증·지급 전 컨텍스트 삭제를 적용합니다.
- **싱글톤 CreatorFeeProcessor + 싱글톤 Vault** (토큰별 클론 대신): CreatorFeeProcessor는 공통 immutable constructor 상태를 갖고, vault는 한 번 초기화되는 공유 UUPS proxy입니다. 토큰별 설정은 `setup()` / mapping으로 관리합니다.
- **조합형 Vault 시스템** (모놀리식 CreatorFeeProcessor 대신): vault 로직(소각, LP, creator claim)을 독립적이고 플러그 가능한 컨트랙트로 분리. CreatorFeeProcessor는 분배만 담당.
- **VaultRegistry (authority-restricted + ERC-165)**: ProtocolManager owner 또는 selector-authorized operator가 vault를 등록/비활성화하며, 등록 시 IVault 인터페이스를 검증합니다.

## 개발

```shell
# 빌드
forge build

# 테스트
forge test

# 상세 출력으로 테스트
forge test -vvv

# 특정 파일 테스트
forge test --match-path test/fee/FeeCollector.t.sol

# 특정 함수 테스트
forge test --match-test test_settle_splitsCorrectly

# 가스 스냅샷
forge snapshot

# 배포 (현재 레거시 V2 생성/졸업 배선 유지)
forge script script/deploy/normal/Deploy.s.sol --rpc-url <rpc_url> --broadcast
```

### 프로젝트 설정

- Solidity 0.8.24, EVM 대상: london
- 프레임워크: Foundry
- 의존성: OpenZeppelin (contracts + upgradeable), Solady

### 테스트 구조

```
test/
├── SetUp.t.sol         # 공유 베이스: 전체 프로토콜 스택 배포 + 헬퍼
├── core/               # BondingCurve, Fee, Graduation, Router, ProtocolManager
│   ├── BondingCurveAttack.t.sol   # 공격 벡터 (직접 매수, 플래시 론, 재진입, 졸업 후)
│   ├── BondingCurveV2.t.sol       # v2 전용: Token + NadFunFactory + FeeCollector로의 크리에이터 수수료
│   └── QuoteReserveAttack.t.sol   # 크로스 커브 리저브 탈취
├── dex/                # NadFunFactory, NadFunPair, NadFunPairFee
├── fee/                # FeeCollector
├── integration/        # 전체 생명주기 E2E
├── router/             # GiwaRouter canonical V3 및 native quote 라우팅
├── adapters/           # V3SwapAdapter와 유지 중인 V2/외부 adapter
├── fork/               # 배포된 wrapped-native/Quoter 통합 (환경 변수로 게이트)
├── modules/            # LPManager
│   └── ModuleAttack.t.sol         # 공격 벡터 (이중 LP, 극단적 수수료, 크리에이터 수수료율 허용 목록)
├── token/              # CreatorFeeProcessor
├── vault/              # VaultRegistry, BurnVault, LPVault, CreatorFeeVault
│   └── VaultAttack.t.sol          # 공격 벡터 (비활성화 vault, revert vault)
├── mocks/              # MockERC20, MockWrappedNative
└── utils/              # (비어 있음 -- NadFunFactory가 UniswapV2Deployer를 대체)
```

### 테스트 카테고리

| 카테고리 | 파일 | 목적 |
|----------|------|------|
| Unit | `test/core/*.t.sol`, `test/token/*.t.sol`, `test/vault/*.t.sol`, `test/dex/*.t.sol`, `test/fee/*.t.sol` | 개별 컨트랙트 기능 검증 |
| Integration | `test/integration/*.t.sol` | 멀티 컨트랙트 생명주기 |
| Attack | `*Attack.t.sol` | 공격 벡터 방어 검증 |
| Module | `test/modules/*.t.sol` | LPManager, 모듈 시스템 |

### 보안

테스트 파일 전반에 걸쳐 공격 벡터가 검증되었습니다. 주요 방어 메커니즘:

- **`_totalQuoteReserved`**: quote 토큰별 회계 처리로 크로스 커브 리저브 탈취 방지
- **`nonReentrant`**: 본딩 커브 거래 및 졸업 흐름 보호
- **안티 스나이핑 패널티**: ProtocolManager의 블록별 lookup table (기본: 생성 후 블록 0..6에 80%/40%/20%/15%/10%/10%/5%, 이후 0), 플래시 론 공격을 비수익적으로 만듦
- **NadFunPair 수수료 강제**: `swap()`에서 수수료가 원자적으로 차감, 직접 전송을 통한 우회 불가
- **V3 콜백 인증**: 활성 swap의 canonical 등록 풀만 콜백할 수 있으며 replay, 누락, 중복, 비정상 델타는 revert
- **FeeCollector 제한 정산**: 임계값과 `minAmountOut` 조건을 충족한 authorized settler만 정산 가능
- **ERC-165 검증**: VaultRegistry가 등록 시 IVault 인터페이스 검증

전체 방어 매트릭스와 알려진 제한 사항은 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#security)를 참조하세요. API 문서: [GiwaRouter](docs/contracts/ko/router/GiwaRouter.md), [IGiwaRouter](docs/contracts/ko/interfaces/IGiwaRouter.md), [V3SwapAdapter](docs/contracts/ko/adapters/V3SwapAdapter.md).
