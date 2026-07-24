# GIWA Launchpad 컨트랙트

본딩 커브에서 토큰을 출시하고 canonical Uniswap V3 풀로 졸업시키는 런치패드입니다.
Solidity 0.8.24, Foundry, UUPS 프록시, EIP-1167 토큰 클론으로 구성됩니다.

## 아키텍처

기본 배포는 V3 전용이며 `CreatorFeeVault`만 등록합니다.

```text
Creator / Trader
      │
      ▼
 YachaRouter ───────────────► V3SwapAdapter ─────────► canonical V3 pool
      │                              ▲
      ▼                              │
 BondingCurve ─► V3PoolDeployer      │
      │              │               │
      │              └─ 풀 생성 및 초기화
      │
      └─ 졸업 ──────► LPManager ───► V3LiquidityActor
                           │                │
                           │                └─ 영구 V3 포지션
                           │
                           └─ LP 수수료 수집
                                ├─ protocol 몫 ─► feeReceiver
                                └─ creator 몫 ──► CreatorFeeProcessor
                                                        │
                                                        └─ CreatorFeeVault
```

주요 소스 구성:

```text
src/
├── core/         BondingCurve, ProtocolManager, LPManager, TokenRegistry,
│                 V3PoolDeployer, CreatorFeeProcessor
├── router/       YachaRouter
├── actors/       V3LiquidityActor
├── adapters/     V3SwapAdapter
├── token/        Token
├── vault/        VaultRegistry, CreatorFeeVault
├── integration/  TokenInfoLens
├── interfaces/
└── libraries/    BondingCurveLibrary, Constants, Math, TransferHelper
```

## 토큰 생명주기

1. **생성** — creator가 `YachaRouter.create()`를 호출합니다. `BondingCurve`는 deterministic
   `Token` 클론을 만들고, `V3PoolDeployer`는 졸업 목표 가격으로 canonical 풀을 생성·초기화합니다.
   `TokenRegistry`는 풀, quote token, fee tier를 기록합니다.
2. **커브 거래** — 졸업 전 매수·매도는 `YachaRouter`를 거쳐 `BondingCurve`에서 실행됩니다.
   quote token별 `curveProtocolFeeRate`가 적용되고 일반 매수에만 anti-sniping 설정이 적용됩니다.
   creator 거래 수수료는 없습니다.
3. **졸업** — virtual token reserve가 `minTokenReserve`에 도달하면 `graduateFee`를 차감하고
   추적된 token/quote 유동성을 `LPManager`로 보냅니다. `V3LiquidityActor`는 contract-v3 수학과
   동일한 두 개의 영구 V3 포지션을 생성합니다.
4. **V3 거래** — 졸업 후 exact-input/exact-output 거래는 `V3SwapAdapter`를 통해 등록된
   canonical 풀에서 실행됩니다. quote 측에는 `dexProtocolFeeRate`가 적용됩니다.
5. **유동성 운영** — `ProtocolManager` owner 또는 selector 권한을 받은 operator는
   `LPManager.increaseLiquidity()`로 두 포지션에 자산을 추가할 수 있습니다. 원금 출금 경로는 없습니다.
6. **LP 수수료 수집** — authorized collector가 `LPManager.collect(tokens)`를 호출합니다.
   token 측 수수료는 canonical 풀에서 quote로 스왑되고 direct quote 수수료와 합쳐진 뒤,
   quote token별 `lpFeeProtocolShareBps`에 따라 protocol과 creator processor로 분배됩니다.

## 주요 컨트랙트

