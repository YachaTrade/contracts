# GIWA Launchpad Contracts

Bonding-curve token launchpad that creates canonical Uniswap V3 pools, graduates into permanent protocol-owned V3 liquidity, and routes post-graduation trades through the registered pool. Built for Monad with Solidity 0.8.24, Foundry, UUPS proxies, and EIP-1167 token clones.

## Architecture

The default deployment is V3-only and registers `CreatorFeeVault` as the only vault.

```text
Creator / Trader
      │
      ▼
 GiwaRouter ───────────────► V3SwapAdapter ─────────► canonical V3 pool
      │                              ▲
      ▼                              │
 BondingCurve ─► V3PoolDeployer      │
      │              │               │
      │              └─ create and initialize pool
      │
      └─ graduation ─► LPManager ─► V3LiquidityActor
                           │              │
                           │              └─ permanent V3 positions
                           │
                           └─ collected LP fees
                                ├─ protocol share ─► feeReceiver
                                └─ creator share ─► CreatorFeeProcessor
                                                        │
                                                        └─ CreatorFeeVault
```

Deployment-relevant source surface:

```text
src/
├── core/         BondingCurve, ProtocolManager, LPManager, TokenRegistry,
│                 V3PoolDeployer, CreatorFeeProcessor
├── router/       GiwaRouter
├── actors/       V3LiquidityActor
├── adapters/     V3SwapAdapter
├── token/        Token
├── vault/        VaultRegistry, CreatorFeeVault
├── integration/  TokenInfoLens
├── interfaces/
└── libraries/    BondingCurveLibrary, Constants, Math, TransferHelper
```

### Token Lifecycle

1. **Create** — A creator calls `GiwaRouter.create()`. `BondingCurve` deploys a deterministic `Token` clone, `V3PoolDeployer` creates and initializes the canonical pool at the configured graduation-target price, and `TokenRegistry` records the pool, quote token, and fee tier. The fixed `deployFee` goes directly to `ProtocolManager.feeReceiver()`.
2. **Trade on the curve** — Before graduation, `GiwaRouter` routes buys and sells through `BondingCurve`. The curve charges the quote token's `curveProtocolFeeRate`; configured anti-sniping penalties apply only to ordinary buys, not the creation-time initial buy or sells. There is no creator trading fee. Native calls are available only when the token's quote token matches the router's wrapped-native token.
3. **Graduate** — When the virtual token reserve reaches `minTokenReserve`, `BondingCurve` deducts `graduateFee`, transfers the tracked token and quote liquidity to `LPManager`, and calls `allocate()`. `V3LiquidityActor` mints two permanent V3 positions using the contract-v3 range math. Unused graduation assets go to `feeReceiver`.
4. **Trade on V3** — After graduation, `GiwaRouter` routes exact-input and exact-output swaps through `V3SwapAdapter` and the canonical registered pool. The router charges `dexProtocolFeeRate` on the quote side and sends it directly to the current `feeReceiver`; the pool fee tier is applied by Uniswap V3.
5. **Operate permanent liquidity** — The `ProtocolManager` owner or a selector-authorized operator may add assets to both existing positions through `LPManager.increaseLiquidity()` without exposing a withdrawal path.
6. **Collect LP fees** — An authorized collector calls `LPManager.collect(tokens)`. Each pool's token-side fee is swapped through the same canonical V3 pool into its quote token, combined with the directly collected quote fee, and split using that quote token's `lpFeeProtocolShareBps`.

## Contracts

### Protocol Core

| Contract | Pattern | Responsibility |
|----------|---------|----------------|
| `ProtocolManager` | UUPS Proxy | Ownable authority for `feeReceiver`, per-quote curve parameters, V3 fee tier, LP-fee protocol share, anti-sniping table, and selector-scoped operator permissions. |
| `BondingCurve` | UUPS Proxy | Token creation, curve trading, reserve accounting, anti-sniping, and V3 graduation orchestration. |
| `TokenRegistry` | UUPS Proxy | Source of truth for each launch token's canonical pool, quote token, DEX type, and V3 fee tier. |
| `V3PoolDeployer` | UUPS Proxy | Creates or validates the canonical factory pool and initializes it at the configured graduation-target price. |
| `LPManager` | UUPS Proxy | Allocates and increases permanent liquidity, records pool metadata, collects V3 fees, swaps token fees to quote, and distributes the quote proceeds. |
| `CreatorFeeProcessor` | Immutable Singleton | Pulls the creator share from a caller authorized by `ProtocolManager.canCall()` and distributes it across the token's configured vault slots by BPS. |
| `GiwaRouter` | UUPS Proxy | User entry point for creation, curve trades, V3 trades, quotes, permits, native wrapping, and refunds. |

### V3 Execution

