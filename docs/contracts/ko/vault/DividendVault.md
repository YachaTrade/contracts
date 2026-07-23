# DividendVault

**Path:** `src/vault/DividendVault.sol`
**Interface:** `src/interfaces/IDividendVault.sol` (`IDividendVault is IVault`)
**Pattern:** UUPS Proxy (Singleton)
**Inheritance:** `IDividendVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

다수 배당 토큰 분배 볼트. CreatorFeeProcessor로부터 creator fee(quoteToken)를 수신하고, creator가 설정한 1~10개의 배당 토큰으로 BPS 비율에 따라 분할을 **기록**한다 — quoteToken 슬롯은 즉시 적립되고, 나머지 슬라이스는 `pendingSwap`에 누적된다. 누적 슬라이스는 이후 **operator bot이 변환**한다. **router hop**(`hop.adapter == router`)은 본딩 phase 또는 등록된 canonical-V3 토큰에 GiwaRouter를 호출한다. 명시적 레거시 NadFunPair 풀은 `nadSwapAdapter` 레인으로, 외부 시장은 Uniswap adapter 레인으로 변환된다. 분배는 기존과 동일하며 singleton UUPS proxy 하나가 모든 토큰에 공유된다.

컨트랙트는 **라우팅 지식을 보유하지 않는다**: 경로 구성은 전적으로 오프체인 bot의 몫이다. 온체인은 방어만 담당한다 — 어댑터 allowlist, path 끝점 검증, 중간 hop 전량 소비 가드, 실값 `amountOutMin`, pending 슬롯 상한, 원자성.

> 아래의 `ConversionHop` / `DividendConfig` 구조체, 모든 이벤트·에러는 컨트랙트가 아닌 `IDividendVault`(`src/interfaces/IDividendVault.sol`)에 선언된다 — 컨트랙트는 로컬 선언 없이 인터페이스 것을 사용한다 (IVaultRegistry/ICreatorFeeProcessor 패턴). 외부에서 참조할 때는 `IDividendVault.X`로 한정한다.

---

## 상수

| 상수 | 값 | 용도 |
|------|---|------|
| `MAX_DIVIDEND_TOKENS` | `10` | sourceToken당 최대 배당 토큰 수 |

---

## 상태 변수

소스 코드의 섹션 헤더 그룹(Protocol wiring / Dividend config / Conversion accounting / Merkle distribution / Setup allowlist)을 그대로 따른다.

### Protocol wiring

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `tokenRegistryV2` | `ITokenRegistry` | public | source quote 조회와 배당 토큰 입장 검증(`setup`)에 사용하는 V2 registry |
| `creatorFeeProcessor` | `address` | public | `afterDeposit` 호출 권한 |
| `bondingCurve` | `address` | public | `setup` 호출 권한 |
| `router` | `address` | public | GiwaRouter — `executeConversion`의 router hop이 본딩 phase 또는 등록된 canonical-V3 토큰에 `buy`를 호출. `initialize`로 배선되며 `setAdapters` 레인이 아님 |
| `bondingCurveV1` | `IBondingCurveV1` | public | V1 BondingCurve (`src/integration/interfaces/IBondingCurveV1.sol`) — 입장 게이트의 진실 소스: `createdAt != 0` = V1 멤버십 (졸업 후에도 유지), `isGraduated` = 단방향 졸업 플래그 |
| `nadSwapAdapter` | `IDexAdapter` | public | 볼트 보유 allowlist 레인 — 일반 NadFunPair 풀 hop용 (USDC/WNATIVE 같은 vanilla 풀, cross-quote 중간 다리 — 라우터는 토큰 주소로만 사므로 임의 풀을 못 함) (0 = 레인 비활성) |
| `uniswapV2Adapter` | `IDexAdapter` | public | 볼트 보유 allowlist 레인 — 외부 Uniswap V2 pair hop용 (0 = 레인 비활성) |
| `uniswapV3Adapter` | `IDexAdapter` | public | 볼트 보유 allowlist 레인 — Capricorn CL / Uniswap V3 pool hop용 (0 = 레인 비활성) |
| `wnative` | `address` | public | claim 시 native 언래핑에만 쓰이는 WNATIVE 싱글톤 (0 = 언래핑 비활성) |

> **hop은 두 종류, 둘 다 자금 안전:** `executeConversion`은 **router hop**(`hop.adapter == router`)에서 `GiwaRouter.buy`를 직접 호출하고, **adapter hop**에서는 세 보유 레인(`nadSwapAdapter`/`uniswapV2Adapter`/`uniswapV3Adapter`)을 토큰 push 전에 검사한다(`UnknownAdapter`). 잘못된 adapter나 미설정 lane은 자금을 받을 수 없다. GiwaRouter는 pull pattern과 lifecycle dispatch를 가진 상위 router이므로 `IDexAdapter`로 감싸지 않는다. `nadSwapAdapter`는 GiwaRouter의 졸업 후 V3 경로가 거부하는 명시적 레거시 NadFunPair 풀을 담당한다.

### Dividend config

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `_config` | `mapping(sourceToken => DividendConfig)` | private | sourceToken별 배당 설정 (`getConfig`로 접근); 설정 여부 == `dividendTokens.length != 0` |

### Conversion accounting

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `dividendBalance` | `mapping(sourceToken => mapping(dividendToken => uint256))` | public | claim 가능한 누적 배당 잔액 |
| `pendingSwap` | `mapping(sourceToken => mapping(dividendToken => uint256))` | public | bot 변환을 대기하는 quoteToken; (sourceToken, dividendToken) 키라 각 슬롯이 독립적으로 — 전량 또는 분할로 — 변환된다 |

### Merkle distribution

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `merkleRoot` | `bytes32` | public | 현재 글로벌 Merkle root (period 식별자) |
| `claimedCumulative` | `mapping(sourceToken => mapping(holder => mapping(dividendToken => uint256)))` | public | (source, holder, dividend)별 누적 지급액. 단조 증가 high-water mark; `claim`은 `leafAmount - claimedCumulative`만 지급 → 재발행/같음/낮은 root는 0 지급 (root 간 race-free) |

### Setup allowlist

| 변수 | 타입 | 가시성 | 용도 |
|------|------|--------|------|
| `allowedDividendToken` | `mapping(token => bool)` | public | 외부(V2 미등록) 배당 토큰의 `setup` 입장을 admin이 개방 — 졸업한 V1 토큰, USDT-quoted 자산, 임의 외부 ERC20 |

> **V1 입장 게이트:** `setAllowedDividendToken(token, true)`는 codeless 주소를 `NotContract`로,
> V1 BondingCurve가 "생성됐지만 미졸업"으로 보고하는 V1 토큰을 `V1TokenNotGraduated`로 거부한다.
> 졸업 전 V1 토큰은 변환 lane이 없어(Capricorn CL pool 부재, GiwaRouter도 V1 lifecycle metadata를 라우팅하지 않음) 입장을
> 허용하면 `pendingSwap` quote가 졸업 — 영원히 안 올 수도 있는 — 때까지 잠긴다. code 체크는
> CREATE2 예측 주소 우회를 봉쇄한다: V1은 `create()`에서 토큰 코드 배포와 `createdAt` 기록이
> 원자적이므로, 아직 생성되지 않은 V1 주소가 "외부 ERC20"으로 통과할 수 없다. 졸업은 단방향이라
> 게이트는 입장 시점 1회만 실행된다 — `setup`·변환 시점 재검사 없음. 제거 경로(`allowed = false`)는
> 무검사.

`metadataURI`(`string`, IVault 메타데이터 URI)는 Merkle 그룹과 setup allowlist 사이에 선언된다.

### 구조체

**`DividendConfig`**

| 필드 | 타입 | 설명 |
|------|------|------|
| `dividendTokens` | `address[]` | 배당 토큰 주소 목록 (1~10개) |
| `ratios` | `uint16[]` | BPS 비율 (합계 = 10000), `dividendTokens`와 길이 일치 |
| `minBalance` | `uint256` | claim 자격 최소 sourceToken 보유량 (creator가 setup 시 지정, 고정) |

> 설정 여부는 `dividendTokens.length != 0`으로 판정 — `setup`은 재설정을 거부하고(`AlreadyConfigured`) 비활성화 경로는 없다. `claim`도 동일한 길이 체크로 미설정 sourceToken에 revert한다(`SourceNotConfigured`).

**`ConversionOrder`**

| 필드 | 타입 | 설명 |
|------|------|------|
| `sourceToken` | `address` | 이 order가 소비하는 pending 슬롯의 source 토큰 |
| `dividendToken` | `address` | 대상 배당 토큰 (마지막 hop의 `tokenOut`과 일치해야 함) |
| `path` | `ConversionHop[]` | source quote → 배당 토큰으로 가는 bot 공급 hop 시퀀스 |
| `quoteIn` | `uint256` | 변환할 source quote 양 (pending 슬롯 이하, `ExcessiveConversion`) |
| `amountOutMin` | `uint256` | bot의 실시간 최소 수령 시세 (`InsufficientOutput`) |

**`ConversionHop`**

| 필드 | 타입 | 설명 |
|------|------|------|
| `adapter` | `IDexAdapter` | hop 디스패치 키. `router`와 같으면 router hop(`GiwaRouter.buy`), 아니면 `nadSwapAdapter`/`uniswapV2Adapter`/`uniswapV3Adapter` 중 하나여야 함 (아니면 `UnknownAdapter`) |
| `pair` | `address` | adapter hop의 NadFunPair / V2 pair / V3 pool 주소. **router hop에선 무시**(라우터는 토큰으로 시장을 해석 — 풀 주소 없음). bot 공급 — 자금 보호는 pair 검증이 아니라 디스패치 키 + `amountOutMin`이 담당 |
| `tokenOut` | `address` | 이 hop의 출력 토큰; 마지막 hop의 `tokenOut`은 대상 배당 토큰과 일치해야 함 (`InvalidPath`) |

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `initialize(protocolManager, tokenRegistryV2, creatorFeeProcessor, bondingCurve, router, bondingCurveV1, metadataURI)` | initializer | UUPS 프록시 초기화 — 모든 주소 zero 체크; `bondingCurveV1`은 추가로 코드 존재 요구(`NotContract`, 잘못된 주소로 V1 게이트가 조용히 무력화되는 것 방지) |
| `setup(sourceToken, data)` | bondingCurve 전용 | 배당 토큰, 비율, minBalance 설정 |
| `afterDeposit(sourceToken, quoteToken, amount)` | creatorFeeProcessor 전용 | 기록 전용 진입점: 비율 분할 기록(quoteToken 슬롯 → `dividendBalance`, 나머지 → `pendingSwap`); 외부 호출 0, 변환 없음 |
| `executeConversion(ConversionOrder[] orders)` | restricted (operator bot) | 단일 변환 진입점: pending quote 슬라이스들을 명시적 `ConversionHop[]` 어댑터 경로로 변환 — 배치, 순차, 원자적(한 order 실패 시 전체 배치 revert); `nonReentrant` |
| `setMerkleRoot(newRoot)` | restricted (operator) | 새 글로벌 Merkle root 게시 (새 claim period 시작) |
| `claim(sourceTokens[], dividendTokens[], amounts[], merkleProofs[])` | anyone (본인 claim) | 배당 수령; leaf amount는 전체 누적 accrued, `amount - claimedCumulative`만 지급 |
| `setWnative(newWnative)` | restricted (admin) | claim 시 native 언래핑용 WNATIVE 설정 (`0` = 언래핑 비활성) |
| `setAdapters(nadSwapAdapter, uniswapV2Adapter, uniswapV3Adapter)` | restricted (admin) | 세 어댑터 레인 교체 (개별 `0` = 해당 레인 비활성). router hop은 레인 배선 불필요 — init의 `router` 사용 |
| `setAllowedDividendToken(token, allowed)` | restricted (admin) | 외부(V2 미등록) 배당 토큰의 `setup` 입장 개방/폐쇄. 개방(`true`)은 코드 존재(`NotContract`)와 V1 미졸업 차단(`V1TokenNotGraduated`)을 통과해야 함; 폐쇄는 무검사 |
| `getConfig(sourceToken)` | external view | sourceToken의 `DividendConfig` 반환 |
| `supportsInterface(interfaceId)` | external pure | ERC-165: `IVault`, `IERC165` 지원 여부 |

---

## 핵심 로직: setup

```
BondingCurve -> DividendVault.setup(sourceToken, abi.encode(dividendTokens, ratios, minBalance))
  |-- 검증: 1 ≤ length ≤ 10, ratios.length == dividendTokens.length, sum(ratios) == 10000
  |-- 각 dividendToken dt:
  |     |-- dt == quoteToken                       → OK (무변환 슬롯, afterDeposit에서 즉시 적립)
  |     |-- tokenRegistryV2.isRegistered(dt)       → OK (nad.fun V2 토큰, 본딩·졸업 무관)
  |     |-- allowedDividendToken[dt]               → OK (admin이 입장 개방한 외부 토큰)
  |     |-- protocolManager.isAllowed(dt)          → OK (설정된 quote 토큰, 예: WNATIVE / LvMON)
  |     |-- bondingCurveV1.createdAt(dt) != 0 && isGraduated(dt) → OK (졸업한 V1 토큰, DEX 풀 있음)
  |     +-- else                                   → revert UnsupportedDividendToken
  |-- 중복 dividendToken 금지 (DuplicateDividendToken)
  +-- _config[sourceToken] 저장 (설정 여부 == dividendTokens.length != 0); emit DividendSetup
