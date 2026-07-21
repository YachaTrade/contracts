# CreatorFeeVault

**Path:** `src/vault/CreatorFeeVault.sol`
**Pattern:** UUPS Proxy
**Inheritance:** `IVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

Claim-model creator-fee vault. Singleton shared across all tokens. Each token registers a per-token `creator` at `setup()`; quoteToken accumulates per token via `afterDeposit`; the registered creator pulls funds with `claim(token)`. Used when token creators want creator-fee revenue routed to a specific wallet they control.

---

## State

| Variable | Type | Set via | Purpose |
|----------|------|---------|---------|
| `bondingCurve` | `address` | initialize | Authorized caller for `setup` |
| `creatorFeeProcessor` | `address` | initialize | Authorized caller for `afterDeposit` |
| `tokenRegistry` | `ITokenRegistry` | initialize | Looks up `quoteToken` for a given token at claim time |
| `metadataURI` | `string` | initialize | Off-chain metadata pointer (`IVault`) |
| `wmon` | `address` | initialize | Wrapped-native singleton. When `claim`'s registered quote == `wmon`, the vault unwraps and forwards native MON. `address(0)` disables the unwrap branch (claims always do an ERC20 transfer) |
| `_creators` | `mapping(address => address)` | setup / setCreator | Per-token creator pointer; `claim` is gated on `msg.sender == _creators[token]` |
| `_balances` | `mapping(address => uint256)` | afterDeposit / claim | Per-token accumulated quoteToken pending claim |

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager_, bondingCurve_, creatorFeeProcessor_, tokenRegistry_, wmon_, metadataURI_)` | initializer | UUPS initializer. `wmon_` enables native unwrap on `claim` when registered quote matches |
| `setup(token, data)` | `bondingCurve` only | Register the per-token creator. `data = abi.encode(creator)` |
| `afterDeposit(token, _, amount)` | `creatorFeeProcessor` only | Add `amount` to `_balances[token]` if a creator is configured |
| `claim(token)` | `msg.sender == _creators[token]`, `nonReentrant` | Withdraw the full accumulated balance. Unwraps to native MON when registered quote == `wmon` |
| `setCreator(token, newCreator)` | **restricted** | Rotate the per-token creator. Past balance follows the new creator (claim authority transfers) |
| `getCreator(token)` | view | Return `_creators[token]` (0 = not configured) |
| `getBalance(token)` | view | Return `_balances[token]` |
| `receive() external payable` | `msg.sender == wmon` only | Accepts native callback from `IWrappedNative.withdraw`. Reverts `UnexpectedNative` for any other sender |

---

## Behavior

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
  |-- if _creators[token] == 0: return                # silently skip unconfigured tokens
  |-- _balances[token] += amount
  +-- emit Deposit(token, amount, _balances[token])
```

The `quoteToken` argument is part of the `IVault.afterDeposit` signature but unused — `claim` resolves the live quote via `tokenRegistry`.

### `claim(token)`

```
creator -> CreatorFeeVault.claim(token)
  |-- creator = _creators[token]
  |-- require msg.sender == creator (NotAuthorized)
  |-- amount = _balances[token]
  |-- require amount > 0 (ZeroBalance)
  |-- _balances[token] = 0                            # CEI: state cleared before external call
  |-- quoteToken = tokenRegistry.getQuoteToken(token)
  |-- if wmon != 0 && quoteToken == wmon:
  |     IWrappedNative(wmon).withdraw(amount)         # unwrap WMON → native MON into vault
  |     (ok,) = creator.call{value: amount}("")       # forward native to creator
  |     require(ok, NativeTransferFailed)
  |-- else:
  |     IERC20(quoteToken).safeTransfer(creator, amount)
  +-- emit Claim(token, creator, amount)
```

Defense in depth: `claim` carries `nonReentrant` (OZ `ReentrancyGuard`, ERC-7201 namespaced storage — proxy-safe) AND CEI is preserved (`_balances[token] = 0` precedes the external call). Either guard alone is sufficient for the current shape, but both together harden against future cross-function paths that might share state with the WMON unwrap callback.

### `setCreator(token, newCreator)`

```
admin / operator -> CreatorFeeVault.setCreator(token, newCreator)
  |-- restricted (admin or operator with permission for setCreator selector)
  |-- require newCreator != 0 (ZeroCreator)
  |-- old = _creators[token]
  |-- require old != 0 (NotConfigured)
  |-- _creators[token] = newCreator
  +-- emit CreatorUpdate(token, old, newCreator)
```

Pointer-only update. Any accumulated `_balances[token]` is inherited by the new creator — the previous creator immediately loses claim authority. Used for creator-handoff or custodial recovery.

---

## End-to-end flow

```
1. Token creation
   Creator -> BondingCurve.create(vaults: [{ vault: creatorFeeVault, setupData: abi.encode(creator) }])
   -> CreatorFeeVault.setup(token, data) -> _creators[token] = creator

2. Fees accrue
   Trades -> FeeCollector -> CreatorFeeProcessor -> CreatorFeeVault.afterDeposit(token, quote, amount)
   -> _balances[token] += amount

3. Creator pulls funds
   creator.claim(token)
   -> if registered quote == wmon: unwrap and send native MON
   -> else: ERC20 safeTransfer
   -> _balances[token] = 0

4. (Optional) Rotate creator
   admin/operator.setCreator(token, newCreator)
   -> claim authority + accumulated balance follow the new pointer
```

---

## Security

| Threat | Mitigation |
|--------|------------|
| Arbitrary caller invokes `setup` | `msg.sender == bondingCurve` (NotAuthorized) |
| Arbitrary caller invokes `afterDeposit` | `msg.sender == creatorFeeProcessor` (NotAuthorized) |
| Arbitrary caller claims someone else's balance | `msg.sender == _creators[token]` (NotAuthorized) |
| Duplicate `setup` for the same token | `_creators[token] != 0` → `AlreadyConfigured` |
| Zero creator at setup or rotate | `creator != 0` → `ZeroCreator` |
| Rotate before setup | `_creators[token] != 0` → `NotConfigured` |
| Claim with no balance | `_balances[token] > 0` → `ZeroBalance` |
| Reentrancy via native callback | `nonReentrant` on `claim` (OZ `ReentrancyGuard`, ERC-7201 namespaced storage — proxy-safe) plus CEI (`_balances[token] = 0` before the external call). Reentrant `claim` is rejected by the guard before re-execution |
| Native unwrap fails (creator reverts in `receive`) | `(bool ok,) = creator.call{value}("")` → `NativeTransferFailed`. Whole claim reverts; `_balances[token]` is restored by the revert. Use `setCreator` to rotate to a workable address and retry |
| Stranded native (accidental funding, drained from elsewhere) | `receive()` accepts only `msg.sender == wmon` → `UnexpectedNative` for any other sender |
| Rotation hijack | `setCreator` is `restricted` — only admin (PM owner) or operators granted `setCreator` selector permission |

---

## Events

| Event | Parameters |
|-------|------------|
| `VaultSetup` | `address indexed token, address creator` |
| `Deposit` | `address indexed token, uint256 amount, uint256 newBalance` |
| `Claim` | `address indexed token, address indexed creator, uint256 amount` |
| `CreatorUpdate` | `address indexed token, address indexed oldCreator, address indexed newCreator` |
