# GiftVault

**Path:** `src/vault/GiftVault.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

오프체인 `(Platform, id)` (GitHub / X)을 앵커로 쓰는 **claim 모델** Gift Vault. 수수료는 토큰별로 vault에 누적되고, 바인딩된 `receiver`가 `claim(token)`을 호출해 전액을 가져간다. 싱글톤으로 배포되어 모든 토큰이 하나의 인스턴스를 공유.

토큰은 상호 배타적인 3가지 상태로 흐른다:

- **Accumulating** — receiver 미바인딩. `afterDeposit`이 `gift.balance`를 누적. bind window(`createdAt + expiryDuration`)가 `setup()` 시점부터 돌아간다.
- **Active** — receiver 바인딩 완료. `afterDeposit`은 여전히 `gift.balance`에 누적. receiver가 `claim(token)`으로 전액 인출. 만료 없음 — 언제든, 반복해서 claim 가능.
- **Burned** (영구) — bind window가 끝난 뒤 deposit이 도착한 순간 확정. 누적분과 이번 deposit이 모두 buyback-burn, 이후 모든 deposit도 buyback-burn. terminal.

---

## 상수

| 상수 | 값 | 용도 |
|------|---|------|
| `BURN_ADDRESS` | `address(0xdead)` | buyback-burn 토큰 송부처 (알려진 프라이빗 키 없음) |

---

## Platform enum

| 값 | 설명 |
|----|------|
| `Platform.GitHub` | GitHub username |
| `Platform.X` | X (구 Twitter) handle |

---

## GiftTarget 구조체 (setup 입력)

| 필드 | 타입 | 용도 |
|------|------|------|
| `platform` | `Platform` | 어느 플랫폼인지 (GitHub / X) |
| `id` | `string` | 플랫폼 사용자 id / handle (예: `"alice"`) |

`setup()`에 `abi.encode(GiftTarget)`로 전달.

---

## GiftInfo 구조체 (storage)

| 필드 | 타입 | 용도 |
|------|------|------|
| `state` | `State` | 현재 상태 (enum, 아래 표 참조). `platform` + `receiver`와 같은 슬롯에 패킹 |
| `platform` | `Platform` | setup 시점 플랫폼 기록 |
| `receiver` | `address` | 바인딩된 receiver. `state == Active`일 때만 non-zero |
| `balance` | `uint256` | claim 대기 중인 누적 quoteToken 잔액 |
| `createdAt` | `uint256` | `setup()` 시각. bind window 타이머 기준점 |
| `id` | `string` | 플랫폼 id 원문 저장. 비어있지 않음 여부가 중복 setup 방지 역할도 겸함 |

### State enum

| 값 | 설명 |
|----|------|
| `State.Accumulating` | receiver 미바인딩. bind window 안에서 `afterDeposit`이 balance를 누적 |
| `State.Active` | receiver 바인딩 완료. balance 계속 누적, receiver가 `claim(token)`으로 인출 |
| `State.Burned` | bind window 만료 후 deposit 도착 시 확정. terminal |

전이: `Accumulating → Active` (`setReceiver`), `Accumulating → Burned` (`afterDeposit` 만료), `Active → Active` (rotate). `Burned`에서 벗어나는 경로 없음.

---

## 상태 변수

| 변수 | 타입 | 설정 | 용도 |
|------|------|------|------|
| `creatorFeeProcessor` | `address` | initialize | `afterDeposit` 권한 |
| `bondingCurve` | `address` | initialize | `setup` 권한 + 본딩 phase 바이백에 쓰임 |
| `tokenRegistry` | `ITokenRegistry` | initialize | pair / adapter 조회, quoteToken 조회 |
| `expiryDuration` | `uint256` | initialize / `setExpiryDuration` | `createdAt` 이후 bind 가능한 기간 |
| `router` | `address` | initialize | 본딩 phase 바이백에 쓰는 `GiwaRouter` |
| `wmon` | `address` | initialize | 래핑 네이티브 싱글톤. `claim` 시점의 등록 quote == `wmon`이면 unwrap해서 native MON으로 전송. `address(0)`이면 unwrap 비활성 (모든 quote에 대해 ERC20 transfer) |
| `_gifts` | `mapping(address => GiftInfo)` | setup / afterDeposit / setReceiver / claim | 토큰별 gift 레코드. state + receiver + balance의 단일 source |

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `initialize(protocolManager_, creatorFeeProcessor_, bondingCurve_, tokenRegistry_, expiryDuration_, router_, wmon_, metadataURI_)` | initializer | UUPS 초기화. `wmon_`이 등록되면 `claim`에서 quote == wmon일 때 native unwrap 활성 |
| `receive() external payable` | `msg.sender == wmon`만 | `IWrappedNative.withdraw` 콜백 수신용. 다른 발신자는 `UnexpectedNative` 리버트 |
| `setup(token, data)` | `bondingCurve`만 | 토큰별 `(platform, id)` 등록 + `createdAt` 기록. `data = abi.encode(GiftTarget)` |
| `afterDeposit(token, quoteToken, amount)` | `creatorFeeProcessor`만 | 상태에 따라 burn / accumulate / expire+burn 분기 |
| `setReceiver(token, receiver)` | **restricted** | receiver 바인딩 또는 교체. 포인터만 바꾸는 단순 호출 — 누적 balance는 그대로 남아 새 receiver가 상속. `state != Burned` 한에서만 허용 |
| `claim(token)` | `msg.sender == gift.receiver`, `nonReentrant` | 바인딩된 receiver에게 누적 balance 전액 인출. 등록 quote == `wmon`이면 unwrap해서 native MON으로 송금. 반복 가능 |
| `setExpiryDuration(newDuration)` | restricted | bind window 변경 (Accumulating 토큰에 즉시 반영) |
| `getGiftInfo(token)` | view | `GiftInfo` 레코드 조회 |
| `isExpired(token)` | view | `_expired[token]` |
| `getReceiver(token)` | view | `_receivers[token]` (0 = 미바인딩) |
| `pendingQuote(token)` | view | 본딩 phase 바이백에서 부분체결되고 남은 quoteToken 보관분 |

---

## 동작

### `setup(token, data)`

```
bondingCurve -> GiftVault.setup(token, abi.encode(GiftTarget{platform, id}))
  |-- GiftTarget 디코드
  |-- id 비어있지 않은지 (EmptyId)
  |-- 이미 setup되지 않았는지 (AlreadyConfigured)
  |-- _gifts[token] = { state: Accumulating, platform, receiver: 0, balance: 0, createdAt: now, id }
  +-- emit VaultSetup(token, platform, id)
