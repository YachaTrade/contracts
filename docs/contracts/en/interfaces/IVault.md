# IVault

**Path:** `src/interfaces/IVault.sol`
**Type:** Interface

Minimal ERC-165-compatible vault interface for creator-fee distribution. The built-in vault implementations are singleton UUPS proxies (not clones). CreatorFeeProcessor transfers quoteToken and then calls `afterDeposit()`; per-token configuration is handled through `setup()`.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `setup(token, data)` | — | Per-token configuration. Called once per token to set up vault-specific state. May be a no-op for vaults that need no per-token config |
| `afterDeposit(token, quoteToken, amount)` | — | Called by CreatorFeeProcessor after transferring quoteToken to the vault |
| `metadataURI()` | `string memory` | Off-chain metadata URI describing this vault implementation (name, icon, docs link). Vault-level value, set once during `initialize()`, not per-token |
| `supportsInterface(interfaceId)` | `bool` | ERC-165 support query inherited from IERC165 |

---

IVault declares no common events. Each implementation defines its own operational events.

---

## Known Implementations

| Implementation | VaultType | Description |
|----------------|-----------|-------------|
| `BurnVault` | Burn | Buyback and burn: swap quoteToken to token via TokenRegistry adapter, send to 0xdead |
| `LPVault` | LP | Swap half quoteToken to token, add liquidity, burn LP |
| `CreatorFeeVault` | Creator | Accumulate quoteToken for the configured per-token creator to claim |
| `GiftVault` | Gift | Platform-id (GitHub/X) based claim-model gift vault. 3 states: Accumulating → Active (via `restricted setReceiver`) or → Burned (if bind window elapses with no receiver). Active receiver pulls funds via `claim(token)`, repeatable. Rotation sweeps pending balance to the previous receiver |
| `DividendVault` | Dividend | Split deposits by configured ratios, convert pending quote slices through authorized routes, and distribute finalized balances through cumulative Merkle claims |
