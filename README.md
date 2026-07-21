# NadFun V2

Bonding curve token launchpad with post-graduation custom DEX trading and pair-level fee system. Built for Monad.

## Architecture

```
src/
├── core/       BondingCurve (UUPS), ProtocolManager (UUPS), LPManager (UUPS), TokenRegistry (UUPS), FeeCollector (UUPS), CreatorFeeProcessor (singleton)
├── router/     NadFunRouter (UUPS), NadFunRouter02 (UUPS)
├── token/      Token (EIP-1167 clone)
├── dex/        NadFunFactory (singleton), NadFunPair (per-pair)
├── vault/      VaultRegistry (UUPS), DividendVault (UUPS), BurnVault, LPVault, CreatorFeeVault (singletons)
├── adapters/   NadSwapAdapter, UniswapV2ExternalAdapter, UniswapV3ExternalAdapter (stateless)
├── interfaces/
└── libraries/  BondingCurveLibrary, NadFunLibrary, Math, UQ112x112, Constants
```

### Token Lifecycle

1. **Create** — Creator calls `NadFunRouter.create()` with `VaultAllocation[]`. BondingCurve deploys a Token clone (plain ERC20 + Permit), creates the NadFunPair via NadFunFactory, registers per-pair fee config in FeeCollector, configures singleton vaults, and charges `deployFee`.
2. **Trade (Bonding Curve)** — Users buy/sell via `NadFunRouter`. Prices follow a bonding curve formula. Protocol fee + creator fee deducted from quote on each trade. Creator fee sent to FeeCollector.
3. **Graduate** — When the curve's funding target is reached, `BondingCurve._graduate()` transfers token/quote liquidity to LPManager, which adds liquidity through the configured DEX adapter and keeps the graduation LP in protocol custody. `graduateFee` is deducted.
4. **Trade (DEX)** — Post-graduation, `NadFunRouter` auto-routes to the NadFunPair. NadFunPair deducts fees (LP fee + protocol fee + creator fee) in `swap()` and sends collected fees to FeeCollector.
5. **Fee Settlement** — FeeCollector forwards the active protocol fee share immediately on each collection and accumulates only creator fees per pair. When accumulated creator fees reach the settlement threshold, `settle()` forwards them to CreatorFeeProcessor for singleton vault distribution by BPS.

## Contracts

### Core (`src/core/`)

| Contract | Upgradeability | Description |
|----------|---------------|-------------|
| `BondingCurve` | UUPS Proxy | Token factory + bonding curve trading engine |
| `ProtocolManager` | UUPS Proxy | Unified protocol config: fees, creator fee settings, quote token registry |
| `LPManager` | UUPS Proxy | DEX liquidity provisioning via IDexAdapter; graduation LP is permanent protocol launch liquidity |
| `TokenRegistry` | UUPS Proxy | Token metadata registry (pair, quoteToken) |
| `NadFunRouter` | UUPS Proxy | Unified router: calls BondingCurve directly for pre-graduation, routes to DEX via IDexAdapter for post-graduation |
| `NadFunRouter02` | UUPS Proxy | Router02-compatible liquidity + fee-aware swap periphery for graduated pairs, standalone |
| `FeeCollector` | UUPS Proxy | Central fee management. Per-pair fee config stores creatorFeeRate + curveProtocolFeeRate + dexProtocolFeeRate. collectFee uses balance delta (msg.sender must be pair or bondingCurve), forwards protocol fee immediately, and accumulates creator fee only. settle forwards accumulated creator fee to CreatorFeeProcessor and early-returns if token not graduated. |
| `CreatorFeeProcessor` | Singleton | Receives quoteToken from FeeCollector, distributes to composable singleton vaults by BPS. |

### DEX (`src/dex/`)

| Contract | Pattern | Description |
|----------|---------|-------------|
| `NadFunFactory` | Singleton | Uniswap V2 fork factory. CREATE2 pair deployment. |
| `NadFunPair` | Per-pair | Uniswap V2 fork pair with fee deduction in `swap()`. Sends fees to FeeCollector. |

### Token (`src/token/`)

| Contract | Pattern | Description |
|----------|---------|-------------|
| `Token` | EIP-1167 Clone | Plain ERC20 + Burnable + ERC20Permit. No fee-on-transfer. |

