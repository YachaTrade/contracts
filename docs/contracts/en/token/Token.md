# Token

**Path:** `src/token/Token.sol`
**Pattern:** EIP-1167 Clone
**Inheritance:** `ERC20Upgradeable`, `ERC20PermitUpgradeable`, `IToken`

Simple ERC-20 launch token with no fee-on-transfer behavior. Lifecycle and protocol fees are handled by BondingCurve, YachaRouter, and LPManager rather than token transfers.

Deployed as an ERC-1167 minimal proxy clone by `BondingCurve.create()`. Uses upgradeable ERC20 and ERC20Permit initializers because clones do not invoke constructors. The entire total supply (1 billion tokens) is minted to the BondingCurve on initialization. On graduation, only the `isGraduated` flag is set -- there is no multi-step state machine.

---

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `TOTAL_SUPPLY` | `1_000_000_000 ether` (1e27) | Fixed total supply minted on initialization |

---

## State Variables

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `bondingCurve` | `address` | public | BondingCurve contract that deployed this token |
| `pair` | `address` | public | Canonical V3 pool address for this token |
| `isGraduated` | `bool` | public | Whether this token has graduated to DEX |

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(name_, symbol_, tokenURI_, bondingCurve_, pair_)` | external (initializer) | Clone initializer. Inits ERC20, stores bondingCurve and pair, mints TOTAL_SUPPLY to bondingCurve |
| `tokenURI()` | view | Returns token metadata URI |
| `setIsGraduated()` | external (onlyBondingCurve) | Sets `isGraduated = true`. Reverts if caller is not bondingCurve or already graduated |

---

## Errors

| Error | Description |
|-------|-------------|
| `AlreadyInitialized()` | Clone already initialized (from IToken) |
| `NotBondingCurve()` | Caller is not the bondingCurve address |
| `AlreadyGraduated()` | Token has already graduated |
| `TransferToPairBeforeGraduation()` | Transfer to pair address blocked before graduation |

---

## Lifecycle

```
BondingCurve.create()
  -> Clones.clone(tokenImplementation)
  -> token.initialize(name, symbol, tokenURI, address(this), pair)
       |- __ERC20_init(name, symbol)
       |- __ERC20Permit_init(name)
       |- bondingCurve = address(this)
       |- pair = pair
       +- _mint(bondingCurve, 1_000_000_000 ether)

BondingCurve._graduate()
  -> token.setIsGraduated()
       |- require(msg.sender == bondingCurve)
       |- require(!isGraduated)
       +- isGraduated = true
```

## Transfer Guard

The `_update` override blocks transfers to the `pair` address before graduation. This prevents reserve corruption by ensuring tokens cannot be sent to the pair (e.g., via direct transfer) until after graduation when the pair has been seeded with liquidity.

- `_update(from, to, value)`: if `!isGraduated && to == pair` -> revert `TransferToPairBeforeGraduation`
