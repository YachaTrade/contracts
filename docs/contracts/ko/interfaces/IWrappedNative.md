# IWrappedNative

**Path:** `src/interfaces/IWrappedNative.sol`
**Type:** Interface

Wrapped native token (WNATIVE) 인터페이스.

---

## Function Signatures

| Function | Description |
|----------|-------------|
| `deposit()` | ETH → WNATIVE (payable) |
| `withdraw(amount)` | WNATIVE → ETH |
| `approve(spender, amount)` | ERC20 approve |
| `transfer(to, amount)` | ERC20 transfer |
| `transferFrom(from, to, amount)` | ERC20 transferFrom |
| `balanceOf(account)` | ERC20 잔액 조회 |
