# IWrappedNative

**Path:** `src/interfaces/IWrappedNative.sol`
**Type:** Interface

Wrapped native token (WMON) 인터페이스.

---

## Function Signatures

| Function | Description |
|----------|-------------|
| `deposit()` | ETH → WMON (payable) |
| `withdraw(amount)` | WMON → ETH |
| `approve(spender, amount)` | ERC20 approve |
| `transfer(to, amount)` | ERC20 transfer |
| `transferFrom(from, to, amount)` | ERC20 transferFrom |
| `balanceOf(account)` | ERC20 잔액 조회 |