```

> **quote 일치 검증 없음.** `setup`은 *입장*만 게이트한다 — 배당 토큰이 어떤 quote로 거래되는지는
> 따지지 않는다. cross-quote 시장(예: LvMON quote source가 WNATIVE quote 배당 토큰을 지급, 또는
> XAUT 같은 USDT-quoted 자산)은 전부 변환 시점에 bot의 path 구성으로 해결된다. 졸업한 V1 토큰·외부
> ERC20은 `setAllowedDividendToken(dt, true)`로 입장한다 — 이 입구 자체가 codeless 주소와 졸업 전
> V1 토큰을 거부한다(위 V1 입장 게이트 참조). 온체인 라우팅 지식 없이 "미등록 토큰 revert" 방어는
> 그대로 유지된다.

---

## 핵심 로직: afterDeposit (기록만)

```
CreatorFeeProcessor -> transfer(quoteToken, vault, amount)
CreatorFeeProcessor -> vault.afterDeposit(sourceToken, quoteToken, amount)
  |-- 입금 분할을 기록만 한다 (외부 호출 0; amount == 0이면 분할 생략):
  |     amount를 ratios대로 분할 (마지막 슬롯이 반올림 잔액 흡수; slice == 0이면 상태 기록 skip):
  |       |-- dt == quoteToken: dividendBalance[sourceToken][dt] += slice  (pending[i] = false)
  |       +-- else:             pendingSwap[sourceToken][dt]     += slice  (pending[i] = true)
  |-- 루프 종료 후 Deposit(sourceToken, dividendTokens[], slices[], pending[]) 1회 emit (tokenCount > 0)
  +-- 끝. 변환도, self-call도, try/catch도 없음 — 변환은 이후 operator bot이 수행한다.
