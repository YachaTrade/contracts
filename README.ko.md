# NadFun V2

본딩 커브 토큰 런치패드로, 졸업 후 커스텀 DEX 거래 및 페어 단위 수수료 시스템을 제공합니다. Monad용으로 구축되었습니다.

## 아키텍처

```
src/
├── core/       BondingCurve (UUPS), ProtocolManager (UUPS), LPManager (UUPS), TokenRegistry (UUPS), NadFunRouter (stateless), FeeCollector (UUPS), CreatorFeeProcessor (singleton)
├── router/     BondingCurveRouter (stateless), DexRouter (stateless)
├── token/      Token (EIP-1167 clone)
├── dex/        NadFunFactory (singleton), NadFunPair (per-pair)
├── vault/      VaultRegistry (UUPS), BurnVault, LPVault, CreatorFeeVault (singletons)
├── interfaces/
└── libraries/  BondingCurveLibrary, Math, UQ112x112, Constants
```

### 토큰 생명주기

1. **생성** -- 생성자가 `VaultAllocation[]`과 함께 `BondingCurve.create()`를 호출합니다. Token 클론(일반 ERC20)을 배포합니다. NadFunFactory를 통해 NadFunPair를 생성합니다. FeeCollector에 토큰별 수수료 설정을 등록합니다. CreatorFeeProcessor 싱글톤에 토큰별 vault 설정(`setup()`)을 구성합니다. `deployFee`가 부과됩니다.
2. **거래 (본딩 커브)** -- 사용자가 `NadFunRouter`를 통해 매수/매도합니다. 가격은 본딩 커브 공식을 따릅니다. 각 거래마다 quote에서 프로토콜 수수료 + 크리에이터 수수료가 차감됩니다. 크리에이터 수수료는 FeeCollector로 전송됩니다.
3. **졸업** -- 커브의 펀딩 목표에 도달하면 `BondingCurve._graduate()`가 실행됩니다: 유동성을 LPManager로 이전하고, LPManager가 직접 `pair.mint()`를 통해 NadFunPair에 유동성을 추가합니다. `graduateFee`가 차감됩니다.
4. **거래 (DEX)** -- 졸업 후 `NadFunRouter`가 자동으로 NadFunPair로 라우팅합니다. NadFunPair가 `swap()`에서 수수료(LP 수수료 + 프로토콜 수수료 + 크리에이터 수수료)를 차감하고, 징수된 수수료를 FeeCollector로 전송합니다.
5. **수수료 정산** -- FeeCollector는 수수료 수집 시 활성 프로토콜 수수료 몫을 즉시 feeReceiver로 보내고, 크리에이터 수수료만 페어별로 누적합니다. 누적된 크리에이터 수수료가 정산 임계값에 도달하면 `settle()`이 CreatorFeeProcessor로 전달하고, 이후 싱글톤 vault들에 BPS 기준으로 분배됩니다.

## 컨트랙트

### 핵심 (`src/core/`)

| 컨트랙트 | 업그레이드 방식 | 설명 |
|----------|---------------|------|
| `BondingCurve` | UUPS Proxy | 토큰 팩토리 + 본딩 커브 거래 엔진 |
| `ProtocolManager` | UUPS Proxy | 통합 프로토콜 설정: 수수료, 크리에이터 수수료 설정, quote 토큰 레지스트리 |
| `LPManager` | UUPS Proxy | 직접 `pair.mint()`를 통한 DEX 유동성 공급 |
| `TokenRegistry` | UUPS Proxy | 토큰 메타데이터 레지스트리 (pair, quoteToken) |
| `NadFunRouter` | Stateless | 통합 라우터: 본딩 커브 또는 DEX로 자동 라우팅 |
| `FeeCollector` | UUPS Proxy | 중앙 수수료 관리. 페어별 수수료 설정에 creatorFeeRate + curveProtocolFeeRate + dexProtocolFeeRate를 저장합니다. collectFee는 balance delta 방식 (msg.sender는 pair 또는 bondingCurve)으로 동작하며, 프로토콜 수수료는 즉시 전송하고 크리에이터 수수료만 누적합니다. settle은 누적 크리에이터 수수료를 CreatorFeeProcessor로 넘기며, 졸업 전이면 조기 반환합니다. |
| `CreatorFeeProcessor` | Singleton | FeeCollector로부터 quoteToken을 수령하여 BPS 기준으로 조합형 싱글톤 vault들에 분배. |

### 라우터 (`src/router/`)

| 컨트랙트 | 업그레이드 방식 | 설명 |
|----------|---------------|------|
| `BondingCurveRouter` | Stateless | 본딩 커브 거래 라우터 |
| `DexRouter` | Stateless | 졸업 후 DEX 거래 라우터 (NadFunPair를 통한 스왑) |

### DEX (`src/dex/`)

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
| `VaultRegistry` | UUPS Proxy | 관리자 전용 vault 레지스트리, ERC-165 인터페이스 검증 |
| `BurnVault` | Singleton | NadFunPair 스왑을 통한 바이백 소각 |
| `LPVault` | Singleton | 절반 스왑 + 유동성 추가 + NadFunPair를 통한 LP 소각 |
| `CreatorFeeVault` | Singleton | 토큰별 설정된 수령인에게 직접 전송 |

## 수수료 시스템

### 수수료 구조

