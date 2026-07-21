# GiftVault

**Path:** `src/vault/GiftVault.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

Claim-model gift vault keyed by an off-chain `(Platform, id)` anchor (GitHub / X). Creator-fee distributions accumulate per token; the bound `receiver` calls `claim(token)` to withdraw. A singleton shared across all tokens.

A token flows through three mutually exclusive states:

- **Accumulating** — no receiver bound. Each `afterDeposit` grows `gift.balance`. A bind window (`createdAt + expiryDuration`) counts down from `setup()`.
- **Active** — a receiver is bound. Each `afterDeposit` still grows `gift.balance`; the receiver withdraws with `claim(token)`. Active never expires — claim is open-ended and repeatable as new fees accrue.
- **Burned** (permanent) — a deposit arrived after the bind window closed without a receiver. The accumulated balance was buyback-burned; every subsequent deposit is buyback-burned too. Terminal.

---

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BURN_ADDRESS` | `address(0xdead)` | Destination for buyback-burned tokens (no known private key) |

---

## Platform enum

| Value | Description |
|-------|-------------|
| `Platform.GitHub` | GitHub username |
| `Platform.X` | X (formerly Twitter) handle |

---

## GiftTarget struct (setup input)

| Field | Type | Purpose |
|-------|------|---------|
| `platform` | `Platform` | Which platform (GitHub / X) |
| `id` | `string` | Platform user id / handle (e.g. `"alice"`) |

Passed to `setup()` as `abi.encode(GiftTarget)`.

---

## GiftInfo struct (storage)

| Field | Type | Purpose |
|-------|------|---------|
| `state` | `State` | Current state (see enum table below). Packs with `platform` + `receiver` in one slot |
| `platform` | `Platform` | Platform recorded at setup |
| `receiver` | `address` | Bound receiver. Zero unless `state == Active` |
| `balance` | `uint256` | Accumulated quoteToken balance pending claim |
| `createdAt` | `uint256` | `setup()` timestamp. Bind-window timer starts here |
| `id` | `string` | Platform id stored raw (e.g. `"alice"`). Non-empty `id` doubles as the duplicate-setup guard |

### State enum

| Value | Description |
|-------|-------------|
| `State.Accumulating` | No receiver bound. Balance grows on each `afterDeposit` while the bind window is open |
| `State.Active` | Receiver bound. Balance continues to grow; receiver pulls funds with `claim(token)` |
| `State.Burned` | Bind window elapsed with no receiver; the next `afterDeposit` flipped this on. Terminal |

Transitions: `Accumulating → Active` (on `setReceiver`), `Accumulating → Burned` (on `afterDeposit` after window), `Active → Active` (on rotate). No path out of `Burned`.

---

## State

| Variable | Type | Set via | Purpose |
|----------|------|---------|---------|
| `creatorFeeProcessor` | `address` | initialize | Authorized caller for `afterDeposit` |
| `bondingCurve` | `address` | initialize | Authorized caller for `setup`; also used for pre-graduation buybacks |
| `tokenRegistry` | `ITokenRegistry` | initialize | Pair / adapter lookup + quoteToken lookup |
| `expiryDuration` | `uint256` | initialize / `setExpiryDuration` | Bind window length from `createdAt` |
| `router` | `address` | initialize | `NadFunRouter` used for pre-graduation buyback-burn |
| `wmon` | `address` | initialize | Wrapped-native singleton. When `claim`'s registered quote == `wmon`, the vault unwraps and forwards native MON. `address(0)` disables the unwrap branch (claims always do an ERC20 transfer) |
| `_gifts` | `mapping(address => GiftInfo)` | setup / afterDeposit / setReceiver / claim | Per-token gift record. Single source for state + receiver + balance |

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager_, creatorFeeProcessor_, bondingCurve_, tokenRegistry_, expiryDuration_, router_, wmon_, metadataURI_)` | initializer | UUPS initializer. `wmon_` enables native unwrap on `claim` when registered quote matches |
| `receive() external payable` | `msg.sender == wmon` only | Accepts native callback from `IWrappedNative.withdraw`. Reverts `UnexpectedNative` for any other sender |
| `setup(token, data)` | `bondingCurve` only | Register per-token `(platform, id)` and stamp `createdAt`. `data = abi.encode(GiftTarget)` |
| `afterDeposit(token, quoteToken, amount)` | `creatorFeeProcessor` only | State-dispatch: burn / accumulate / expire-and-burn |
| `setReceiver(token, receiver)` | **restricted** | Bind or rotate the claim receiver. Pointer-only update — accumulated balance persists and is inherited by the incoming receiver. Allowed while `state != Burned` |
| `claim(token)` | `msg.sender == gift.receiver`, `nonReentrant` | Withdraw the full accumulated balance to the bound receiver. Unwraps to native MON when registered quote == `wmon`. Repeatable |
| `setExpiryDuration(newDuration)` | restricted | Update the bind window length (applies to existing Accumulating tokens immediately) |
| `getGiftInfo(token)` | view | Return the `GiftInfo` record |
| `isExpired(token)` | view | `_expired[token]` |
| `getReceiver(token)` | view | Return `_receivers[token]` (0 = not bound) |
| `pendingQuote(token)` | view | Leftover quoteToken retained from pre-graduation buybacks that partially filled |

---

## Behavior

### `setup(token, data)`

```
bondingCurve -> GiftVault.setup(token, abi.encode(GiftTarget{platform, id}))
  |-- decode GiftTarget
  |-- require id non-empty (EmptyId)
  |-- require token not already set up (AlreadyConfigured)
  |-- _gifts[token] = { state: Accumulating, platform, receiver: 0, balance: 0, createdAt: now, id }
  +-- emit VaultSetup(token, platform, id)