```

`setup()` 직후 토큰은 **Accumulating** 상태.

### `afterDeposit(token, quoteToken, amount)`

```
creatorFeeProcessor -> GiftVault.afterDeposit(token, quoteToken, amount)
  |-- amount == 0 → return
  |-- gift = _gifts[token]
  |
  |-- if gift.state == Burned:
  |     buybackAndBurn(amount)
  |     return
  |
  |-- if gift.state == Active:                         # 누적만
  |     gift.balance += amount
  |     emit Deposit(token, amount, gift.balance)
  |     return
  |
  |-- # Accumulating
  |-- if block.timestamp > gift.createdAt + expiryDuration:
  |     total = gift.balance + amount
  |     gift.balance = 0
  |     gift.state = Burned                             # terminal: Accumulating → Burned
  |     emit Expire(token, total)
  |     buybackAndBurn(total)
  |     return
  |
  |-- gift.balance += amount
  +-- emit Deposit(token, amount, gift.balance)
```

Active는 vault 밖으로 직접 보내지 않는다 — 인출은 `claim()`이 담당.

### `setReceiver(token, receiver)`

```
relayer -> GiftVault.setReceiver(token, receiver)
  |-- require receiver != 0 (ZeroReceiver)
  |-- gift = _gifts[token]
  |-- require gift.state != Burned (GiftExpiredError)
  |-- require setup()된 토큰 (NotConfigured)
  |-- gift.receiver = receiver
  |-- gift.state = Active                              # 최초 bind 시 Accumulating → Active (rotate는 no-op)
  +-- emit ReceiverSet(token, receiver)
