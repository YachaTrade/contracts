# Contract Reference Index

> Solidity 0.8.24 · Foundry · canonical Uniswap V3

The current runtime is a V3-only launch lifecycle. English and Korean component documents are under `docs/contracts/en/` and `docs/contracts/ko/`.

## Runtime graph

```text
YachaRouter
  ├─ BondingCurve
  │    ├─ Token clone
  │    ├─ V3PoolDeployer
  │    ├─ TokenRegistry
  │    └─ LPManager ──► V3LiquidityActor ──► canonical V3 pool
  └─ V3SwapAdapter ─────────────────────────► canonical V3 pool

LPManager.collect
  ├─ protocol quote share ──► feeReceiver
  └─ creator quote share ───► CreatorFeeProcessor ──► CreatorFeeVault
```

## Deployment patterns

| Pattern | Contracts |
| --- | --- |
| UUPS proxy in default deployment | `ProtocolManager`, `BondingCurve`, `TokenRegistry`, `V3PoolDeployer`, `LPManager`, `YachaRouter`, `VaultRegistry`, `CreatorFeeVault` |
| Immutable singleton | `CreatorFeeProcessor`, `V3LiquidityActor`, `V3SwapAdapter`, `QuoterV2`, `Lens`, `TokenInfoLens` |
| EIP-1167 clone | `Token` |
| Optional source module, not deployed by default | `Treasury`, `BurnVault`, `GiftVault`, `DividendVault`, external Uniswap adapters |

## Core

| Contract | Source | Responsibility |
| --- | --- | --- |
| `ProtocolManager` | `src/core/ProtocolManager.sol` | Per-quote lifecycle/V3 configuration, fee receiver, anti-sniping table, selector permissions |
| `BondingCurve` | `src/core/BondingCurve.sol` | Token creation, virtual-reserve trading, reserve accounting, graduation |
| `TokenRegistry` | `src/core/TokenRegistry.sol` | Canonical token, quote, pool, DEX type, and V3 fee metadata |
| `V3PoolDeployer` | `src/core/V3PoolDeployer.sol` | Canonical factory pool creation, validation, and price initialization |
| `LPManager` | `src/core/LPManager.sol` | Two-position permanent liquidity, fee preview, fee collection, quote distribution |
| `CreatorFeeProcessor` | `src/core/CreatorFeeProcessor.sol` | Authorized pull and BPS distribution of the creator LP-fee share |
| `Treasury` | `src/core/Treasury.sol` | Optional managed treasury; not in the default deployment |

## Router and V3 execution

| Contract | Source | Responsibility |
| --- | --- | --- |
| `YachaRouter` | `src/router/YachaRouter.sol` | Creation, curve/V3 trade routing, quotes, permits, WNATIVE handling, refunds |
| `V3LiquidityActor` | `src/actors/V3LiquidityActor.sol` | Permanent position custody, mint callbacks, position fee collection |
| `V3SwapAdapter` | `src/adapters/V3SwapAdapter.sol` | Canonical registered-pool swaps and callback authentication |
| `UniswapV2ExternalAdapter` | `src/adapters/UniswapV2ExternalAdapter.sol` | Optional external pair adapter used only by optional integrations |
| `UniswapV3ExternalAdapter` | `src/adapters/UniswapV3ExternalAdapter.sol` | Optional external concentrated-liquidity adapter |

## Token and vaults

| Contract | Source | Responsibility |
| --- | --- | --- |
| `Token` | `src/token/Token.sol` | Fixed-supply ERC-20 clone with ERC-2612 permit and pre-graduation pool-transfer guard |
| `VaultRegistry` | `src/vault/VaultRegistry.sol` | Authority-controlled vault implementation registry |
| `CreatorFeeVault` | `src/vault/CreatorFeeVault.sol` | Creator quote accounting and claims; the only default registered vault |
| `BurnVault` | `src/vault/BurnVault.sol` | Optional buyback-and-burn destination |
| `GiftVault` | `src/vault/GiftVault.sol` | Optional receiver-bound gift destination |
| `DividendVault` | `src/vault/DividendVault.sol` | Optional multi-token Merkle dividend destination |

## Read integrations

| Contract | Source | Responsibility |
| --- | --- | --- |
| `Lens` | `src/lens/Lens.sol` | Current YachaRouter/BondingCurve/TokenRegistry facade |
| `TokenInfoLens` | `src/integration/TokenInfoLens.sol` | Token version and quote metadata for SDKs and indexers |

## Interfaces

The public boundaries are defined under `src/interfaces/`:

- `IBondingCurve`
- `ICreatorFeeProcessor`
- `IDexAdapter`
- `IDividendVault`
- `ILPManager`
- `IProtocolManager`
- `IToken`
- `ITokenRegistry`
- `ITreasury`
- `IV3LiquidityActor`
- `IV3PoolDeployer`
- `IV3SwapAdapter`
- `IVault`
- `IVaultRegistry`
- `IWrappedNative`
- `IYachaRouter`

## Libraries

| Library | Source | Responsibility |
| --- | --- | --- |
| `BondingCurveLibrary` | `src/libraries/BondingCurveLibrary.sol` | Virtual-reserve constant-product calculations |
| `Constants` | `src/libraries/Constants.sol` | Supply and BPS constants |
| `Math` | `src/libraries/Math.sol` | Shared arithmetic helpers |
| `TransferHelper` | `src/libraries/TransferHelper.sol` | Native and ERC-20 transfer helpers |

## Detailed references

- [Architecture](ARCHITECTURE.md)
- [Protocol flow — English](PROTOCOL_FLOW.md)
- [Protocol flow — Korean](PROTOCOL_FLOW.ko.md)
- [YachaRouter — English](contracts/en/router/YachaRouter.md)
- [YachaRouter — Korean](contracts/ko/router/YachaRouter.md)
- [Repository README](../README.md)
