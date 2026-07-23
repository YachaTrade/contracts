# Contract Reference Index

> Solidity 0.8.24 · Foundry · Monad

Each contract has detailed documentation in two languages:
- **English:** `docs/contracts/en/`
- **Korean:** `docs/contracts/ko/`

> **Note:** This index distinguishes the current GiwaRouter/canonical-V3 runtime from the retained V2 creation and graduation wiring. The default deployment script does not yet compose them into one end-to-end V3 launch lifecycle.

---

## Architecture Overview

```
Token Creation (current default deployment wiring):
  GiwaRouter → BondingCurve.create()
    ├─ ProtocolManager.getConfig(quoteToken)
    ├─ Clone: Token (plain ERC20) → NadFunFactory.createPair()
    ├─ FeeCollector.setup(pair, baseToken, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)
    ├─ TokenRegistry.register(token, pair, quoteToken, dexType)
    ├─ Singleton Vault setup (via VaultRegistry)
    ├─ Singleton CreatorFeeProcessor.setup(token, vaults[])
    └─ Token.initialize(name, symbol, uri, bondingCurve, pair)

Trading (Bonding Curve Phase):
  GiwaRouter → BondingCurve.buy/sell()
    ├─ BondingCurveLibrary.getAmountOut/getAmountIn
    ├─ Protocol fee + Creator fee → FeeCollector.collectFee(pair, protocolFee, creatorFee)
    ├─ Anti-Sniping quote penalty (configurable via ProtocolManager)
    └─ Auto-Graduation when virtualTokenReserve == minTokenReserve

Graduation:
  BondingCurve._graduate(token)
    ├─ Excess token → feeReceiver
    ├─ LPManager.addLiquidity() → IDexAdapter.addLiquidity()
    │   └─ LP tokens held by LPManager as permanent protocol launch liquidity
    └─ Token.setIsGraduated() + retained V2 registry metadata

Canonical V3 Runtime (for tokens already registered as UniswapV3):
  GiwaRouter → V3SwapAdapter → canonical factory pool
    ├─ exact-input or exact-output buy/sell
    ├─ quote-side dexProtocolFeeRate → current feeReceiver
    ├─ pool LP fee remains in Uniswap V3 execution
    └─ active callback is bound to registry + factory + token order + fee tier

Retained Legacy Fee Flow (Post-Graduation V2):
  DEX swap → NadFunPair.swap()
    ├─ LP fee (0.25%) → stays in reserves
    ├─ Protocol fee + Creator fee → FeeCollector.collectFee(pair, protocolFee, creatorFee)
    └─ authorized FeeCollector.settle(pair, minAmountOut) (when threshold met)
         ├─ Protocol fee는 collectFee 시점에 즉시 feeReceiver로 전달
         └─ Creator fee → CreatorFeeProcessor.processCreatorFee()
              └─ Distribute to singleton vaults by BPS
                   └─ vault[i].afterDeposit()
```

---

## Contract Patterns

| Pattern | Contracts |
|---------|-----------|
| **UUPS Proxy** | BondingCurve, ProtocolManager, LPManager, TokenRegistry, V3PoolDeployer, VaultRegistry, FeeCollector, Treasury, GiwaRouter, BurnVault, LPVault, GiftVault, CreatorFeeVault, DividendVault |
| **EIP-1167 Clone** | Token |
| **Singleton** | CreatorFeeProcessor; the vault UUPS proxies are one shared deployment per vault type |
| **Adapter / integration** | V3SwapAdapter, NadSwapAdapter, UniswapV2ExternalAdapter, UniswapV3ExternalAdapter, TokenInfoLens |
| **Custom DEX** | NadFunFactory (singleton), NadFunPair (one per pair) |

---

## DEX

| Contract | Source | Description |
|----------|--------|-------------|
| NadFunFactory | `src/dex/NadFunFactory.sol` | Uniswap V2 Factory fork. Permissionless pair creation via CREATE2. |
| NadFunPair | `src/dex/NadFunPair.sol` | Uniswap V2 Pair fork with pair-level fee deduction in swap(). getAmountOut/getAmountIn fee-aware view 함수 제공. Sends fees to FeeCollector. |

## Core