| Contract | Pattern | Responsibility |
|----------|---------|----------------|
| `V3LiquidityActor` | Immutable Singleton | Owns the two permanent positions per launch pool, authenticates mint callbacks, and transfers collected fees to `LPManager`. |
| `V3SwapAdapter` | Immutable Singleton | Executes direct swaps against the canonical registry-backed pool and authenticates every swap callback. |
| `Token` | EIP-1167 Clone | Plain ERC-20 with ERC-2612 permit. It has no transfer tax or public burn function. |
| `TokenInfoLens` | Immutable Integration | Exposes launch-token version and quote-token metadata for SDKs and indexers. |

### Vaults

| Contract | Pattern | Responsibility |
|----------|---------|----------------|
| `VaultRegistry` | UUPS Proxy | Registers active vault implementations after authority and ERC-165 validation. |
| `CreatorFeeVault` | UUPS Proxy | Accumulates quote token per launch token for its registered creator. Wrapped-native quote claims are unwrapped before transfer. |

`script/deploy/normal/Deploy.s.sol` deploys and registers only `CreatorFeeVault`. `CreatorFeeProcessor` still supports up to five vault slots whose BPS values sum to 10,000, allowing future vault types to be added through an explicit deployment change.

## Fees

There is no creator fee on token creation, bonding-curve trades, or post-graduation router trades. Creator revenue comes from the configured share of collected V3 LP fees.

| Stage | Configuration | Recipient |
|-------|---------------|-----------|
| Token creation | `deployFee` per quote token | `feeReceiver` |
| Bonding-curve trade | `curveProtocolFeeRate`; ordinary buys may also pay an anti-sniping penalty | `feeReceiver` |
| Graduation | `graduateFee` per quote token | `feeReceiver` |
| Post-graduation V3 trade | `dexProtocolFeeRate` on the quote side | `feeReceiver` |
| V3 pool execution | `v3FeeTier` | Accrues to the permanent V3 positions |
| LP-fee collection | `lpFeeProtocolShareBps` | Protocol share to `feeReceiver`; remainder to `CreatorFeeProcessor` |

The main deployment initializes the wrapped-native quote token with `dexProtocolFeeRate = 0`. A nonzero post-graduation router fee must be configured later through `updateV3QuoteToken()` or `UpdateQuoteToken.s.sol`.

### LP Fee Collection

```text
authorized collector
  └─ LPManager.collect([tokenA, tokenB, ...])
       └─ for each token
            ├─ validate stored pool against TokenRegistry and V3 factory
            ├─ V3LiquidityActor.collectFees(pool)
            │    ├─ launch-token fee
            │    └─ direct quote-token fee
            ├─ V3SwapAdapter.exactInput(launch-token fee → quote token)
            ├─ total quote = direct quote fee + swapped quote
            ├─ protocol quote = total quote × lpFeeProtocolShareBps / 10,000
            │    └─ transfer to ProtocolManager.feeReceiver()
            └─ creator quote = total quote - protocol quote
                 └─ CreatorFeeProcessor.processCreatorFee()
                      └─ CreatorFeeVault.afterDeposit()
                           └─ creator claims the quote asset
```

Collection is atomic across the submitted batch. Duplicate tokens, mismatched pool metadata, partial token-fee swaps, taxed transfers, failed vault callbacks, or incorrect balance deltas revert the transaction. Entry balances and pre-existing donations are preserved, and temporary allowances are cleared.

### Multiple Quote Tokens

`ProtocolManager` stores an independent `QuoteConfig` for every supported quote token:

- decimals
- virtual quote and token reserves
- minimum token reserve
- deploy and graduation fees
- curve and post-graduation protocol fee rates
- canonical V3 fee tier
- LP-fee protocol share in BPS
- active status

Use `addV3QuoteToken()` or `updateV3QuoteToken()` for atomic curve and V3 configuration. The scripts `AddQuoteToken.s.sol` and `UpdateQuoteToken.s.sol` expose the same configuration flow for operations. A multi-token `LPManager.collect()` batch resolves and distributes each token in its own registered quote asset.

## Permissions

`ProtocolManager` is the Ownable configuration and selector-scoped authority contract. After deployment, the multisig owns `ProtocolManager` and is therefore implicitly allowed by `canCall()`; other callers need an explicit selector permission. The default deployment grants only the required operator edges:

- `BondingCurve` may create V3 pools, register V3 metadata, allocate graduation liquidity, and configure the token's processor vault slots.
- `LPManager` may call `CreatorFeeProcessor.processCreatorFee()`.
- `COLLECTOR` may call `LPManager.collect()`; it defaults to the multisig when not configured separately.
- An optional `CREATOR_MANAGER` may update a token's creator in `CreatorFeeVault`.
- `GiwaRouter` receives `BondingCurve.ROUTER_ROLE`; the multisig owns `ProtocolManager` and the BondingCurve admin and guardian roles after deployment.