```

> `afterDeposit`은 라우팅·유동성 문제로 실패할 수 없다 — 스토리지만 건드리므로 settle 파이프라인이
> 구조적으로 보호된다 (이전 설계는 이를 위해 try/catch self-call이 필요했다). 모든 non-quote
> 슬라이스는 bot이 변환할 때까지 `pendingSwap`에서 대기한다.

---

## 핵심 로직: executeConversion (bot 공급 path)

```
operator bot -> executeConversion(ConversionOrder[] orders)   [restricted, nonReentrant]
  |-- orders.length == 0                            → revert InvalidPath
  |-- 각 order {sourceToken, dividendToken, path[], quoteIn, amountOutMin} — 순차·원자적
  |   (한 order라도 실패하면 배치 전체 revert; bot이 실패 order를 빼고 재제출):
  |-- pending = pendingSwap[sourceToken][dividendToken]
  |-- quoteIn > pending                             → revert ExcessiveConversion
  |-- path.length == 0                              → revert InvalidPath
  |-- path[마지막].tokenOut != dividendToken         → revert InvalidPath  (끝점 검증)
  |-- currentToken = tokenRegistryV2.getQuoteToken(sourceToken); currentAmount = quoteIn
  |-- sourceQuoteBalanceBefore = balanceOf(currentToken, this)
  |-- 각 hop i:
  |     |-- inputBalanceBefore / tokenOutBalanceBefore 스냅샷 후 hop 종류로 디스패치:
  |     |   ROUTER HOP (hop.adapter == router):
  |     |     forceApprove(currentToken → router, currentAmount)
  |     |     router.buy({amountIn: currentAmount, amountOutMin: 0, token: tokenOut, to: this, deadline: now})
  |     |     forceApprove(currentToken → router, 0)
  |     |     (router가 vault에서 currentAmount pull → 미소비분을 vault로 직접 refund)
  |     |   ADAPTER HOP (else): 토큰 push 전에 멤버십 검사 (평탄 if; zero/미설정 레인은 매칭 안 됨):
  |     |     hop.adapter ∉ {nadSwapAdapter, uniswapV2Adapter, uniswapV3Adapter}
  |     |                                           → revert UnknownAdapter   (address(0)도 여기; router는 nonzero)
  |     |     safeTransfer(currentToken, hop.adapter, currentAmount)    (push 패턴)
  |     |     adapter.swap(hop.pair, currentToken, tokenOut, currentAmount, this, "")
  |     |-- i == 0: consumed = sourceQuoteBalanceBefore - inputBalanceAfter
  |     |     (첫 hop 부분 체결은 **수용** — 환불은 잔액 델타로 돌아오고
  |     |      pendingSwap은 실소비량만큼만 차감된다)
  |     |-- i != 0: inputBalanceAfter > inputBalanceBefore - currentAmount → revert PathResidue
  |     |     (중간 hop 부분 체결은 pendingSwap 회계 밖의 **중간 토큰**을 환불받는 상황 —
  |     |      변환 전체를 revert하고 bot이 새 path/규모로 재시도. 델타 기준 검사라
  |     |      vault의 해당 토큰 기존 보유분과는 분리됨)
  |     +-- currentAmount = balanceOf(hop.tokenOut, this) 델타; currentToken = hop.tokenOut
  |-- received = 마지막 hop의 currentAmount
  |-- received < amountOutMin                       → revert InsufficientOutput (bot이 실시간
  |                                                    오프체인 시세를 공급 — 고정 최소값 아님)
  |-- pendingSwap[sourceToken][dividendToken] = pending - consumed
  |-- dividendBalance[sourceToken][dividendToken] += received
  +-- 모든 order 처리 후: emit Converted(sourceTokens[], dividendTokens[], consumedQuote[], received[])