| 컨트랙트 | 패턴 | 역할 |
| --- | --- | --- |
| `ProtocolManager` | UUPS Proxy | fee receiver, quote 설정, V3 fee tier, LP 수수료 분배율, anti-sniping, selector 권한 관리 |
| `BondingCurve` | UUPS Proxy | 토큰 생성, 커브 거래, reserve 회계, 졸업 오케스트레이션 |
| `TokenRegistry` | UUPS Proxy | launch token별 canonical pool, quote token, DEX type, fee tier 저장 |
| `V3PoolDeployer` | UUPS Proxy | canonical V3 풀 생성·검증·초기화 |
| `LPManager` | UUPS Proxy | 영구 유동성 배치·증가, 수수료 조회·수집·quote 통일·분배 |
| `V3LiquidityActor` | Immutable | 두 영구 포지션 소유, mint callback 인증, fee 수집 |
| `V3SwapAdapter` | Immutable | registry 기반 canonical 풀 swap 및 callback 인증 |
| `CreatorFeeProcessor` | Immutable | LPManager에서 받은 creator quote를 vault BPS대로 분배 |
| `VaultRegistry` | UUPS Proxy | authority와 ERC-165 검증을 거친 vault 등록 |
| `CreatorFeeVault` | UUPS Proxy | 토큰별 creator quote 적립 및 claim |
| `YachaRouter` | UUPS Proxy | 생성, 커브/V3 거래, quote, permit, native wrapping/refund 진입점 |
| `Token` | EIP-1167 Clone | ERC-20 + ERC-2612 permit |
| `Lens` | Immutable | 생명주기 상태와 quote 조회를 위한 통합 Lens |

## 수수료

토큰 생성, 커브 거래, 졸업 후 라우터 거래에는 creator trading fee가 없습니다.
creator 수익은 V3 LP 수수료의 설정된 몫에서 발생합니다.

| 단계 | 설정 | 수신처 |
| --- | --- | --- |
| 토큰 생성 | quote token별 `deployFee` | `feeReceiver` |
| 커브 거래 | `curveProtocolFeeRate`, 일반 매수 anti-sniping | `feeReceiver` |
| 졸업 | quote token별 `graduateFee` | `feeReceiver` |
| 졸업 후 거래 | quote 측 `dexProtocolFeeRate` | `feeReceiver` |
| V3 풀 실행 | `v3FeeTier` | 영구 V3 포지션에 적립 |
| LP 수수료 수집 | `lpFeeProtocolShareBps` | protocol 몫은 `feeReceiver`, 나머지는 `CreatorFeeProcessor` |

```text
authorized collector
  └─ LPManager.collect(tokens)
       └─ 각 launch token
            ├─ 저장된 pool/factory/registry 검증
            ├─ V3LiquidityActor.collectFees()
            ├─ launch-token fee 전량을 quote token으로 swap
            ├─ total quote = direct quote fee + swap output
            ├─ protocol quote → ProtocolManager.feeReceiver()
            └─ creator quote → CreatorFeeProcessor.processCreatorFee()
                                  └─ CreatorFeeVault.afterDeposit()
```

batch 수집은 원자적입니다. 중복 토큰, pool metadata 불일치, partial swap, taxed transfer,
vault callback 실패, balance delta 불일치는 전체 트랜잭션을 revert합니다. 기존 donation과
entry balance는 수집 수익에 포함하지 않으며 임시 allowance도 제거합니다.

## 여러 Quote Token

`ProtocolManager`는 quote token별로 다음 값을 독립적으로 저장합니다.

- decimals
- virtual quote/token reserve와 minimum token reserve
- deploy/graduate fee
- curve/dex protocol fee rate
- canonical V3 fee tier
- LP fee protocol share BPS
- active 상태

`addV3QuoteToken()`과 `updateV3QuoteToken()`이 curve·V3 설정을 원자적으로 처리합니다.
`LPManager.collect()` batch의 각 launch token은 자기 registry에 기록된 quote asset으로 분배됩니다.

## 권한

- `ProtocolManager.owner()`는 모든 AccessManaged target을 직접 호출할 수 있습니다.
- 별도 operator는 정확한 target/selector 권한이 필요합니다.
- `BondingCurve`는 pool 생성, registry 등록, LP 배치, creator vault 설정 권한을 가집니다.
- `LPManager`는 `CreatorFeeProcessor.processCreatorFee()`를 호출할 수 있습니다.
- `COLLECTOR`는 `LPManager.collect()`만 호출할 수 있습니다.
- `YachaRouter`는 `BondingCurve.ROUTER_ROLE`을 가집니다.
- multisig는 `ProtocolManager` owner와 BondingCurve admin/guardian 역할을 가집니다.

## 개발과 검증