```

After `setup()`, the token is **Accumulating**.

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
  |-- if gift.state == Active:                         # accumulate only
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

Active never transfers out of the vault — withdrawal is driven by `claim()`.

### `setReceiver(token, receiver)`

```
relayer -> GiftVault.setReceiver(token, receiver)
  |-- require receiver != 0 (ZeroReceiver)
  |-- gift = _gifts[token]
  |-- require gift.state != Burned (GiftExpiredError)
  |-- require setup() was called (NotConfigured)
  |-- gift.receiver = receiver
  |-- gift.state = Active                              # Accumulating → Active on first bind (no-op on rotate)
  +-- emit ReceiverSet(token, receiver)
```

First bind and rotate are treated identically: the receiver pointer swaps and `gift.balance` stays in the vault. **The current receiver always owns the full accumulated balance** — on rotate, that means the new receiver inherits everything and the previous receiver loses claim authority.

### `claim(token)`

```
receiver -> GiftVault.claim(token)
  |-- gift = _gifts[token]
  |-- require gift.state == Active (NotReceiver)
  |-- require msg.sender == gift.receiver (NotReceiver)
  |-- amount = gift.balance
  |-- require amount > 0 (ZeroBalance)
  |-- gift.balance = 0                                # CEI: state cleared before external call
  |-- quoteToken = tokenRegistry.getQuoteToken(token)
  |-- if wmon != 0 && quoteToken == wmon:
  |     IWrappedNative(wmon).withdraw(amount)         # unwrap WMON → native MON into vault
  |     (ok,) = receiver.call{value: amount}("")      # forward native to receiver
  |     require(ok, NativeTransferFailed)
  |-- else:
  |     IERC20(quoteToken).safeTransfer(receiver, amount)
  +-- emit Claim(token, receiver, amount)
```

No expiry on claim. Repeatable — after a claim, new `afterDeposit` calls grow the balance and the same receiver can claim again.

Defense in depth: `claim` carries `nonReentrant` (OZ `ReentrancyGuard`, ERC-7201 namespaced storage — proxy-safe) AND CEI is preserved (`gift.balance = 0` precedes the external call). Either guard alone is sufficient for the current shape, but both together harden against future cross-function paths that might share state with the WMON unwrap callback.

---

## `_buybackAndBurn(token, quoteToken, amount)`

```
_buybackAndBurn(token, quoteToken, amount)
  |-- if IToken(token).isGraduated():
  |     info    = tokenRegistry.getTokenInfo(token)
  |     adapter = tokenRegistry.getAdapter(info.dexType)
  |     safeTransfer(quoteToken → adapter, amount)
  |     tokenReceived = adapter.swap(pair, quoteToken, token, amount, this, "")
  |-- else (bonding phase):
  |     forceApprove(router, amount)
  |     tokenReceived = NadFunRouter.buy({ amountIn: amount, amountOutMin: 1 })
  |     # Unspent quote is tracked in _pendingQuote[token] and consumed on the next call.
  |-- if tokenReceived > 0:
  |     safeTransfer(token → 0xdead, tokenReceived)
  |     emit Burn(token, pair, spent, tokenReceived)
