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
forge test --match-path test/integration/WnativeV3GraduationE2E.t.sol -vvv
forge test --match-path test/integration/WnativeV3LpFeeCollectionE2E.t.sol -vvv
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

### GIWA Sepolia deployment

The current V3 deployment is live on GIWA Sepolia (`chainId = 91342`).

- RPC: `https://sepolia-rpc.giwa.io`
- Explorer: `https://sepolia-explorer.giwa.io`
- Deployment records: `broadcast/DeployV3Factory.s.sol/91342`,
  `broadcast/Deploy.s.sol/91342`, and `broadcast/DeployLens.s.sol/91342`
- Last onchain code check: 2026-07-23

Use the proxy addresses below for SDK, user, and administrative interactions.
Implementation addresses are listed separately for upgrade and deployment auditing.

#### Public integrations and proxy addresses

| Contract | Deployment kind | Address | Creation transaction |
| --- | --- | --- | --- |
| WNATIVE | Canonical predeploy | [`0x4200000000000000000000000000000000000006`](https://sepolia-explorer.giwa.io/address/0x4200000000000000000000000000000000000006) | Predeploy |
| UniswapV3Factory | Standalone | [`0x00a131Cf1fbEE9b02C4632756a813A32BC250849`](https://sepolia-explorer.giwa.io/address/0x00a131Cf1fbEE9b02C4632756a813A32BC250849) | [`0xa6ac…25d4`](https://sepolia-explorer.giwa.io/tx/0xa6ac410b71e5f04a9b466816b0bfd49878f909e897ddf67bd8b8e90db96125d4) |
| ProtocolManager | UUPS proxy | [`0x839AAE0711DDf9A3E8381d73Fbc8bD9146cc762e`](https://sepolia-explorer.giwa.io/address/0x839AAE0711DDf9A3E8381d73Fbc8bD9146cc762e) | [`0xdfa0…a830`](https://sepolia-explorer.giwa.io/tx/0xdfa05924db3c6cc6e45da4448a89dec6fe7bceb61a1d33db156a1c3a4ebca830) |
| TokenRegistry | UUPS proxy | [`0xB9E1a129818fE17300152E067b978eA9098100F0`](https://sepolia-explorer.giwa.io/address/0xB9E1a129818fE17300152E067b978eA9098100F0) | [`0xb637…6c5b`](https://sepolia-explorer.giwa.io/tx/0xb637ac9344586c8017b34ed63cdd083be924eb9853eb58b741315104d93f6c5b) |
| LPManager | UUPS proxy | [`0xA7dAacA8DF5685bCAA20043071953dC87b0BC24f`](https://sepolia-explorer.giwa.io/address/0xA7dAacA8DF5685bCAA20043071953dC87b0BC24f) | [`0xc055…d3e6`](https://sepolia-explorer.giwa.io/tx/0xc055180f0ee09fd48b088e66efbe01be1d3e18b0be161ec9b73572c1084ed3e6) |
| V3PoolDeployer | UUPS proxy | [`0xB4cBF62905D297bc7a6b61D4985F5345Cdc7232a`](https://sepolia-explorer.giwa.io/address/0xB4cBF62905D297bc7a6b61D4985F5345Cdc7232a) | [`0xb436…f04c`](https://sepolia-explorer.giwa.io/tx/0xb436aac0bcf86bc0573f7a92b9a17f9ab6336b6dd8d0f3c302c6acb540e6f04c) |
| BondingCurve | UUPS proxy | [`0x852716437D0e67e8BbaF4c8282C26b7941DD16E9`](https://sepolia-explorer.giwa.io/address/0x852716437D0e67e8BbaF4c8282C26b7941DD16E9) | [`0x2d75…2392`](https://sepolia-explorer.giwa.io/tx/0x2d755d985a881ed9f32d4446bda9d5818aef51cf02b924a05e661b59e6872392) |
| GiwaRouter | UUPS proxy | [`0x6139848625B395C4e2C347ED6C083dE2077Fb07b`](https://sepolia-explorer.giwa.io/address/0x6139848625B395C4e2C347ED6C083dE2077Fb07b) | [`0xb9d3…9bbb`](https://sepolia-explorer.giwa.io/tx/0xb9d3678783131bcdc515b465a08f0bacb9da2af8d6ae3e5667169f9298229bbb) |
| VaultRegistry | UUPS proxy | [`0x552239751E29260AfC8402bDc1099bcfD5e591f2`](https://sepolia-explorer.giwa.io/address/0x552239751E29260AfC8402bDc1099bcfD5e591f2) | [`0x2aec…03a9`](https://sepolia-explorer.giwa.io/tx/0x2aec0acab32337d121dcb5cafbaef57a1944aaa5307bd49cdb9660be6e2b03a9) |
| CreatorFeeVault | UUPS proxy | [`0xA101f5653e5cD45bBB7158606391dc2a893090d7`](https://sepolia-explorer.giwa.io/address/0xA101f5653e5cD45bBB7158606391dc2a893090d7) | [`0xb01e…c70f`](https://sepolia-explorer.giwa.io/tx/0xb01e509ff7ed8fd5566db1660e44838a5b10d59585462183b46e28328d32c70f) |
| Lens | Immutable integration | [`0x9f86fB3Cd9aBd4E0E2d9B7B42E16B01D478e2DD6`](https://sepolia-explorer.giwa.io/address/0x9f86fB3Cd9aBd4E0E2d9B7B42E16B01D478e2DD6) | [`0x8b71…7125`](https://sepolia-explorer.giwa.io/tx/0x8b71ef1003fec135ea7cd28ce915b96fb3fe10c189a09f3923e789f4e9d17125) |

#### Implementation and auxiliary addresses

| Contract | Deployment kind | Address | Creation transaction |
| --- | --- | --- | --- |
| ProtocolManager | Implementation | [`0x7FBC8478bbc18517bD5FFDB4b055B26EDe2f9025`](https://sepolia-explorer.giwa.io/address/0x7FBC8478bbc18517bD5FFDB4b055B26EDe2f9025) | [`0xa145…e32b`](https://sepolia-explorer.giwa.io/tx/0xa145d6672ce2a2a600e7a92e5fe81f0c69708da42734e236c47318bcadd7e32b) |
| TokenRegistry | Implementation | [`0x13cd48F5B53efd2DE08e5534734Eda50f1Bd8332`](https://sepolia-explorer.giwa.io/address/0x13cd48F5B53efd2DE08e5534734Eda50f1Bd8332) | [`0xe457…8f7d`](https://sepolia-explorer.giwa.io/tx/0xe4573c21ae589287abc9bca90160907cfdc6efab5e0e38cb509d559e27fc8f7d) |
| CreatorFeeProcessor | Standalone | [`0xDfD7a91438B35Ea94C8EAB89c0EE4fFf13E55969`](https://sepolia-explorer.giwa.io/address/0xDfD7a91438B35Ea94C8EAB89c0EE4fFf13E55969) | [`0xe2b6…9490`](https://sepolia-explorer.giwa.io/tx/0xe2b6ed244b1536724c502369ef5162f3673b5b3b198e75ebf32f7afbd73a9490) |
| V3SwapAdapter | Standalone | [`0x7e2E8492C0E3C8fF56920CDa02D7D37c60485852`](https://sepolia-explorer.giwa.io/address/0x7e2E8492C0E3C8fF56920CDa02D7D37c60485852) | [`0xee96…af49`](https://sepolia-explorer.giwa.io/tx/0xee96099f247f1bd68936aa71b04d208817c7cb592f53476477aec7a693f6af49) |
| LPManager | Implementation | [`0x5de5a8e8bFbE23578808d29E37BDdF38306DEC12`](https://sepolia-explorer.giwa.io/address/0x5de5a8e8bFbE23578808d29E37BDdF38306DEC12) | [`0x316f…7176`](https://sepolia-explorer.giwa.io/tx/0x316f926ec50192eb002560070666df7897091662867f9b98b2517be9a8ed7176) |
| V3PoolDeployer | Implementation | [`0x034709910cf31ffb318316FA7EdBAc6a18EC77DA`](https://sepolia-explorer.giwa.io/address/0x034709910cf31ffb318316FA7EdBAc6a18EC77DA) | [`0x7aea…62de`](https://sepolia-explorer.giwa.io/tx/0x7aeac0dbc13bf2d765699e58188d52c7418bf0cd09a57ffa7390ba05953062de) |
| V3LiquidityActor | Standalone | [`0x9685d85f92dcaC12802B367807352A0afFA5a466`](https://sepolia-explorer.giwa.io/address/0x9685d85f92dcaC12802B367807352A0afFA5a466) | [`0xa6c3…e300`](https://sepolia-explorer.giwa.io/tx/0xa6c36befab4d1a13d239bfa11dadc439389b64aab4266704f4859bc7670ce300) |
| Token | EIP-1167 clone implementation | [`0xf5f8C3707f278E15Ad7a9Dc0255C42757AeC0b46`](https://sepolia-explorer.giwa.io/address/0xf5f8C3707f278E15Ad7a9Dc0255C42757AeC0b46) | [`0x3f1f…40a9`](https://sepolia-explorer.giwa.io/tx/0x3f1f5032a868cc65de1d44d2df3041b2076a511c12d1ed066c653e01c00d40a9) |
| BondingCurve | Implementation | [`0xED770A987C645f76DC0f3eBf31b12bc8c2CE8384`](https://sepolia-explorer.giwa.io/address/0xED770A987C645f76DC0f3eBf31b12bc8c2CE8384) | [`0x88cb…c840`](https://sepolia-explorer.giwa.io/tx/0x88cbe28cc503ba04593d90b0a87517049d5fd491c7dceecea6dc96baeeb3c840) |
| QuoterV2 | Standalone | [`0x38783f78C81E55F73bA7e09f9462CBb994ae9ead`](https://sepolia-explorer.giwa.io/address/0x38783f78C81E55F73bA7e09f9462CBb994ae9ead) | [`0xd4ea…e0ac`](https://sepolia-explorer.giwa.io/tx/0xd4ea321862d0c833f121834c4965a4bcdd2ddc1c3acaf87b8c74a09f4da3e0ac) |
| GiwaRouter | Implementation | [`0x693a0837FE5Dc1F71DeFdF17c15c9eb655b3b09D`](https://sepolia-explorer.giwa.io/address/0x693a0837FE5Dc1F71DeFdF17c15c9eb655b3b09D) | [`0xd2c8…7a8c`](https://sepolia-explorer.giwa.io/tx/0xd2c8e4d413b67f33368a2e125d212793ecbf70a787ca5a21fd9121790daa7a8c) |
| VaultRegistry | Implementation | [`0x40c126f92DAD5C26D3b36aA7F2A949265FA534cB`](https://sepolia-explorer.giwa.io/address/0x40c126f92DAD5C26D3b36aA7F2A949265FA534cB) | [`0xf36f…1e70`](https://sepolia-explorer.giwa.io/tx/0xf36f1996dfe46525db40aa44462e97a5d79a4963b9c73cf1d00ac12673251e70) |
| CreatorFeeVault | Implementation | [`0x21A3455b170FD35b7089216791D72bDD2dbf9E53`](https://sepolia-explorer.giwa.io/address/0x21A3455b170FD35b7089216791D72bDD2dbf9E53) | [`0xf602…a986`](https://sepolia-explorer.giwa.io/tx/0xf602c2fdb5afe66d573a54cb1ccf6e28aa6a965831661e5bfd8771358355a986) |

These tables cover the contracts created by the current GIWA Sepolia V3 deployment
plus the canonical WNATIVE predeploy reused by the protocol. Legacy mainnet Safe batches
under `deploy/` are separate operational artifacts and are not part of this deployment.

The V3 factory is deployed separately, then passed to the protocol deployment.

```shell
# 1. Deploy the canonical V3 factory
forge script script/deploy/normal/DeployV3Factory.s.sol \
  --rpc-url "$RPC_URL" --broadcast

# 2. Deploy and wire the protocol
forge script script/deploy/normal/Deploy.s.sol \
  --rpc-url "$RPC_URL" --broadcast

# 3. Deploy the immutable lifecycle Lens against the GiwaRouter proxy
forge script script/deploy/normal/DeployLens.s.sol:DeployLens \
  --rpc-url "$RPC_URL" --broadcast
```

The main deployment reuses the chain's canonical wrapped-native token, deploys the V3-only launch stack, registers only `CreatorFeeVault`, applies selector permissions, and transfers final administration to `MULTISIG`. Operational values are supplied through the local environment; never commit private keys or environment files.

The Lens deployment requires `CHAIN_ID`, `PRIVATE_KEY`, `DEPLOYER`, `GIWA_ROUTER`,
`BONDING_CURVE`, `TOKEN_REGISTRY`, and `PROTOCOL_MANAGER`. The script validates the
chain, signer, Router proxy implementation, independently supplied dependencies, and
the deployed Lens wiring before reporting the new address.

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