| Contract | Source | Description |
|----------|--------|-------------|
| BondingCurve | `src/core/BondingCurve.sol` | Token lifecycle orchestrator (UUPS). Token creation, curve trading with creator fee, graduation. |
| CreatorFeeProcessor | `src/core/CreatorFeeProcessor.sol` | Receives quoteToken from FeeCollector, distributes to vaults by BPS |
| FeeCollector | `src/core/FeeCollector.sol` | Central fee management (UUPS). Per-pair fee config (baseToken, quoteToken, creator/curve/dex rates). `collectFee(pair, protocolFee, creatorFee)` validates the received balance delta and caller; `settle(pair, minAmountOut)` is restricted to authorized settlers. |
| LPManager | `src/core/LPManager.sol` | LP accounting layer delegating to IDexAdapter (UUPS) |
| GiwaRouter | `src/router/GiwaRouter.sol` | Unified user router (UUPS). 졸업 전 BondingCurve, 졸업 후 canonical Uniswap V3 exact-input/exact-output, quote, permit, ERC-20/native refund 경로를 제공합니다. |
| ProtocolManager | `src/core/ProtocolManager.sol` | Unified protocol config: fees, creator fee settings, quote token registry (UUPS) |
| TokenRegistry | `src/core/TokenRegistry.sol` | Token metadata registry: pair, quoteToken, DexType→adapter (UUPS) |
| V3PoolDeployer | `src/core/V3PoolDeployer.sol` | Canonical factory pool creation/reuse, validation, initialization, and observation-cardinality setup (UUPS). Registry registration and liquidity are separate responsibilities. |
| Treasury | `src/core/Treasury.sol` | Protocol treasury used by the V3 launch infrastructure (UUPS). |

## Interfaces

| Interface | Source | Description |
|-----------|--------|-------------|
| IBondingCurve | `src/interfaces/IBondingCurve.sol` | Interface + CurveInfo/CreateTokenParams structs |
| ILPManager | `src/interfaces/ILPManager.sol` | LP accounting and delegation interface |
| IGiwaRouter | `src/interfaces/IGiwaRouter.sol` | Unified creation, curve/V3 trading, quote, permit, and native interface |
| IV3SwapAdapter | `src/interfaces/IV3SwapAdapter.sol` | Canonical V3 exact-input/exact-output adapter interface |
| IProtocolManager | `src/interfaces/IProtocolManager.sol` | Protocol configuration interface |
| ICreatorFeeProcessor | `src/interfaces/ICreatorFeeProcessor.sol` | Interface + VaultSlot struct (singleton, setup + processCreatorFee) |
| IToken | `src/interfaces/IToken.sol` | Plain ERC20 + Permit token interface (initialize, burn, setIsGraduated) |
| IDexAdapter | `src/interfaces/IDexAdapter.sol` | Pluggable DEX adapter interface (swap, liquidity, fees) |
| ITokenRegistry | `src/interfaces/ITokenRegistry.sol` | Interface + TokenInfo struct + adapter registry |
| IVault | `src/interfaces/IVault.sol` | Minimal vault interface (afterDeposit + setup) |
| IVaultRegistry | `src/interfaces/IVaultRegistry.sol` | VaultRegistry interface + VaultInfo struct |
| IDividendVault | `src/interfaces/IDividendVault.sol` | DividendVault interface (`is IVault`): ConversionHop/DividendConfig structs, 전체 events/errors + 외부 API (IVaultRegistry/ICreatorFeeProcessor 패턴) |
| IWrappedNative | `src/interfaces/IWrappedNative.sol` | WNATIVE interface |
| INadFunFactory | `src/dex/interfaces/INadFunFactory.sol` | Factory interface (createPair, getPair) |
| INadFunPair | `src/dex/interfaces/INadFunPair.sol` | Pair interface (mint, burn, swap, sync, getAmountOut, getAmountIn) |
| INadFunCallee | `src/dex/interfaces/INadFunCallee.sol` | Flash swap callback interface |
| IFeeCollector | `src/interfaces/IFeeCollector.sol` | FeeCollector interface (setup, getFeeConfig, collectFee, settle) |
| ITokenRegistryV1 | `src/integration/interfaces/ITokenRegistryV1.sol` | Minimal nadfun V1 (contract-v3) TokenRegistry interface: `tokenInfos(token) → (pool, lpManager, dexDeployer)`. V1 registration check = `pool != 0`. Used by TokenInfoLens. |

## Libraries

| Library | Source | Description |
|---------|--------|-------------|
| BondingCurveLibrary | `src/libraries/BondingCurveLibrary.sol` | Bonding curve math (constant-product) |
| NadFunLibrary | `src/libraries/NadFunLibrary.sol` | Retained legacy V2 path/math helper. `pairFor` resolves via `factory.getPair` (EIP-1167 clones invalidate the standard CREATE2 init-code-hash approach). Provides `quote`, `getAmountsOut`, `getAmountsIn` with per-hop delegation to `NadFunPair`. |
| Math | `src/libraries/Math.sol` | Uniswap V2 math utilities (min, sqrt) |
| UQ112x112 | `src/libraries/UQ112x112.sol` | 112-bit fixed-point arithmetic |
| Constants | `src/libraries/Constants.sol` | Shared constants |