```

> **원자성:** 어느 단계의 revert든(`ExcessiveConversion`, `InvalidPath`, `UnknownAdapter`, adapter
> 스왑 실패, `PathResidue`, `InsufficientOutput`) 배치 전체가 롤백된다 — `pendingSwap`은 보존되고
> bot이 실패 order를 빼고 재시도한다. operator 트랜잭션이므로 try/catch로 완충하지 않는다: 실패는
> bot의 tx receipt에 그대로 드러난다 (fail loud).

---

## 핵심 로직: router hop (본딩 또는 등록 canonical V3)

**router hop**은 본딩 phase 토큰 또는 canonical Uniswap V3로 등록된 졸업 토큰에 유효하다.
bot이 `hop.adapter == router`로 인코딩하면 루프가 `GiwaRouter.buy`를 직접 호출한다.
졸업한 레거시 V2 토큰은 `nadSwapAdapter` lane을 사용해야 하며 GiwaRouter는 해당 metadata를 거부한다.
주문 생성과 실행 사이에 졸업 상태가 바뀌면 bot은 현재 route를 다시 resolve해 재시도해야 한다.

```
hop.adapter == router 인 hop:
  |-- forceApprove(currentToken → router, currentAmount)
  |-- router.buy({amountIn: currentAmount, amountOutMin: 0, token: tokenOut, to: vault, deadline: now})
  |     (슬리피지는 path 완료 후 VAULT의 order 레벨 amountOutMin이 강제; 출력은 라우터가 vault로 직송)
  +-- forceApprove(currentToken → router, 0)
  # router가 vault(msg.sender)에서 currentAmount를 pull하고 미소비분을 buy() 안에서 vault로 직접
  # refund하므로, vault의 잔액-델타 consumed 회계가 실소비 quote만큼만 pendingSwap을 차감 — 중계 없음.
