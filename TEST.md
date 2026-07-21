# NadFun V2 — 테스트 가이드

## 빠른 시작

```shell
# 전체 테스트 실행
forge test

# 상세 로그
forge test -vvv

# 특정 파일
forge test --match-path test/fee/FeeCollector.t.sol

# 특정 함수
forge test --match-test test_settle_splitsCorrectly

# 가스 리포트
forge test --gas-report
```

## 테스트 구조

```
test/
├── SetUp.t.sol         # 공유 베이스 (full stack 배포 + 헬퍼)
├── core/               # 핵심 컨트랙트 단위 테스트
│   ├── BondingCurve.t.sol         # 기본 buy/sell, 리저브
│   ├── BondingCurveV2.t.sol       # v2: Token + NadFunFactory + creator fee → FeeCollector
│   ├── BondingCurveAttack.t.sol   # 공격 벡터 (직접 buy, flash loan, 재진입, 졸업 후)
│   ├── QuoteReserveAttack.t.sol   # Cross-curve reserve 도난
│   ├── BuyCap.t.sol               # 매수 한도
│   ├── Fee.t.sol                  # 수수료 시스템
│   ├── Graduation.t.sol           # 졸업 프로세스
│   ├── NadFunRouter.t.sol         # 통합 라우터
│   ├── NadFunRouterCreate.t.sol   # 라우터 토큰 생성
│   ├── ProtocolManager.t.sol      # 프로토콜 설정
│   ├── Router.t.sol               # 라우터 기본
│   └── RouterV2.t.sol             # v2: NadFunRouter + LPManager
├── dex/                # Custom DEX 테스트
│   ├── NadFunFactory.t.sol        # 팩토리: pair 생성, CREATE2
│   ├── NadFunPair.t.sol           # 페어: mint, burn, swap (vanilla V2)
│   └── NadFunPairFee.t.sol        # 페어: fee 차감, FeeCollector 연동
├── fee/                # 수수료 관리
│   └── FeeCollector.t.sol         # setup, collection, settlement, split
├── integration/        # 멀티 컨트랙트 통합 테스트 (DividendRouterLane: 실 라우터 경유 배당 변환)
├── modules/            # 모듈 (LPManager) 테스트
│   ├── LPManager.t.sol            # 유동성 추가, LP 잠금
│   └── ModuleAttack.t.sol         # 공격 벡터 (이중 LP, 극단 수수료, 크리에이터 수수료율 allowlist)
├── token/              # CreatorFeeProcessor 테스트
│   └── CreatorFeeProcessorV2.t.sol       # v2: quoteToken 직접 분배
├── vault/              # Vault + VaultRegistry 테스트
│   ├── BurnVaultV2.t.sol          # v2: NadFunPair 경유 바이백 소각
│   ├── LPVaultV2.t.sol            # v2: NadFunPair 경유 LP 추가
│   ├── CreatorFeeVault.t.sol             # recipient 설정, 직접 전달
│   ├── DividendVault.t.sol        # 배당 변환(라우터 lane·uni lane hop)·Merkle claim·V1 게이트
│   ├── VaultAttack.t.sol          # 공격 벡터 (비활성 vault, reverting vault)
│   └── VaultRegistry.t.sol        # 등록, 비활성화, ERC-165 검증
├── adapters/           # NadSwapAdapter, UniswapV2/V3ExternalAdapter 단위 테스트
├── mocks/              # MockERC20, MockWMON, MockNadFunRouter, MockUniswapV2Pair, MockCapricornPool, MockTokenRegistryV1, ...
└── utils/              # (비어있음 — NadFunFactory가 UniswapV2Deployer 대체)
```

## SetUp.t.sol — 공유 베이스 컨트랙트

모든 테스트 파일은 `SetUp`을 상속하여 full protocol stack을 사용합니다.

### 배포되는 컨트랙트 (모두 real, mock 아님)

