# CreatorFeeVault

**Path:** `src/vault/CreatorFeeVault.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

Claim 모델 기반 크리에이터 수수료 vault. 모든 토큰이 공유하는 싱글톤. `setup()`에서 토큰별 `creator`를 등록하고, `afterDeposit`로 quoteToken이 토큰별로 누적되며, 등록된 creator가 `claim(token)`으로 인출. 토큰 생성자가 크리에이터 수수료 수익을 본인이 관리하는 지갑으로 받고 싶을 때 사용.

---

## 상태 변수

| 변수 | 타입 | 설정 | 용도 |
|------|------|------|------|
| `bondingCurve` | `address` | initialize | `setup` 호출 권한 |
| `creatorFeeProcessor` | `address` | initialize | `afterDeposit` 호출 권한 |
| `tokenRegistry` | `ITokenRegistry` | initialize | claim 시점에 토큰의 `quoteToken` 조회 |
| `metadataURI` | `string` | initialize | 오프체인 메타데이터 URI (`IVault`) |
| `wnative` | `address` | initialize | 래핑 네이티브 싱글톤. `claim` 시점의 등록 quote == `wnative`이면 unwrap해서 native currency으로 전송. `address(0)`이면 unwrap 비활성 (모든 quote에 대해 ERC20 transfer) |
| `_creators` | `mapping(address => address)` | setup / setCreator | 토큰별 creator 포인터; `claim`은 `msg.sender == _creators[token]` 조건 |
| `_balances` | `mapping(address => uint256)` | afterDeposit / claim | 토큰별 누적 quoteToken 잔액 (claim 대기) |

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `initialize(protocolManager_, bondingCurve_, creatorFeeProcessor_, tokenRegistry_, wnative_, metadataURI_)` | initializer | UUPS 초기화. `wnative_` 등록되면 `claim`에서 quote == wnative일 때 native unwrap 활성 |
| `setup(token, data)` | `bondingCurve`만 | 토큰별 creator 등록. `data = abi.encode(creator)` |
| `afterDeposit(token, _, amount)` | `creatorFeeProcessor`만 | creator 등록된 토큰이면 `_balances[token]`에 `amount` 누적 |
| `claim(token)` | `msg.sender == _creators[token]`, `nonReentrant` | 누적 잔액 전액 인출. 등록 quote == `wnative`이면 unwrap해서 native currency으로 송금 |
| `setCreator(token, newCreator)` | **restricted** | 토큰별 creator 교체. 누적 잔액은 새 creator가 상속 (이전 creator는 claim 권한 상실) |
| `getCreator(token)` | view | `_creators[token]` 조회 (0 = 미설정) |
| `getBalance(token)` | view | `_balances[token]` 조회 |
| `receive() external payable` | `msg.sender == wnative`만 | `IWrappedNative.withdraw` 콜백 수신. 다른 발신자는 `UnexpectedNative` revert |

---

## 동작

### `setup(token, data)`

```
bondingCurve -> CreatorFeeVault.setup(token, abi.encode(creator))
  |-- require msg.sender == bondingCurve (NotAuthorized)
  |-- require _creators[token] == 0 (AlreadyConfigured)
  |-- creator = abi.decode(data, (address))
  |-- require creator != 0 (ZeroCreator)
  |-- _creators[token] = creator
  +-- emit VaultSetup(token, creator)
```

### `afterDeposit(token, _, amount)`

```
creatorFeeProcessor -> safeTransfer(quoteToken, vault, amount)
creatorFeeProcessor -> CreatorFeeVault.afterDeposit(token, _, amount)
  |-- require msg.sender == creatorFeeProcessor (NotAuthorized)
  |-- if amount == 0: return
  |-- if _creators[token] == 0: return                # 미설정 토큰은 silent skip
  |-- _balances[token] += amount
  +-- emit Deposit(token, amount, _balances[token])
```

`quoteToken` 인자는 `IVault.afterDeposit` 시그니처에 포함되지만 사용하지 않음 — claim 시점에 `tokenRegistry`로 실시간 quote 조회.

### `claim(token)`

```
creator -> CreatorFeeVault.claim(token)
  |-- creator = _creators[token]
  |-- require msg.sender == creator (NotAuthorized)
  |-- amount = _balances[token]
  |-- require amount > 0 (ZeroBalance)
  |-- _balances[token] = 0                            # CEI: 외부 호출 전 state 정리
  |-- quoteToken = tokenRegistry.getQuoteToken(token)
  |-- if wnative != 0 && quoteToken == wnative:
  |     IWrappedNative(wnative).withdraw(amount)         # WNATIVE unwrap → vault에 native currency
  |     (ok,) = creator.call{value: amount}("")       # native를 creator에게 전달
  |     require(ok, NativeTransferFailed)
  |-- else:
  |     IERC20(quoteToken).safeTransfer(creator, amount)
  +-- emit Claim(token, creator, amount)
