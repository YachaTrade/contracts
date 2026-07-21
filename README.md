# GIWA Launchpad Contracts

Bonding curve token launchpad with canonical Uniswap V3 routing for registered graduated tokens. Built for Monad.

> **Integration status:** `GiwaRouter` and `V3SwapAdapter` provide the current user-facing V3 trading path. The retained `Deploy.s.sol` creation/graduation wiring still registers the legacy NadFun V2 path; it does not yet configure an end-to-end V3 lifecycle. A newly created token can trade on the bonding curve through `GiwaRouter`, but its graduated V2 metadata is intentionally rejected by the router's V3 path until deployment wiring is migrated.

## Architecture

```
src/
├── core/       BondingCurve, ProtocolManager, LPManager, TokenRegistry, V3PoolDeployer, FeeCollector, Treasury (UUPS); CreatorFeeProcessor (singleton)
├── router/     GiwaRouter (UUPS)
├── token/      Token (EIP-1167 clone)
├── dex/        NadFunFactory (singleton), NadFunPair (per-pair)
├── vault/      VaultRegistry, DividendVault, BurnVault, LPVault, CreatorFeeVault (singleton UUPS proxies)
├── adapters/   V3SwapAdapter, NadSwapAdapter, UniswapV2ExternalAdapter, UniswapV3ExternalAdapter
├── interfaces/
└── libraries/  BondingCurveLibrary, NadFunLibrary, Math, UQ112x112, Constants
```

### Token Lifecycle

1. **Create** — Creator calls `GiwaRouter.create()` with `VaultAllocation[]`. The current BondingCurve deployment path deploys a Token clone (plain ERC20 + Permit), creates a legacy NadFunPair via NadFunFactory, registers fee metadata, configures singleton vaults, and charges `deployFee`.
2. **Trade (Bonding Curve)** — Before graduation, users buy/sell through `GiwaRouter`. Prices and curve protocol/creator fees are computed by BondingCurve. ERC-20 quotes and wrapped-native quotes are supported; native calls require the token's quote token to equal the router's configured wrapped-native token.
3. **Graduate** — When the curve's funding target is reached, `BondingCurve._graduate()` transfers token/quote liquidity to LPManager, which adds liquidity through the configured DEX adapter and keeps the graduation LP in protocol custody. `graduateFee` is deducted.
4. **Trade (DEX)** — For tokens registered as `DexType.UniswapV3`, `GiwaRouter` routes exact-input and exact-output buys/sells through the canonical pool using `V3SwapAdapter`. The router applies `dexProtocolFeeRate` on the quote-token side; the pool's own LP fee remains embedded in Uniswap V3 execution. Legacy V2 metadata is not accepted by this path.
5. **Fee Settlement** — FeeCollector forwards the declared protocol fee plus excess immediately on each collection and accumulates only creator fees per pair. When accumulated creator fees reach the threshold, authorized `settle(pair, minAmountOut)` forwards them to CreatorFeeProcessor for singleton vault distribution by BPS.

## Contracts

### Core (`src/core/`)

| Contract | Upgradeability | Description |
|----------|---------------|-------------|
| `BondingCurve` | UUPS Proxy | Token factory + bonding curve trading engine |
| `ProtocolManager` | UUPS Proxy | Unified protocol config: fees, creator fee settings, quote token registry |
| `LPManager` | UUPS Proxy | DEX liquidity provisioning via IDexAdapter; graduation LP is permanent protocol launch liquidity |
| `TokenRegistry` | UUPS Proxy | Token metadata registry (pool/pair, quoteToken, DEX type) |
| `V3PoolDeployer` | UUPS Proxy | Canonical Uniswap V3 pool creation/reuse, validation, initialization, and observation-cardinality setup |
| `GiwaRouter` | UUPS Proxy | User entry point for creation, curve trades, canonical V3 exact-input/exact-output trades, quoting, permits, and native wrapping/refunds |
| `Treasury` | UUPS Proxy | Protocol treasury component used by V3 lifecycle infrastructure |
| `FeeCollector` | UUPS Proxy | Central fee management. `collectFee(pair, protocolFee, creatorFee)` validates the received balance delta, forwards protocol fee plus excess immediately, and accumulates creator fee only. `settle(pair, minAmountOut)` works in both bonding and legacy post-graduation phases. |
| `CreatorFeeProcessor` | Singleton | Receives quoteToken from FeeCollector, distributes to composable singleton vaults by BPS. |

### Legacy V2 DEX (`src/dex/`)

| Contract | Pattern | Description |
|----------|---------|-------------|
| `NadFunFactory` | Singleton | Uniswap V2 fork factory. CREATE2 pair deployment. |
| `NadFunPair` | Per-pair | Uniswap V2 fork pair with fee deduction in `swap()`. Sends fees to FeeCollector. |

