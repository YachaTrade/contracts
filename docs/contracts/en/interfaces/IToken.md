# IToken

**Path:** `src/interfaces/IToken.sol`
**Type:** Interface

Simple ERC20 token interface for NadFun v2. Deployed as an ERC-1167 clone by BondingCurve. No fee-on-transfer -- fee collection happens at the NadFunPair and BondingCurve level.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `initialize(name_, symbol_, tokenURI_, bondingCurve_, pair_)` | -- | Clone initializer. Called once by BondingCurve after deployment |
| `setIsGraduated()` | -- | Called by BondingCurve on graduation. Sets isGraduated flag |
| `isGraduated()` | `bool` | Whether this token has graduated from bonding curve to DEX |
| `bondingCurve()` | `address` | The BondingCurve contract that deployed this token |
| `pair()` | `address` | The NadFunPair address for this token |
| `tokenURI()` | `string` | Token metadata URI |
| `TOTAL_SUPPLY()` | `uint256` | Fixed total supply: 1 billion tokens (1e27 wei) |

---

## Errors

| Error | Description |
|-------|-------------|
| `AlreadyInitialized()` | Clone already initialized |
| `NotBondingCurve()` | Caller is not the bondingCurve address |
| `AlreadyGraduated()` | Token has already graduated |
| `TransferToPairBeforeGraduation()` | Transfer to pair address blocked before graduation |

---

## Known Implementations

| Implementation | Description |
|----------------|-------------|
| `Token` | Simple ERC20Upgradeable clone with no fee-on-transfer |