```

방어 다층 구성: `claim`에 `nonReentrant` (OZ `ReentrancyGuard`, ERC-7201 namespaced storage — proxy 안전) + CEI(`_balances[token] = 0`을 외부 호출 전에 적용). 둘 중 하나만 있어도 현 구조에선 충분하지만, 향후 WNATIVE unwrap 콜백과 state를 공유하는 cross-function 경로가 추가될 가능성에 대비.

### `setCreator(token, newCreator)`

```
admin / operator -> CreatorFeeVault.setCreator(token, newCreator)
  |-- restricted (admin 또는 setCreator selector 권한 가진 operator)
  |-- require newCreator != 0 (ZeroCreator)
  |-- old = _creators[token]
  |-- require old != 0 (NotConfigured)
  |-- _creators[token] = newCreator
  +-- emit CreatorUpdate(token, old, newCreator)
```

포인터만 교체. `_balances[token]`에 쌓여 있던 잔액은 새 creator가 상속 — 이전 creator는 즉시 claim 권한 상실. creator 핸드오프 또는 위탁 복구 용도.

---

## 엔드-투-엔드 플로우

```
1. 토큰 생성
   Creator -> BondingCurve.create(vaults: [{ vault: creatorFeeVault, setupData: abi.encode(creator) }])
   -> CreatorFeeVault.setup(token, data) -> _creators[token] = creator

2. 수수료 누적
   거래 -> FeeCollector -> CreatorFeeProcessor -> CreatorFeeVault.afterDeposit(token, quote, amount)
   -> _balances[token] += amount

3. Creator가 인출
   creator.claim(token)
   -> 등록 quote == wnative 이면: unwrap해서 native currency 전송
   -> 그 외: ERC20 safeTransfer
   -> _balances[token] = 0

4. (선택) creator 교체
   admin/operator.setCreator(token, newCreator)
   -> claim 권한 + 누적 잔액이 새 포인터로 이전
```

---

## 보안

| 위협 | 대응 |
|------|------|
| 임의 호출자가 `setup` 호출 | `msg.sender == bondingCurve` (NotAuthorized) |
| 임의 호출자가 `afterDeposit` 호출 | `msg.sender == creatorFeeProcessor` (NotAuthorized) |
| 다른 사람의 잔액 claim | `msg.sender == _creators[token]` (NotAuthorized) |
| 같은 토큰에 중복 setup | `_creators[token] != 0` → `AlreadyConfigured` |
| setup/rotate 시 zero creator | `creator != 0` → `ZeroCreator` |
| setup 전 rotate | `_creators[token] != 0` → `NotConfigured` |
| 잔액 0 claim | `_balances[token] > 0` → `ZeroBalance` |
| Native 콜백을 통한 재진입 | `claim`에 `nonReentrant` (OZ `ReentrancyGuard`, ERC-7201 namespaced storage — proxy 안전) + CEI(외부 호출 전 `_balances[token] = 0`). 재진입한 `claim`은 가드에서 차단 |
| Native unwrap 송금 실패 (creator의 receive에서 revert) | `(bool ok,) = creator.call{value}("")` → `NativeTransferFailed`. 전체 claim revert로 `_balances[token]` 복구. `setCreator`로 작동 가능한 주소로 교체 후 재시도 |
| 임의 native 송금 (실수 입금, 다른 컨트랙트에서 흘러옴) | `receive()`는 `msg.sender == wnative`만 허용 → 그 외 발신자는 `UnexpectedNative` revert |
| Rotation 탈취 | `setCreator`는 `restricted` — admin(PM owner) 또는 `setCreator` selector 권한 부여받은 operator만 호출 가능 |

---

## 이벤트

| 이벤트 | 파라미터 |
|--------|----------|
| `VaultSetup` | `address indexed token, address creator` |
| `Deposit` | `address indexed token, uint256 amount, uint256 newBalance` |
| `Claim` | `address indexed token, address indexed creator, uint256 amount` |
| `CreatorUpdate` | `address indexed token, address indexed oldCreator, address indexed newCreator` |