The multisig may also call restricted operations directly, including `LPManager.increaseLiquidity()` and `CreatorFeeProcessor.processCreatorFee()`.

### Administrative Operations

- Rotate the protocol recipient with `ProtocolManager.setFeeReceiver()`.
- Add or atomically update per-quote curve and V3 configuration with `addV3QuoteToken()` and `updateV3QuoteToken()`; deactivate a quote token with `removeQuoteToken()`.
- Change only the V3 fee tier and LP-fee protocol share with `setV3QuoteConfig()`.
- Replace the per-block anti-sniping schedule with `setSnipingPenaltyTable()` or `SetSnipingConfig.s.sol`.
- Grant or revoke an operator's exact target and selector with `setOperatorPermission()`.
- Pause or resume curve creation and trading with guardian-controlled `BondingCurve.halt()`.

## Development

```shell
# Format
forge fmt
forge fmt --check

# Build and full test suite
forge build
forge test

# Focused lifecycle and LP-fee tests
forge test --match-path test/integration/WethV3GraduationE2E.t.sol -vvv
forge test --match-path test/integration/WethV3LpFeeCollectionE2E.t.sol -vvv
forge test --match-path test/modules/LPManagerCollect.t.sol -vvv
forge test --match-path test/invariant/LPPrincipalLock.invariant.t.sol -vvv

# Environment-gated fork coverage
RUN_FORK_TESTS=true forge test --match-path test/fork/GiwaRouterNativeQuoteFork.t.sol -vvv
```

### Test Layout

| Area | Paths | Coverage |
|------|-------|----------|
| Core | `test/core/` | Curve math, creation, fees, graduation, permissions, registry, and pool deployment |
| Router | `test/router/`, `test/core/GiwaRouter*.t.sol` | Curve/V3 routing, native quote handling, permits, refunds, and slippage |
| V3 liquidity | `test/modules/LPManagerV3.t.sol`, `test/modules/V3LiquidityActor.t.sol` | Contract-v3 tick math, two-position allocation, callback validation, and principal custody |
| LP fees | `test/modules/LPManagerCollect.t.sol` | Token-to-quote conversion, per-quote split, batch atomicity, donation isolation, and access control |
| Integration | `test/integration/` | Real V3 graduation, full-balance post-graduation sells, LP-fee collection, and deployment wiring |
| Invariant | `test/invariant/` | Permanent LP principal and liquidity-accounting invariants |
| Fork | `test/fork/` | Deployed wrapped-native and quote integration when enabled |

## Deployment

The V3 factory is deployed separately, then passed to the protocol deployment.

```shell
# 1. Deploy the canonical V3 factory
forge script script/deploy/normal/DeployV3Factory.s.sol \
  --rpc-url "$RPC_URL" --broadcast

# 2. Deploy and wire the protocol
forge script script/deploy/normal/Deploy.s.sol \
  --rpc-url "$RPC_URL" --broadcast
```

The main deployment reuses the chain's canonical wrapped-native token, deploys the V3-only launch stack, registers only `CreatorFeeVault`, applies selector permissions, and transfers final administration to `MULTISIG`. Operational values are supplied through the local environment; never commit private keys or environment files.

## Security Properties

- **Canonical pool validation** — Pool address, factory, token ordering, fee tier, and reverse registry mapping are checked before V3 execution.
- **Authenticated callbacks** — Mint and swap callbacks are bound to one active operation and reject forged, replayed, missing, or malformed callbacks.
- **Permanent LP principal** — `V3LiquidityActor` owns the graduation positions, and fee collection does not expose a principal-withdrawal path.
- **Balance-delta accounting** — Curve transfers, LP collection, swaps, processor distribution, and vault deposits require exact balance changes and reject taxed or rebasing behavior.
- **Donation isolation** — Pre-existing balances are excluded from curve reserves, LP-fee proceeds, router refunds, and processor distributions.
- **Atomic fee distribution** — A failed swap, transfer, or vault callback reverts the full collection batch.
- **Selector-scoped authority** — Administrative and operational calls are restricted through BondingCurve roles or `ProtocolManager.canCall()`.
- **Native-token guards** — Native value is accepted only on the configured wrapped-native paths and excess call-scoped value is refunded without sweeping existing balances.

API references: [GiwaRouter](docs/contracts/en/router/GiwaRouter.md), [IGiwaRouter](docs/contracts/en/interfaces/IGiwaRouter.md), [LPManager](docs/contracts/en/core/LPManager.md), [ProtocolManager](docs/contracts/en/core/ProtocolManager.md), and [V3SwapAdapter](docs/contracts/en/adapters/V3SwapAdapter.md).