```shell
forge fmt
forge fmt --check
forge build
forge test

forge test --match-path test/integration/WnativeV3GraduationE2E.t.sol -vvv
forge test --match-path test/integration/WnativeV3LpFeeCollectionE2E.t.sol -vvv
forge test --match-path test/modules/LPManagerCollect.t.sol -vvv
forge test --match-path test/invariant/LPPrincipalLock.invariant.t.sol -vvv

RUN_FORK_TESTS=true forge test --match-path test/fork/YachaRouterNativeQuoteFork.t.sol -vvv
```

테스트는 core, router, V3 liquidity, LP fee, integration, invariant, fork 영역으로 나뉩니다.
현재 전체 로컬 검증은 557 passed, 0 failed, 환경 의존 fork 2 skipped입니다.
LP principal invariant는 65,536 calls / 0 reverts로 통과했습니다.

### Canonical ABI

`bash script/extract-abis.sh`를 실행하면 현재 build artifact에서 public ABI를 다시 생성합니다.

- `abis/YachaRouter.json`은 현재 canonical router ABI이며 이전 router ABI는 제거했습니다.
- `abis/Lens.json`은 `yachaRouter()`와 현재 router 기반 read surface를 제공합니다.
- `abis/LPManager.json`은 업그레이드된 LPManager에서 다시 생성한 canonical `Allocate`, `Collect` 이벤트를 제공합니다. `Collect.quoteAmount`는 수집한 launch-token 수수료를 quote로 스왑한 뒤 실제 배분하는 최종 quote 총액입니다.

## GIWA Sepolia 배포

- Chain ID: `91342`
- RPC: `https://sepolia-rpc.giwa.io`
- Explorer: `https://sepolia-explorer.giwa.io`
- Canonical WNATIVE: `0x4200000000000000000000000000000000000006`

### 현재 통합 주소