## Adapter

| Contract | Source | Description |
|----------|--------|-------------|
| NadSwapAdapter | `src/adapters/NadSwapAdapter.sol` | IDexAdapter thin wrapper for NadFunPair. Delegates AMM views to pair, handles swap execution and liquidity. |
| V3SwapAdapter | `src/adapters/V3SwapAdapter.sol` | Canonical Uniswap V3 direct-swap adapter. Resolves the registered factory pool, binds one active callback context, validates caller/data/deltas, clears context before payment, and checks caller-owned input/recipient output deltas. |
| UniswapV2ExternalAdapter | `src/adapters/UniswapV2ExternalAdapter.sol` | Stateless IDexAdapter for external Uniswap V2 pairs (0.3% formula). Held by DividendVault as the external-V2 adapter lane (`setAdapters`). Validates tokenIn/tokenOut against pair token0/token1 (TokenMismatch). |
| UniswapV3ExternalAdapter | `src/adapters/UniswapV3ExternalAdapter.sol` | Stateless IDexAdapter for Capricorn CL / Uniswap V3 pools: direct `pool.swap` + swap callback (`capricornCLSwapCallback` / `uniswapV3SwapCallback` / `pancakeV3SwapCallback` selectors over one shared handler). Held by DividendVault as the V3 adapter lane (`setAdapters`) — bot paths route V1/Capricorn and external V3 hops through it. Guards: SwapInProgress reentrancy, missing/double callback, delta validation, ExcessiveInput, partial-fill refund to caller. No factory validation — pool addresses are trusted inputs (V1 registry / restricted admin). |

## Token

| Contract | Source | Description |
|----------|--------|-------------|
| Token | `src/token/Token.sol` | Plain ERC20 + Burnable + Permit (EIP-1167 clone) |

## Vault

| Contract | Source | Description |
|----------|--------|-------------|
| BurnVault | `src/vault/BurnVault.sol` | Buyback & burn (swap quoteToken → token via IDexAdapter → 0xdead) |
| LPVault | `src/vault/LPVault.sol` | Swap half + addLiquidity via IDexAdapter + burn LP |
| CreatorFeeVault | `src/vault/CreatorFeeVault.sol` | Accumulates quoteToken per token; configured creator claims ERC-20 or WNATIVE-unwrapped native |
| DividendVault | `src/vault/DividendVault.sol` | Multi-token dividend vault (UUPS). Converts creator fees into 1–10 dividend tokens by creator-configured ratio. Global Merkle root + per-period holder claim. Conversion is bot-driven: afterDeposit records ratio splits; an operator converts through GiwaRouter for bonding or registered canonical-V3 tokens, NadSwapAdapter for explicit legacy pools, or the external V2/V3 adapter lanes. |
| VaultRegistry | `src/vault/VaultRegistry.sol` | Authority-restricted singleton vault registry (UUPS, VaultType enum); owner or selector-authorized operators may mutate it. |

## Integration

| Contract | Source | Description |
|----------|--------|-------------|
| TokenInfoLens | `src/integration/TokenInfoLens.sol` | Stateless view contract. 토큰 주소를 받아 `(version, quoteToken)` 리턴 — V1(`contract-v3`)은 별도로 설정한 legacy V1 wrapped-native, V2는 V2 registry 저장 quoteToken 그대로, 미등록은 `(None, address(0))`. 오프체인 SDK/indexer 전용. |

---

## Removed in v2

| Contract | Reason |
|----------|--------|
| TaxToken | Replaced by Token (plain ERC20). Fee-on-transfer removed. |
| V2DexAdapter | Replaced by NadSwapAdapter (wraps NadFunPair with fee logic). |
| ITaxToken | Replaced by IToken. |
| NadFunRouter / NadFunRouter02 | Removed from the public runtime and replaced by GiwaRouter's bonding-curve and canonical-V3 user path. Legacy NadFunPair adapters remain for explicit internal compatibility lanes. |
| BondingCurveRouter / DexRouter | Consolidated into the current GiwaRouter user entry point. |
| IBondingCurveRouter / IDexRouter / INadFunRouter | Replaced by IGiwaRouter. |