```

Same dual-path pattern as `BurnVault`. Pre-graduation routes through `NadFunRouter.buy` so clamped buys can partial-fill via `_pendingQuote`. Post-graduation uses the registered DEX adapter. Swap failures revert; `CreatorFeeProcessor`'s `try/catch` protects the overall `afterDeposit` pipeline.

---

## End-to-end flow

```
1. Token creation
   Creator -> BondingCurve.create(vaults: [{ vault: giftVault, setupData: abi.encode(GiftTarget{Platform.X, "alice"}) }])
   -> GiftVault.setup(token, data) -> _gifts[token] = { platform: Platform.X, id: "alice", createdAt: now }

2. Fees accrue (Accumulating or Active)
   Trades -> FeeCollector -> CreatorFeeProcessor -> GiftVault.afterDeposit(token, quote, amount)
   -> gift.balance += amount

3a. Happy path: relayer verifies id owner, binds receiver, receiver claims
    Off-chain: relayer verifies OAuth proof for @alice
    -> relayer.setReceiver(token, claimerWallet)          [Accumulating → Active, balance preserved]
    -> claimerWallet.claim(token)                          [receiver pulls full balance]
    -> future fees accumulate; claimerWallet can claim again at any time

3b. Rotation: receiver changes to a new wallet
    -> relayer.setReceiver(token, newClaimerWallet)
    -> pointer swaps. Accumulated balance persists in the vault and is inherited by newClaimerWallet
    -> future fees accumulate for the new receiver; newClaimerWallet claims

3c. Burn: bind window elapses and a deposit arrives before any setReceiver
    -> afterDeposit observes block.timestamp > createdAt + expiryDuration
    -> gift.balance + amount buyback-burned, _expired[token] = true (terminal)
    -> setReceiver reverts GiftExpiredError forever; every subsequent afterDeposit burns
```

Trust model: the relayer chooses who can claim; the relayer *cannot* pull funds itself (claim is gated on `msg.sender`). Admin bounds the relayer via `ProtocolManager.setOperatorPermission(relayer, giftVault, GiftVault.setReceiver.selector, false)`.

---

## Security

| Threat | Mitigation |
|--------|------------|
| Arbitrary receiver bound | `restricted` on `setReceiver` — only admin-granted operators can call |
| Relayer self-drain | `claim` is gated on `msg.sender == gift.receiver`; relayer has no direct withdrawal path |
| Platform-id forgery | Off-chain relayer verifies ownership via OAuth before binding |
| Relayer key compromise | Admin revokes via `ProtocolManager.setOperatorPermission(relayer, giftVault, setReceiver.selector, false)` |
| Bind / rotate after permanent burn | `gift.state == Burned` → `GiftExpiredError` |
| Relayer mis-rotate hands full balance to wrong receiver | Trust model: the relayer must verify id ownership before `setReceiver`. A rotate transfers both future and already-accumulated fees to the new receiver (previous loses access). Admin can revoke a compromised relayer via `setOperatorPermission` |
| Old receiver claims after rotate | `msg.sender != gift.receiver` → `NotReceiver` |
| Deposit to a burned token | `gift.state == Burned` check at the top of `afterDeposit` routes every subsequent deposit to `_buybackAndBurn` |
| Claim on non-Active state | `gift.state != Active` → `NotReceiver` (defense-in-depth; `receiver` is already zero in other states) |
| Bind without setup | `bytes(gift.id).length == 0` → `NotConfigured` |
| Zero receiver | `receiver != address(0)` → `ZeroReceiver` |
| Duplicate setup | `bytes(gift.id).length != 0` → `AlreadyConfigured` |
| Claim with zero balance | `balance > 0` check → `ZeroBalance` |
| Native unwrap fails (receiver reverts in `receive`) | `(bool ok,) = receiver.call{value}("")` → `NativeTransferFailed`. Whole claim reverts; `gift.balance` is restored by the revert, allowing rotation via `setReceiver` and retry |
| Stranded native (accidental funding, drained from elsewhere) | `receive()` accepts only `msg.sender == wmon` → `UnexpectedNative` for any other sender. Vault cannot accumulate native without going through the wmon→withdraw path |

---

## Events

| Event | Parameters |
|-------|------------|
| `VaultSetup` | `address indexed token, Platform platform, string id` |
| `Deposit` | `address indexed token, uint256 amount, uint256 newBalance` |
| `ReceiverSet` | `address indexed token, address indexed receiver` |
| `Claim` | `address indexed token, address indexed receiver, uint256 amount` |
| `Expire` | `address indexed token, uint256 amount` |
| `Burn` | `address indexed token, address indexed pair, uint256 quoteIn, uint256 tokenBurned` |
| `ExpiryUpdate` | `uint256 oldDuration, uint256 newDuration` |