| 컨트랙트 | 주소 |
| --- | --- |
| ProtocolManager | [`0x839AAE0711DDf9A3E8381d73Fbc8bD9146cc762e`](https://sepolia-explorer.giwa.io/address/0x839AAE0711DDf9A3E8381d73Fbc8bD9146cc762e) |
| BondingCurve | [`0x852716437D0e67e8BbaF4c8282C26b7941DD16E9`](https://sepolia-explorer.giwa.io/address/0x852716437D0e67e8BbaF4c8282C26b7941DD16E9) |
| TokenRegistry | [`0xB9E1a129818fE17300152E067b978eA9098100F0`](https://sepolia-explorer.giwa.io/address/0xB9E1a129818fE17300152E067b978eA9098100F0) |
| LPManager proxy | [`0xA7dAacA8DF5685bCAA20043071953dC87b0BC24f`](https://sepolia-explorer.giwa.io/address/0xA7dAacA8DF5685bCAA20043071953dC87b0BC24f) |
| LPManager implementation | [`0xbD8c3c60eFDf5d6f3370CC4180AE9ED317B01AAc`](https://sepolia-explorer.giwa.io/address/0xbD8c3c60eFDf5d6f3370CC4180AE9ED317B01AAc) |
| YachaRouter proxy | [`0x733132B6f0FEbd58D062f61657F1b3dbb2aDEB5A`](https://sepolia-explorer.giwa.io/address/0x733132B6f0FEbd58D062f61657F1b3dbb2aDEB5A) |
| YachaRouter implementation | [`0xD69eD80ac8FB5064176fa3714BB6bce5A0E806E9`](https://sepolia-explorer.giwa.io/address/0xD69eD80ac8FB5064176fa3714BB6bce5A0E806E9) |
| Lens | [`0x198BdbC54B7abaFc3f781d958e2b9E935064305C`](https://sepolia-explorer.giwa.io/address/0x198BdbC54B7abaFc3f781d958e2b9E935064305C) |
| V3 factory | [`0x00a131Cf1fbEE9b02C4632756a813A32BC250849`](https://sepolia-explorer.giwa.io/address/0x00a131Cf1fbEE9b02C4632756a813A32BC250849) |
| V3LiquidityActor | [`0x9685d85f92dcaC12802B367807352A0afFA5a466`](https://sepolia-explorer.giwa.io/address/0x9685d85f92dcaC12802B367807352A0afFA5a466) |
| V3SwapAdapter | [`0x7e2E8492C0E3C8fF56920CDa02D7D37c60485852`](https://sepolia-explorer.giwa.io/address/0x7e2E8492C0E3C8fF56920CDa02D7D37c60485852) |
| CreatorFeeProcessor | [`0xDfD7a91438B35Ea94C8EAB89c0EE4fFf13E55969`](https://sepolia-explorer.giwa.io/address/0xDfD7a91438B35Ea94C8EAB89c0EE4fFf13E55969) |

이전 router proxy `0x6139848625B395C4e2C347ED6C083dE2077Fb07b`는 더 이상
`BondingCurve.ROUTER_ROLE`을 갖지 않습니다. 다만 permissionless V3 adapter를 사용하는
졸업 후 경로는 계속 호출 가능하므로, 위 YachaRouter와 Lens 주소를 canonical 통합 주소로 사용해야 합니다.

현재 LPManager 구현체, YachaRouter ERC1967 proxy와 구현체의 Explorer 소스 검증은 모두
완료됐습니다. Lens는 배포와 온체인 연결 검증은 완료됐지만 Explorer Cloudflare가 검증
제출을 차단해 소스 검증만 대기 중입니다.

LPManager `Collect` 이벤트 업그레이드 트랜잭션은
[`0x2dfa…315e`](https://sepolia-explorer.giwa.io/tx/0x2dfa38f733aa6273381bce0adc4001dce537c122a3e9f1bcda10d580d7f9315e)이며,
새 구현체 배포 트랜잭션은
[`0x46f6…54c4`](https://sepolia-explorer.giwa.io/tx/0x46f6655285f6048322849a69f3ef893a1afd8f4e9f807972663f7863edb354c4)입니다.

### Router 교체 실행 순서

```shell
# 1. live 역할을 변경하지 않고 새 구현체와 프록시 배포
forge script script/deploy/normal/DeployYachaRouter.s.sol:DeployYachaRouter \
  --rpc-url "$RPC_URL" --broadcast --slow

# 2. 새 역할 부여. 이 시점에는 기존 역할도 유지
forge script script/deploy/normal/MigrateYachaRouterRole.s.sol:GrantYachaRouterRole \
  --rpc-url "$RPC_URL" --broadcast --slow

# 3. 새 YACHA_ROUTER를 가리키는 Lens 배포 및 검증
forge script script/deploy/normal/DeployLens.s.sol:DeployLens \
  --rpc-url "$RPC_URL" --broadcast --slow

# 4. 새 Lens/클라이언트 전환 확인 후 기존 curve 역할 회수
forge script script/deploy/normal/MigrateYachaRouterRole.s.sol:RevokePreviousRouterRole \
  --rpc-url "$RPC_URL" --broadcast --slow
```

grant와 revoke 단계는 각 단계의 완료 상태에서 재실행해도 추가 변경이 없는 방식으로 검증됩니다.
프라이빗 키와 `.env*` 파일은 절대 커밋하지 않습니다.

## 보안 속성

- canonical pool/factory/token order/fee tier/reverse registry 검증
- 단일 활성 컨텍스트에 결합된 mint/swap callback 인증
- 원금 출금 경로가 없는 영구 LP 포지션
- curve, LP fee, swap, processor, vault의 정확한 balance-delta 회계
- 기존 donation과 호출 범위 자산의 격리
- swap/transfer/vault 실패 시 전체 fee batch 원자적 revert
- BondingCurve role 및 `ProtocolManager.canCall()` 기반 selector 권한
- WNATIVE 경로 외 native 수신 거부와 호출 범위 refund

상세 API:
[YachaRouter](docs/contracts/ko/router/YachaRouter.md),
[IYachaRouter](docs/contracts/ko/interfaces/IYachaRouter.md),
[LPManager](docs/contracts/ko/core/LPManager.md),
[ProtocolManager](docs/contracts/ko/core/ProtocolManager.md),
[V3SwapAdapter](docs/contracts/ko/adapters/V3SwapAdapter.md).