```

`hop.pair`는 router hop에서 무시된다(라우터가 token metadata로 시장을 resolve한다).
본딩 졸업 임계점 또는 V3 price limit 부분 체결은 첫-hop 부분 체결과 똑같이 동작한다: 환불은 vault에 남고 미소비
슬라이스는 이후 order를 위해 `pendingSwap`에 잔존한다. 첫 hop이 아닌 위치에서 같은 환불이
발생하면 `PathResidue`로 revert되므로(중간 토큰은 pending 회계 밖), 본딩 buy로 끝나는
cross-quote 경로는 입력을 전량 소비할 때만 정산된다.

---

## 핵심 로직: claim (누적청구 모델)

merkle leaf의 `amount`는 그 홀더의 `(sourceToken, dividendToken)` **전체 누적 accrued**다 — 오프체인
scheduler는 아무것도 빼지 않는다. 컨트랙트가 미청구 delta(`amount - claimedCumulative`)만 지급하고
`claimedCumulative`를 leaf amount로 전진시킨다(단조 증가 high-water mark). 같거나 낮은 누적의 root를
재발행해도 0 지급 → **root 타이밍 무관하게 race-free** (홀더 총 수령액은 최신 leaf amount를 못 넘음).

```
holder -> DividendVault.claim(sourceTokens[], dividendTokens[], amounts[], merkleProofs[])
  |-- nonReentrant
  |-- length > 0 이고 모든 배열 길이 일치, 아니면 InvalidArrayLength
  |-- merkleRoot != bytes32(0), 아니면 InvalidMerkleRoot
  |-- 각 항목 i — skip/revert 규칙:
  |     1. amount == 0                              → skip
  |     2. leaf = keccak256(abi.encode(sourceToken, msg.sender, dividendToken, amount))
  |        MerkleProof.verify 실패                  → revert InvalidMerkleProof
  |     3. _config[sourceToken].dividendTokens.length == 0 → revert SourceNotConfigured
  |     4. balanceOf(sourceToken, msg.sender) < minBalance → revert BelowMinBalance (eligibility 미달)
  |     5. alreadyClaimed = claimedCumulative[sourceToken][msg.sender][dividendToken]
  |        amount <= alreadyClaimed                 → skip (신규 누적 없음; 재발행/낮은 root)
  |        payout = amount - alreadyClaimed
  |     6. balanceOf(dividendToken, vault) < payout → revert InsufficientVaultBalance
  |        (누적 전진 안 함 → 볼트 충전 후 재청구 가능)
  |     7. claimedCumulative[sourceToken][msg.sender][dividendToken] = amount  (CEI: 전송 전 high-water mark 갱신)
  |     8. 지급 (인라인):
  |           dividendToken == wnative && wnative != 0:
  |             IWrappedNative(wnative).withdraw(payout)
  |             TransferHelper.safeTransferNative(msg.sender, payout)
  |           else: IERC20(dividendToken).safeTransfer(msg.sender, payout)
  +-- 모든 항목 처리 후: emit Claim(msg.sender, sourceTokens[], dividendTokens[], paidAmounts[])