### V3 routing (`src/router/`, `src/adapters/`)

| Contract | Pattern | Description |
|----------|---------|-------------|
| `GiwaRouter` | UUPS Proxy | Resolves registered pool metadata, computes router protocol fees, and owns user slippage/refund handling. |
| `V3SwapAdapter` | Singleton | Executes direct canonical V3 pool swaps and pays the callback only for the active, registry-backed pool context. |

### Token (`src/token/`)

| Contract | Pattern | Description |
|----------|---------|-------------|
| `Token` | EIP-1167 Clone | Plain ERC20 + Burnable + ERC20Permit. No fee-on-transfer. |

### Vault (`src/vault/`)

| Contract | Pattern | Description |
|----------|---------|-------------|
| `VaultRegistry` | UUPS Proxy | Authority-restricted vault registry with ERC-165 interface validation |
| `BurnVault` | Singleton UUPS Proxy | Buyback and burn via phase-aware routing |
| `LPVault` | Singleton UUPS Proxy | Swap half + addLiquidity + burn LP through the configured adapter |
| `CreatorFeeVault` | Singleton UUPS Proxy | Accumulates quoteToken per token; the configured creator later claims ERC-20 or, for configured WMON quotes, native MON |
| `DividendVault` | UUPS Proxy | Multi-token dividend distribution: converts creator fees into 1–10 dividend tokens by ratio, global Merkle root → holder claim |

## Fee System

### Fee Structure

| Phase | Creator fee (creator-set) | Protocol Fee | LP Fee | User Total |
|-------|-------------------|-------------|--------|-----------|
| Bonding Curve | 1%/3%/5% (from quote) | 1% (from quote) | - | 2%/4%/6% |
| Legacy DEX (NadFunPair) | 1%/3%/5% (from quote) | configurable (from quote) | 0.25% | Sum |
| Canonical V3 through GiwaRouter | - | `dexProtocolFeeRate` (quote side) | pool fee tier | Router fee + pool execution |