| 컨트랙트 | 패턴 | 변수명 |
|----------|------|--------|
| NadFunFactory | Singleton | `nadFunFactory` |
| NadFunPair | Per-pair | (pair creation 시 생성) |
| ProtocolManager | UUPS Proxy | `protocolManager` |
| BondingCurve | UUPS Proxy | `bondingCurve` |
| TokenRegistry | UUPS Proxy | `tokenRegistry` |
| LPManager | UUPS Proxy | `lpManager` |
| FeeCollector | UUPS Proxy | `feeCollector` |
| CreatorFeeProcessor | Singleton | `creatorFeeProcessor` |
| VaultRegistry | UUPS Proxy | `vaultRegistry` |
| BurnVault | Singleton | `burnVault` |
| LPVault | Singleton | `lpVault` |
| CreatorFeeVault | Singleton | `creatorFeeVault` |
| MockERC20 (quoteToken) | Mock | `quoteToken` |

### 제공 헬퍼

| 헬퍼 | 용도 |
|------|------|
| `_createToken()` | 기본 파라미터로 토큰 생성 (creator 주소) |
| `_createTokenWith(name, symbol, creatorFeeRate, salt)` | 커스텀 파라미터로 토큰 생성 |
| `_defaultParams()` | CreateTokenParams 반환 (CreatorFeeVault 100% BPS) |
| `_createTokenParams(name, symbol, creatorFeeRate, salt)` | 커스텀 CreateTokenParams 반환 |
| `_mintAndTransfer(user, amount)` | quoteToken mint → BondingCurve에 전송 |
| `_mintAndApprove(user, spender, amount)` | quoteToken mint → approve |
| `_buyOnCurve(buyer, token, quoteAmount)` | 본딩커브 매수, tokenOut 반환 |
| `_sellOnCurve(seller, token, tokenAmount)` | 본딩커브 매도, quoteOut 반환 |
| `_graduateToken(token)` | 졸업까지 반복 매수 |
| `_skipAntiSniping()` | `vm.warp(+100 minutes)` |

### 테스트 작성 패턴

```solidity
import {SetUp} from "../SetUp.t.sol";

contract MyFeatureTest is SetUp {
    address token;

    function setUp() public override {
        super.setUp();
        // 테스트 고유 setup만 추가
        token = _createToken();
    }

    function test_buyOnCurve() public {
        uint256 tokenOut = _buyOnCurve(user1, token, 1 ether);
        assertGt(tokenOut, 0);
    }
}
```

## 테스트 카테고리

### Unit Tests (`test/core/`, `test/token/`, `test/vault/`, `test/dex/`, `test/fee/`)

개별 컨트랙트의 기능을 독립적으로 검증.

| 파일 | 대상 | 주요 검증 |
|------|------|----------|
| `BondingCurve.t.sol` | BondingCurve | buy/sell, 리저브 업데이트, anti-sniping |
| `BondingCurveV2.t.sol` | BondingCurve (v2) | Token + NadFunFactory + creator fee → FeeCollector |
| `Fee.t.sol` | 수수료 시스템 | 프로토콜 수수료 계산, 스나이핑 페널티, getAmountOut |
| `Router.t.sol` | NadFunRouter | buy/sell 라우팅, 슬리피지 보호 |
| `RouterV2.t.sol` | NadFunRouter (v2) | NadFunPair 연동, fee 포함 |
| `NadFunRouter.t.sol` | NadFunRouter | 자동 라우팅 (커브↔DEX), 네이티브 토큰 래핑 |
| `Graduation.t.sol` | 졸업 프로세스 | LP 배포, graduateFee 차감 |
| `ProtocolManager.t.sol` | ProtocolManager | 수수료 설정, quote 토큰 관리 |
| `NadFunPair.t.sol` | NadFunPair | mint, burn, swap, skim, sync (vanilla V2) |
| `NadFunPairFee.t.sol` | NadFunPair (fee) | fee 차감, FeeCollector 연동, k invariant |
| `NadFunFactory.t.sol` | NadFunFactory | pair 생성, CREATE2, 중복 방지 |
| `FeeCollector.t.sol` | FeeCollector | setup, collection, restricted settlement, split |
| `CreatorFeeProcessorV2.t.sol` | CreatorFeeProcessor (v2) | quoteToken 직접 분배, BPS, dust rounding |
| `VaultRegistry.t.sol` | VaultRegistry | 등록, 비활성화, ERC-165 검증, VaultType |
| `BurnVaultV2.t.sol` | BurnVault (v2) | NadFunPair 경유 바이백 소각 |
| `LPVaultV2.t.sol` | LPVault (v2) | NadFunPair 경유 유동성 추가, LP 소각 |
| `CreatorFeeVault.t.sol` | CreatorFeeVault | recipient 설정, 직접 전달 |

