# IVault

**Path:** `src/interfaces/IVault.sol`
**Type:** Interface

Minimal vault interface for creator fee distribution. All vault implementations must implement this interface. Vaults are deployed as singletons (not clones). CreatorFeeProcessor transfers quoteToken then calls `afterDeposit()`. Per-token configuration is handled via `setup()`.

---

## Function Signatures

| Function | Returns | Description |
|----------|---------|-------------|
| `setup(token, data)` | — | Per-token configuration. Called once per token to set up vault-specific state. May be a no-op for vaults that need no per-token config |
| `afterDeposit(token, quoteToken, amount)` | — | Called by CreatorFeeProcessor after transferring quoteToken to the vault |
| `metadataURI()` | `string memory` | Off-chain metadata URI describing this vault implementation (name, icon, docs link). Vault-level value, set once during `initialize()`, not per-token |

---

## Events

| Event | Parameters | Description |
|-------|------------|-------------|
| `VaultExecuted` | `address indexed token, address indexed vault, uint256 amountIn, uint256 amountProcessed` | Emitted by all vaults after processing a deposit |

---

## Known Implementations

| Implementation | VaultType | Description |
|----------------|-----------|-------------|
| `BurnVault` | Burn | Buyback and burn: swap quoteToken to token via TokenRegistry adapter, send to 0xdead |
| `LPVault` | LP | Swap half quoteToken to token, add liquidity, burn LP |
| `CreatorFeeVault` | Transfer | Direct transfer to a per-token recipient configured via setup() |
| `GiftVault` | Gift | Platform-id (GitHub/X) based claim-model gift vault. 3 states: Accumulating → Active (via `restricted setReceiver`) or → Burned (if bind window elapses with no receiver). Active receiver pulls funds via `claim(token)`, repeatable. Rotation sweeps pending balance to the previous receiver |