### Vault (`src/vault/`)

| Contract | Pattern | Description |
|----------|---------|-------------|
| `VaultRegistry` | UUPS Proxy | Admin-only vault registry with ERC-165 interface validation |
| `BurnVault` | Singleton | Buyback and burn via NadFunPair swap |
| `LPVault` | Singleton | Swap half + addLiquidity + burn LP via NadFunPair |
| `CreatorFeeVault` | Singleton | Direct transfer to per-token configured recipient |
| `DividendVault` | UUPS Proxy | Multi-token dividend distribution: converts creator fees into 1–10 dividend tokens by ratio, global Merkle root → holder claim |

## Fee System

### Fee Structure

| Phase | Creator fee (creator-set) | Protocol Fee | LP Fee | User Total |
|-------|-------------------|-------------|--------|-----------|
| Bonding Curve | 1%/3%/5% (from quote) | 1% (from quote) | - | 2%/4%/6% |
| DEX (NadFunPair) | 1%/3%/5% (from quote) | configurable (from quote) | 0.25% | Sum |

- **Creator fee rates** are restricted to an allowlist: 1%, 3%, 5% (configurable by admin via `ProtocolManager`)
- **Bonding curve**: protocol fee + creator fee deducted from quote token in `BondingCurve.buy()/sell()`
- **DEX**: LP fee (0.25%) stays in reserves, protocol fee + creator fee sent to FeeCollector in `NadFunPair.swap()`
- **Creator fee is permanent** — no expiration (unlike v1's TaxToken which had creatorFeeExpirationTime)

### Fee Settlement (FeeCollector → CreatorFeeProcessor → Vaults)

```
NadFunPair.swap() / BondingCurve.buy()/sell()
     │
     └── Fee (quoteToken) → FeeCollector.collectFee()
              │
              └── When accumulated >= threshold:
                   authorized settler calls FeeCollector.settle()
                    └── Creator fee → CreatorFeeProcessor.processCreatorFee()
                         └── Distribute to singleton vaults by BPS:
                              ├── BurnVault: swap quoteToken → token → 0xdead
                              ├── LPVault: swap half + addLiquidity + burn LP
                              ├── CreatorFeeVault: direct transfer to recipient
                              └── DividendVault: convert to 1–10 dividend tokens → Merkle claim
```

## Key Design Decisions

- **Plain ERC20 Token** over fee-on-transfer TaxToken: simpler, no creator fee reentrancy issues, composable with any DEX/protocol
- **Custom NadFunPair** over external Uniswap V2: pair-level fee deduction gives protocol full control, no need for fee-on-transfer token
- **FeeCollector** as central fee hub: single point for fee config, accumulation, and settlement. Both NadFunPair and BondingCurve send fees here.
- **Simplified CreatorFeeProcessor**: no longer swaps baseToken → quoteToken. Receives quoteToken directly from FeeCollector. Just distributes to vaults.
- **Unified ProtocolManager** over separate FeeManager/AdminModule/QuoteManager: single deployment, fewer cross-contract calls, and a single authority for global config plus operator permissions
- **LPManager + IDexAdapter liquidity path** over router: keeps graduation liquidity provisioning isolated and adapter-driven
- **Permanent graduation LP**: LPManager does not expose a liquidity removal path; graduation LP is intended to remain protocol launch liquidity
- **Singleton CreatorFeeProcessor + Singleton Vaults** over EIP-1167 clones: constructor immutable for common state, per-token config via `setup()` / `mapping`. Reduces deployment cost per token.
- **Composable Vault System** over monolithic CreatorFeeProcessor: vault logic (burn, LP, transfer) is separated into independent, pluggable contracts. CreatorFeeProcessor just distributes.
- **VaultRegistry (admin-only + ERC-165)**: admin registers verified vaults. ERC-165 interface validation on registration. Admin can deactivate vulnerable types.

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

# Deploy
forge script script/Deploy.s.sol --rpc-url <rpc_url> --broadcast
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
- **Restricted FeeCollector settlement**: Only an authorized settler can trigger settlement once the per-quote threshold is met
- **ERC-165 validation**: VaultRegistry verifies IVault interface on registration

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#security) for the full defense matrix and known limitations.