| 단계 | 크리에이터 수수료 (생성자 설정) | 프로토콜 수수료 | LP 수수료 | 사용자 총합 |
|------|-------------------|-------------|----------|-----------|
| 본딩 커브 | 1%/3%/5% (quote에서) | 1% (quote에서) | - | 2%/4%/6% |
| DEX (NadFunPair) | 1%/3%/5% (quote에서) | 설정 가능 (quote에서) | 0.25% | 합산 |

- **크리에이터 수수료율**은 허용 목록으로 제한됩니다: 1%, 3%, 5% (`ProtocolManager`를 통해 관리자가 설정 가능)
- **본딩 커브**: `BondingCurve.buy()/sell()`에서 quote 토큰으로부터 프로토콜 수수료 + 크리에이터 수수료 차감
- **DEX**: LP 수수료(0.25%)는 리저브에 잔류, 프로토콜 수수료 + 크리에이터 수수료는 `NadFunPair.swap()`에서 FeeCollector로 전송
- **크리에이터 수수료는 영구적** -- 만료 없음 (v1의 TaxToken에 있던 creatorFeeExpirationTime과 달리)

### 수수료 정산 (FeeCollector -> CreatorFeeProcessor -> Vaults)

```
NadFunPair.swap() / BondingCurve.buy()/sell()
     |
     └── 수수료 (quoteToken) → FeeCollector.collectFee()
              |
              └── 누적액 >= 임계값 도달 시:
                   FeeCollector.settle()
                    ├── 프로토콜 수수료 부분 → feeReceiver
                    └── 크리에이터 수수료 부분 → CreatorFeeProcessor.processCreatorFee()
                         └── BPS 기준으로 싱글톤 vault들에 분배:
                              ├── BurnVault: quoteToken → token 스왑 → 0xdead 소각
                              ├── LPVault: 절반 스왑 + 유동성 추가 + LP 소각
                              └── CreatorFeeVault: 수령인에게 직접 전송
```

## 주요 설계 결정

- **일반 ERC20 Token** (fee-on-transfer TaxToken 대신): 더 단순하고, 크리에이터 수수료 재진입 문제 없으며, 모든 DEX/프로토콜과 호환 가능
- **커스텀 NadFunPair** (외부 Uniswap V2 대신): 페어 단위 수수료 차감으로 프로토콜이 완전한 제어권 확보, fee-on-transfer 토큰 불필요
- **FeeCollector** 중앙 수수료 허브: 수수료 설정, 누적, 정산을 위한 단일 포인트. NadFunPair와 BondingCurve 모두 여기로 수수료 전송.
- **단순화된 CreatorFeeProcessor**: 더 이상 baseToken → quoteToken 스왑 불필요. FeeCollector로부터 quoteToken을 직접 수령. vault들에 분배만 담당.
- **통합 ProtocolManager** (별도의 FeeManager/AdminModule/QuoteManager 대신): 단일 배포, 크로스 컨트랙트 호출 감소, 전역 설정과 operator 권한 정책을 한 곳에서 관리
- **라우터 대신 직접 `pair.mint()`**: 유동성 추가 시 2개의 approve 작업 절약 (~40k 가스)
- **싱글톤 CreatorFeeProcessor + 싱글톤 Vault** (EIP-1167 클론 대신): 공통 상태에 대한 constructor immutable, 토큰별 설정은 `setup()` / `mapping`으로 관리. 토큰당 배포 비용 절감.
- **조합형 Vault 시스템** (모놀리식 CreatorFeeProcessor 대신): vault 로직(소각, LP, 전송)을 독립적이고 플러그 가능한 컨트랙트로 분리. CreatorFeeProcessor는 분배만 담당.
- **VaultRegistry (관리자 전용 + ERC-165)**: 관리자가 검증된 vault를 등록. 등록 시 ERC-165 인터페이스 검증. 관리자가 취약한 타입을 비활성화 가능.

## 개발

```shell
# 빌드
forge build

# 테스트 (318개 테스트)
forge test

# 상세 출력으로 테스트
forge test -vvv

# 특정 파일 테스트
forge test --match-path test/fee/FeeCollector.t.sol

# 특정 함수 테스트
forge test --match-test test_settle_splitsCorrectly

# 가스 스냅샷
forge snapshot

# 배포
forge script script/Deploy.s.sol --rpc-url <rpc_url> --broadcast
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
├── modules/            # LPManager
│   └── ModuleAttack.t.sol         # 공격 벡터 (이중 LP, 극단적 수수료, 크리에이터 수수료율 허용 목록)
├── token/              # CreatorFeeProcessor
├── vault/              # VaultRegistry, BurnVault, LPVault, CreatorFeeVault
│   └── VaultAttack.t.sol          # 공격 벡터 (비활성화 vault, revert vault)
├── mocks/              # MockERC20, MockWMON
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
- **안티 스나이핑 패널티**: ProtocolManager를 통해 설정 가능 (기본: 99분에 걸쳐 99% -> 0%, 1%/분), 플래시 론 공격을 비수익적으로 만듦
- **NadFunPair 수수료 강제**: `swap()`에서 수수료가 원자적으로 차감, 직접 전송을 통한 우회 불가
- **FeeCollector 비허가 정산**: 임계값 도달 시 누구나 정산 트리거 가능
- **ERC-165 검증**: VaultRegistry가 등록 시 IVault 인터페이스 검증

전체 방어 매트릭스와 알려진 제한 사항은 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#security)를 참조하세요.