```

최초 bind와 rotate가 동일하게 처리됨: receiver 포인터만 교체되고 `gift.balance`는 vault에 그대로 남는다. **현재 receiver는 항상 전체 누적 잔액의 권리자** — rotate 시 새 receiver가 모든 잔액을 상속하고 이전 receiver는 claim 권한을 잃는다.

### `claim(token)`

```
receiver -> GiftVault.claim(token)
  |-- gift = _gifts[token]
  |-- require gift.state == Active (NotReceiver)
  |-- require msg.sender == gift.receiver (NotReceiver)
  |-- amount = gift.balance
  |-- require amount > 0 (ZeroBalance)
  |-- gift.balance = 0                                # CEI: 외부 호출 전 state 정리
  |-- quoteToken = tokenRegistry.getQuoteToken(token)
  |-- if wmon != 0 && quoteToken == wmon:
  |     IWrappedNative(wmon).withdraw(amount)         # WMON unwrap → vault에 native MON
  |     (ok,) = receiver.call{value: amount}("")      # native를 receiver에게 전달
  |     require(ok, NativeTransferFailed)
  |-- else:
  |     IERC20(quoteToken).safeTransfer(receiver, amount)
  +-- emit Claim(token, receiver, amount)
```

claim 만료 없음. 반복 가능 — claim 후 새 `afterDeposit`이 balance를 다시 키우면 같은 receiver가 또 claim 가능.

방어 다층 구성: `claim`에 `nonReentrant` (OZ `ReentrancyGuard`, ERC-7201 namespaced storage — proxy 안전) + CEI(`gift.balance = 0`을 외부 호출 전에 적용). 둘 중 하나만 있어도 현 구조에선 충분하지만, 향후 WMON unwrap 콜백과 state를 공유하는 cross-function 경로가 추가될 가능성에 대비.

---

## `_buybackAndBurn(token, quoteToken, amount)`

```
_buybackAndBurn(token, quoteToken, amount)
  |-- if IToken(token).isGraduated():
  |     info    = tokenRegistry.getTokenInfo(token)
  |     adapter = tokenRegistry.getAdapter(info.dexType)
  |     safeTransfer(quoteToken → adapter, amount)
  |     tokenReceived = adapter.swap(pair, quoteToken, token, amount, this, "")
  |-- else (본딩 phase):
  |     forceApprove(router, amount)
  |     tokenReceived = GiwaRouter.buy({ amountIn: amount, amountOutMin: 1 })
  |     # clamped buy 시 남은 quote는 _pendingQuote[token]에 쌓여 다음 호출에 합산
  |-- if tokenReceived > 0:
  |     safeTransfer(token → 0xdead, tokenReceived)
  |     emit Burn(token, pair, spent, tokenReceived)
```

`BurnVault`와 동일한 dual-path 패턴. 본딩 phase는 `GiwaRouter.buy`로 clamped buy 부분체결을 처리하고, 졸업 이후는 등록된 DEX adapter swap. pending buyback은 self-call `try/catch`로 실행되어 실패 시 pending quote를 재시도용으로 보존하고 상위 gift/settlement 작업을 revert하지 않는다.

---

## 엔드-투-엔드 플로우

```
1. 토큰 생성
   Creator -> BondingCurve.create(vaults: [{ vault: giftVault, setupData: abi.encode(GiftTarget{Platform.X, "alice"}) }])
   -> GiftVault.setup(token, data) -> _gifts[token] = { platform: Platform.X, id: "alice", createdAt: now }

2. 수수료 누적 (Accumulating 또는 Active)
   거래 -> FeeCollector -> CreatorFeeProcessor -> GiftVault.afterDeposit(token, quote, amount)
   -> gift.balance += amount

3a. Happy path — relayer가 id 소유자 확인 후 receiver 바인딩, receiver가 claim
    오프체인: relayer가 @alice OAuth 소유 증명 확인
    -> relayer.setReceiver(token, claimerWallet)          [Accumulating → Active, balance 유지]
    -> claimerWallet.claim(token)                          [receiver가 전액 인출]
    -> 이후 수수료 누적되면 claimerWallet이 또 claim 가능