### Integration Tests (`test/integration/`)

전체 프로토콜 라이프사이클을 하나의 테스트에서 관통하는 E2E 검증.

### Attack Tests (`*Attack.t.sol`)

공격 벡터에 대한 방어 검증.

| 파일 | 공격 벡터 |
|------|----------|
| `QuoteReserveAttack.t.sol` | Cross-curve reserve 도난 |
| `BondingCurveAttack.t.sol` | 직접 buy, flash loan, 재진입, 졸업 후 거래 |
| `ModuleAttack.t.sol` | 이중 LP, 극단 수수료, 크리에이터 수수료율 allowlist |
| `VaultAttack.t.sol` | 비활성 vault, reverting vault |

## Mock 컨트랙트

| Mock | 위치 | 용도 |
|------|------|------|
| `MockERC20` | `test/mocks/` | 민팅 가능한 기본 ERC20 (quoteToken으로 사용) |
| `MockERC20Permit` | `test/mocks/` | EIP-2612 Permit 지원 ERC20 (Router02 permit 테스트용) |
| `MockWMON` | `test/mocks/` | Wrapped Native 토큰 (네이티브 토큰 테스트용) |
| `MockLvMonMinter` | `test/mocks/` | ILvMonMinter mock (Router LvMON quote 경로 테스트용) |
| `MockNadFunRouter` | `test/mocks/` | router.buy mock — 실제 라우터처럼 전액 pull 후 환불(consumeBps/nextOut로 부분 소비·환불 시뮬레이션). DividendVault의 router hop(executeConversion) 경로 검증용 |
| `MockUniswapV2Pair` | `test/mocks/` | 외부 표준 V2 pair mock (UniswapV2ExternalAdapter 테스트용) |
| `MockCapricornPool` | `test/mocks/` | Capricorn CL(V3) pool mock — exact-input swap + 콜백. 적대적 모드(콜백 미실행/이중/오염 델타/재진입) + `fillBps` 부분 체결·과다 청구 시뮬레이션 (UniswapV3ExternalAdapter·DividendVault V1 경로) |
| `MockTokenRegistryV1` | `test/mocks/` | nadfun V1(contract-v3) TokenRegistry mock — `tokenInfos(token)`, pool != 0 = 등록 (TokenInfoLens·DividendVault V1 resolve) |
| `MockFeeOnTransferERC20` | `test/mocks/` | 전송 수수료 ERC20 (DividendVault 잔액 델타 회계 검증용) |

> 모든 테스트가 real 컨트랙트를 사용. NadFunFactory가 외부 Uniswap V2 Deployer를 대체.

## 커버리지 목표

- 최소 80% 라인 커버리지
- 모든 public/external 함수에 최소 1개 이상의 테스트
- 모든 error/revert 경로에 테스트
- 공격 벡터별 방어 테스트 필수

## 주의사항

1. **Forge는 전체 컴파일**: `--match-path`로 특정 파일만 테스트해도 모든 .sol 파일이 컴파일됨.
2. **Anti-sniping은 토큰별**: SetUp의 `_skipAntiSniping()`은 전역 타임스탬프를 이동시키지만, 이후 생성된 토큰은 새로운 sniping 윈도우를 가짐. 토큰 생성 후 다시 `_skipAntiSniping()` 호출 필요.
3. **Mock vault ERC-165**: IVault 구현하는 모든 mock에 `supportsInterface()` 필수 (VaultRegistry가 등록 시 체크).