receive() external payable { if (msg.sender != wnative) revert UnexpectedNative(); }
```

---

## Bot 변환 (operator 운영 가이드)

볼트는 배당 파이프라인을 3단으로 분리한다:

```
[기록 — 온체인 자동]   afterDeposit: auth + 비율 분할 기록만 (외부 호출 0)
[변환 — bot 주도]      operator bot이 path를 들고 executeConversion 호출
[분배 — 기존 유지]     setMerkleRoot → claim
```

라우팅 지식은 전부 **오프체인 operator bot**에 있다 — 컨트랙트에는 route 테이블도, registry
캐스케이드도, quote 정규화 로직도 없다. 새 quote, 새 시장(예: XAUT/USDT), V1 토큰은 전부 bot의
path 구성 문제이고 컨트랙트는 변경되지 않는다.

| 배당 토큰 | 변환 호출 | bot path |
|---|---|---|
| source quoteToken 자체 | 없음 — `afterDeposit`이 `dividendBalance`에 직접 적립 | — |
| V2 토큰 (본딩 **또는** 졸업 — 분기는 라우터 소관) | `executeConversion` | 단일 router hop: `hop.adapter = router`, `tokenOut = 해당 토큰` (`pair` 무시) |
| 일반 NadFunPair 풀 (vanilla 풀 / cross-quote 중간 다리) | `executeConversion` | nadSwapAdapter hop: `hop.adapter = nadSwapAdapter`, `pair = 해당 NadFunPair` |
| V1 졸업토큰 (Capricorn CL) | `executeConversion` | `uniswapV3Adapter` hop; source quote와 pool quote가 다르면 multi-hop (예: LvMON→WNATIVE→토큰). setup 입장은 admin이 `setAllowedDividendToken`으로 개방 |
| 그 외 외부 ERC20 / cross-quote 시장 (예: XAUT/USDT) | `executeConversion` | router hop + 세 어댑터 레인을 조합한 임의 multi-hop. setup 입장은 admin이 `setAllowedDividendToken`으로 개방 |
| cross-quote V2 본딩토큰 | router hop으로 끝나는 multi-hop (예: `quoteA →(uni) quoteB →(router) 토큰`) — 전량 소비일 때만 정산: 첫 hop이 아닌 위치의 졸업 임계점 환불은 `PathResidue` revert, bot이 더 작은 `quoteIn`으로 재시도 | — |
| 졸업 전 V1 토큰 | **입장 불가** — `setAllowedDividendToken`이 `V1TokenNotGraduated` revert (변환 lane이 없어 입장 시 `pendingSwap` 잠김); 졸업 후 입장 | — |

**온체인 방어 (컨트랙트가 여전히 강제하는 것):**

- **hop 디스패치 allowlist** — router hop은 init의 `router`로, adapter hop은 세 보유 레인
  (`nadSwapAdapter` / `uniswapV2Adapter` / `uniswapV3Adapter`, `setAdapters`로 배선)으로; adapter hop은 토큰 push
  **전에** 평탄 if로 멤버십 검사 (`UnknownAdapter`).
- **path 끝점 검증** — path는 비어 있지 않고 마지막 hop이 대상 배당 토큰을 출력해야 함 (`InvalidPath`).
- **중간 hop 전량 소비** — 중간 hop의 부분 체결은 변환 전체를 revert (`PathResidue`); 첫 hop만
  부분 체결이 허용되고 `pendingSwap`은 실소비량만큼 차감.
- **실값 `amountOutMin`** — bot이 order마다 실시간 시세로 공급, path 완료 후 VAULT가 검사
  (`InsufficientOutput`); router hop은 하류에 `amountOutMin = 0`을 전달하는데, order 레벨 검사가
  동일한 원자적 revert 경계이기 때문이다.
- **pending 상한** — `quoteIn`은 기록된 pending 슬롯을 초과할 수 없음 (`ExcessiveConversion`).
- **원자성** — 어떤 revert든 `pendingSwap` 보존; 경로 중간에서 잃는 자금 없음.

**신뢰 모델:** operator는 이미 Merkle root로 분배 전권 — 누구에게 얼마를 지급할지 — 을 신뢰받는
주체다. path 공급은 그보다 작은 권한이다: 자금은 vault → allowlist 어댑터 → vault로만 이동하고,
끝점과 최소 수령량이 온체인에서 강제된다. `setMerkleRoot`(분배)와 `executeConversion`(변환)은 **별도
EOA로 키 분리** — `restricted`가 selector별 operator 권한이라 자연 지원, 한 키 유출 시 blast radius
축소. 변환은 settle 즉시가 아닌 bot 주기로 일어난다 — 분배 자체가 주기적 root 게시라 제품상 동등.

- 새 어댑터 *종류* 지원은 보유 레인 + 평탄 디스패치 분기를 추가하는 컨트랙트 업그레이드 필요 —
  확장 마찰 대신 fail-loud 경로 안전을 택한 트레이드오프.
- `wnative`은 이제 claim native 언래핑에만 쓰인다; 변환에는 관여하지 않는다.

---

## 접근 제어

| 함수 | 호출자 | 가드 |
|------|--------|------|
| `setup` | BondingCurve | `msg.sender == bondingCurve` |
| `afterDeposit` | CreatorFeeProcessor | `msg.sender == creatorFeeProcessor` |
| `executeConversion` | operator bot | `restricted` + `nonReentrant` |
| `setMerkleRoot` | operator | `restricted` |
| `setWnative` | admin | `restricted` |
| `setAdapters` | admin | `restricted` |
| `setAllowedDividendToken` | admin | `restricted` |
| `_authorizeUpgrade` | admin | `restricted` |
| `claim` | anyone (본인만) | `nonReentrant` + proof 검증 + skip 게이트들 |

---

## 이벤트

| 이벤트 | 매개변수 |
|--------|----------|
| `DividendSetup` | `address indexed sourceToken, address[] dividendTokens, uint16[] ratios, uint256 minBalance` |
| `Deposit` | `address indexed sourceToken, address[] dividendTokens, uint256[] slices, bool[] pending` — afterDeposit당 1회, 전체 split(config 순서) 수록. `pending[i] == true`=pendingSwap 적립, `false`=dividendBalance 즉시 적립(quote 슬롯) |
| `Converted` | `address[] sourceTokens, address[] dividendTokens, uint256[] consumedQuote, uint256[] received` (배치 order당 1항목) |
| `SetMerkleRoot` | `bytes32 indexed merkleRoot` |
| `Claim` | `address indexed holder, address[] sourceTokens, address[] dividendTokens, uint256[] amounts` (skip된 항목은 `0`으로 보고) |
| `SetWnative` | `address wnative` |
| `SetAdapters` | `address nadSwapAdapter, address uniswapV2Adapter, address uniswapV3Adapter` |
| `SetAllowedDividendToken` | `address indexed token, bool allowed` |

---

## 에러

| 에러 | 설명 |
|------|------|
| `NotAuthorized()` | 예상 컨트랙트가 아닌 호출자 |
| `ZeroAddress()` | 필수 주소 파라미터가 zero |
| `InvalidTokenCount()` | dividendTokens 길이가 0 또는 10 초과 |
| `LengthMismatch()` | ratios와 dividendTokens 길이 불일치 |
| `AlreadyConfigured()` | sourceToken이 이미 설정됨 (`dividendTokens.length != 0`) |
| `ZeroRatio()` | 비율 항목이 0 |
| `UnsupportedDividendToken()` | `setup`: source quote도, V2 등록 토큰도, admin allowlist 토큰도, 설정된 quote 토큰(`isAllowed`)도 아님 |
| `SourceNotConfigured()` | `claim`: 미설정 sourceToken (dividend config 없음) |
| `BelowMinBalance()` | `claim`: 보유량이 `minBalance` 미만 (eligibility 미달) |
| `InsufficientVaultBalance()` | `claim`: 볼트의 배당 토큰 잔고가 지급액보다 적음 (충전 후 재청구 가능) |
| `DuplicateDividendToken()` | dividendTokens에 동일 주소 중복 |
| `InvalidRatioTotal()` | ratios 합계가 BPS(10000)와 불일치 |
| `InvalidMerkleRoot()` | root가 zero이거나 merkleRoot 미설정 |
| `InvalidMerkleProof()` | Merkle proof 검증 실패 (전체 호출 revert) |
| `InvalidArrayLength()` | claim 배열이 비어 있거나 길이 불일치 |
| `UnexpectedNative()` | wnative 이외 주소에서 native currency 수신 |
| `UnknownAdapter()` | hop의 adapter가 세 볼트 보유 allowlist 레인 중 어느 것도 아님 — 토큰 push **전** 검사 |
| `InvalidPath()` | 변환 path가 비어 있거나, 마지막 hop의 `tokenOut`이 대상 배당 토큰이 아님 |
| `PathResidue()` | 중간 hop이 부분 체결되어 중간 토큰을 환불받음 — 중간 토큰은 `pendingSwap` 회계 밖이므로 변환 전체를 revert하고 깨끗하게 재시도 |
| `InsufficientOutput()` | 최종 수령량이 bot이 공급한 order 레벨 `amountOutMin` 미만 |
| `ExcessiveConversion()` | `quoteIn`이 pending 슬롯 `pendingSwap[sourceToken][dividendToken]`을 초과 |
| `V1TokenNotGraduated()` | `setAllowedDividendToken(token, true)`: V1 BondingCurve가 생성됨(`createdAt != 0`)·미졸업으로 보고 — 변환 lane이 아직 없음 |
| `NotContract()` | `initialize`: `bondingCurveV1`에 코드 없음. `setAllowedDividendToken(token, true)`: 토큰 주소에 코드 없음 (CREATE2 예측 주소 우회 봉쇄) |