- **Creator fee rates** are restricted to an allowlist: 1%, 3%, 5% (configurable by admin via `ProtocolManager`)
- **Bonding curve**: protocol fee + creator fee deducted from quote token in `BondingCurve.buy()/sell()`
- **DEX**: LP fee (0.25%) stays in reserves, protocol fee + creator fee sent to FeeCollector in `NadFunPair.swap()`
- **Canonical V3 router path**: `GiwaRouter` reads `dexProtocolFeeRate` for the token's quote token at execution time and transfers that fee directly to the current `feeReceiver`; direct calls to `V3SwapAdapter` do not add the router fee
- **Creator fee is permanent** — no expiration (unlike v1's TaxToken which had creatorFeeExpirationTime)

### Fee Settlement (FeeCollector → CreatorFeeProcessor → Vaults)

```
NadFunPair.swap() / BondingCurve.buy()/sell()
     │
     └── Fee (quoteToken) → FeeCollector.collectFee(pair, protocolFee, creatorFee)
              │
              └── When accumulated >= threshold:
                   authorized settler calls FeeCollector.settle(pair, minAmountOut)
                    └── Creator fee → CreatorFeeProcessor.processCreatorFee()
                         └── Distribute to singleton vaults by BPS:
                              ├── BurnVault: swap quoteToken → token → 0xdead
                              ├── LPVault: swap half + addLiquidity + burn LP
                              ├── CreatorFeeVault: accumulate per token → creator claim (ERC-20 or WMON → native)
                              └── DividendVault: convert to 1–10 dividend tokens → Merkle claim
```

## Key Design Decisions

- **Plain ERC20 Token** over fee-on-transfer TaxToken: simpler, no creator fee reentrancy issues, composable with any DEX/protocol
- **Custom NadFunPair** over external Uniswap V2: pair-level fee deduction gives protocol full control, no need for fee-on-transfer token
- **FeeCollector** as central fee hub: single point for fee config, accumulation, and settlement. Both NadFunPair and BondingCurve send fees here.
- **Simplified CreatorFeeProcessor**: no longer swaps baseToken → quoteToken. Receives quoteToken directly from FeeCollector. Just distributes to vaults.
- **Unified ProtocolManager** over separate FeeManager/AdminModule/QuoteManager: single deployment, fewer cross-contract calls, and a single authority for global config plus operator permissions
- **LPManager + IDexAdapter liquidity path** over router: keeps graduation liquidity provisioning isolated and adapter-driven
- **Canonical V3 validation**: `V3SwapAdapter` derives the pool from the configured factory and registered fee tier, binds a single active callback context, validates deltas, and clears context before paying the pool
- **Permanent graduation LP**: LPManager does not expose a liquidity removal path; graduation LP is intended to remain protocol launch liquidity
- **Singleton CreatorFeeProcessor + Singleton Vaults** over per-token clones: CreatorFeeProcessor keeps common immutable constructor state; vaults are shared UUPS proxies initialized once. Per-token config lives in `setup()` / mappings, reducing deployment cost per token.
- **Composable Vault System** over monolithic CreatorFeeProcessor: vault logic (burn, LP, creator claims) is separated into independent, pluggable contracts. CreatorFeeProcessor just distributes.
- **VaultRegistry (authority-restricted + ERC-165)**: the ProtocolManager owner or selector-authorized operators register/deactivate vaults; registration validates the IVault interface.

## Development

```shell
# Build
forge build

# Test
forge test

# Test with verbosity
forge test -vvv

# Test specific file
forge test --match-path test/fee/FeeCollector.t.sol

# Test specific function
forge test --match-test test_settle_splitsCorrectly

# Gas snapshots
forge snapshot

# Deploy (currently retains legacy V2 creation/graduation wiring)
forge script script/deploy/normal/Deploy.s.sol --rpc-url <rpc_url> --broadcast
```

### Project Setup

- Solidity 0.8.24, EVM target: london
- Framework: Foundry
- Dependencies: OpenZeppelin (contracts + upgradeable), Solady

### Test Structure

```
test/
├── SetUp.t.sol         # Shared base: full protocol stack deployment + helpers
├── core/               # BondingCurve, Fee, Graduation, Router, ProtocolManager
│   ├── BondingCurveAttack.t.sol   # Attack vectors (direct buy, flash loan, reentrancy, post-grad)
│   ├── BondingCurveV2.t.sol       # v2-specific: Token + NadFunFactory + creator fee to FeeCollector
│   └── QuoteReserveAttack.t.sol   # Cross-curve reserve theft
├── dex/                # NadFunFactory, NadFunPair, NadFunPairFee
├── fee/                # FeeCollector
├── integration/        # Full lifecycle E2E
├── router/             # GiwaRouter canonical V3 and native-quote routing
├── adapters/           # V3SwapAdapter plus retained V2/external adapters
├── fork/               # Deployed wrapped-native/Quoter integration (environment gated)
├── modules/            # LPManager
│   └── ModuleAttack.t.sol         # Attack vectors (double LP, extreme fees, creator fee rate allowlist)
├── token/              # CreatorFeeProcessor
├── vault/              # VaultRegistry, BurnVault, LPVault, CreatorFeeVault
│   └── VaultAttack.t.sol          # Attack vectors (deactivated vault, reverting vault)
├── mocks/              # MockERC20, MockWMON
└── utils/              # (empty — NadFunFactory replaces UniswapV2Deployer)
```

### Test Categories

| Category | Files | Purpose |
|----------|-------|---------|
| Unit | `test/core/*.t.sol`, `test/token/*.t.sol`, `test/vault/*.t.sol`, `test/dex/*.t.sol`, `test/fee/*.t.sol` | 개별 컨트랙트 기능 검증 |
| Integration | `test/integration/*.t.sol` | 멀티 컨트랙트 라이프사이클 |
| Attack | `*Attack.t.sol` | 공격 벡터 방어 검증 |
| Module | `test/modules/*.t.sol` | LPManager, 모듈 시스템 |

### Security

Attack vectors verified across test files. Key defense mechanisms:

- **`_totalQuoteReserved`**: Per-quote-token accounting prevents cross-curve reserve theft
- **`nonReentrant`**: Guards bonding curve trading and graduation flow
- **Anti-sniping penalty**: Per-block lookup table on ProtocolManager (default: 80%/40%/20%/15%/10%/10%/5% for blocks 0..6 then 0; indexed by `block.number - createdAtBlock`), makes flash loan attacks unprofitable
- **NadFunPair fee enforcement**: Fees deducted atomically in `swap()`, no bypass via direct transfer
- **V3 callback authentication**: Only the canonical registered pool may call back for the active swap; replay, missing, double, and malformed-delta callbacks revert
- **Restricted FeeCollector settlement**: Only an authorized settler can trigger settlement once the per-quote threshold is met
- **ERC-165 validation**: VaultRegistry verifies IVault interface on registration

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#security) for the full defense matrix and known limitations. API references: [GiwaRouter](docs/contracts/en/router/GiwaRouter.md), [IGiwaRouter](docs/contracts/en/interfaces/IGiwaRouter.md), and [V3SwapAdapter](docs/contracts/en/adapters/V3SwapAdapter.md).