3b. Rotation — 수령인 지갑 교체
    -> relayer.setReceiver(token, newClaimerWallet)
    -> 포인터만 교체. 누적 잔액은 vault에 그대로 남아 newClaimerWallet이 상속
    -> 이후 수수료는 new receiver로 누적, newClaimerWallet가 claim

3c. Burn — bind window 지난 상태에서 setReceiver 없이 deposit 도착
    -> afterDeposit이 block.timestamp > createdAt + expiryDuration 감지
    -> gift.balance + amount buyback-burn, _expired[token] = true (terminal)
    -> setReceiver는 이 토큰에 대해 영구적으로 GiftExpiredError로 revert, 이후 모든 afterDeposit은 burn
```

신뢰 모델: relayer는 claim 대상(receiver)을 지정할 수 있지만, 자신이 자금을 빼낼 수는 없다 (claim은 `msg.sender` 체크). admin은 `ProtocolManager.setOperatorPermission(relayer, giftVault, GiftVault.setReceiver.selector, false)`로 relayer 권한을 즉시 회수해 피해 범위를 제한.

---

## 보안

| 위협 | 대응 |
|------|------|
| 임의 호출자가 receiver 지정 | `setReceiver`에 `restricted` — admin이 selector 권한 부여한 operator만 호출 가능 |
| Relayer self-drain | `claim`은 `msg.sender == gift.receiver` 체크로 receiver만 호출 가능, relayer는 직접 인출 경로 없음 |
| 플랫폼 id 위조 | 오프체인 relayer가 OAuth로 바인딩 전 소유권 검증 |
| Relayer 키 유출 | admin이 `ProtocolManager.setOperatorPermission(relayer, giftVault, setReceiver.selector, false)`로 즉시 회수 |
| Burn 확정 이후 bind / rotate | `gift.state == Burned` → `GiftExpiredError` |
| Relayer mis-rotate로 잘못된 receiver에게 전액 전달 | 신뢰 모델: relayer가 id 소유권 확인 후 `setReceiver` 호출. rotate는 미래/누적 수수료를 모두 새 receiver에게 이전(이전은 권한 상실). admin이 `setOperatorPermission`으로 손상된 relayer 권한 즉시 회수 |
| rotate 후 이전 receiver가 claim 시도 | `msg.sender != gift.receiver` → `NotReceiver` |
| Burned 토큰에 deposit 유입 | `afterDeposit` 최상단 `gift.state == Burned` 체크가 이후 모든 입금을 `_buybackAndBurn`으로 보냄 |
| 비-Active 상태 claim | `gift.state != Active` → `NotReceiver` (방어 계층. 다른 상태에선 `receiver`가 0이라 이미 차단) |
| setup 없이 bind | `bytes(gift.id).length == 0` → `NotConfigured` |
| Zero receiver | `receiver != address(0)` → `ZeroReceiver` |
| 중복 setup | `bytes(gift.id).length != 0` → `AlreadyConfigured` |
| 잔액 0 claim | `balance > 0` 체크 → `ZeroBalance` |
| Native unwrap 송금 실패 (receiver의 receive에서 revert) | `(bool ok,) = receiver.call{value}("")` → `NativeTransferFailed`. 전체 claim revert로 `gift.balance` 복구. `setReceiver`로 새 주소 지정 후 재시도 가능 |
| 임의 native 송금 (실수 입금, 다른 컨트랙트에서 흘러옴) | `receive()`는 `msg.sender == wmon`만 허용 → 그 외 발신자는 `UnexpectedNative` revert. wmon→withdraw 콜백 외 경로로는 native가 vault에 쌓이지 않음 |

---

## 이벤트

| 이벤트 | 매개변수 |
|--------|----------|
| `VaultSetup` | `address indexed token, Platform platform, string id` |
| `Deposit` | `address indexed token, uint256 amount, uint256 newBalance` |
| `ReceiverSet` | `address indexed token, address indexed receiver` |
| `Claim` | `address indexed token, address indexed receiver, uint256 amount` |
| `Expire` | `address indexed token, uint256 amount` |
| `Burn` | `address indexed token, address indexed pair, uint256 quoteIn, uint256 tokenBurned` |
| `ExpiryUpdate` | `uint256 oldDuration, uint256 newDuration` |
