# Protocol-owned WETH quote design

## Objective

Deploy one protocol-owned, fully backed WETH contract for the fresh deployment and use it as the default quote token throughout the bonding curve, router, vault, and Uniswap V3 lifecycle.

## Wrapped asset

- Add a non-upgradeable `WrappedEther` contract that inherits Solady's audited `WETH` implementation without overriding its accounting logic.
- Native ETH deposits mint WETH 1:1 through `deposit()` or `receive()`.
- `withdraw(amount)` burns the caller's WETH before returning the same amount of native ETH.
- The contract has no owner, privileged mint, privileged burn, pause, fee, blacklist, or recovery function.
- The intended invariant is `address(weth).balance == weth.totalSupply()` after every successful deposit or withdrawal, excluding forced ETH sent by `selfdestruct`; forced ETH may make backing exceed supply but can never make it insufficient.

## Quote configuration

The deployment script deploys `WrappedEther` first and passes its resulting address directly to every downstream deployment step. It then registers that address in `ProtocolManager` using `addQuoteToken` and completes V3-specific configuration with `setV3QuoteConfig`.

The configured fields are:

- virtual quote reserve
- virtual token reserve
- minimum token reserve
- deploy fee
- graduate fee
- bonding-curve protocol fee rate
- post-graduation DEX protocol fee rate, set to zero for the V3 design
- settlement threshold where legacy infrastructure still requires the field
- Uniswap V3 fee tier
- LP fee protocol share in BPS

Configuration values remain deployment inputs, but the WETH address is not supplied as an environment variable. This prevents different modules from accidentally receiving different wrapped-native addresses.

## Module wiring

The single deployed WETH address is used by:

- `ProtocolManager` as the default active quote token
- `NadFunRouter` and `NadFunRouter02` as wrapped native
- native-aware vaults and `Treasury`
- `V3PoolDeployer` through the quote configuration
- `TokenRegistry` as the quote token stored in V3 token metadata
- the Uniswap V3 adapter and post-graduation routing path

No second WETH/WMON instance may be deployed by the same deployment run.

## V3 lifecycle

1. The deployment script deploys WETH and registers its quote and V3 configuration.
2. A token creation request selects `DexType.UniswapV3` and the deployed WETH quote.
3. `BondingCurve` calls `V3PoolDeployer.createPool` and registers the canonical pool through `TokenRegistry.registerV3`.
4. Curve trading uses WETH as its quote asset until the graduation threshold is reached.
5. Graduation transfers token and WETH balances to `LPManager`, which calls `allocate` and delegates V3 position operations to `V3LiquidityActor`.
6. Post-graduation Router trades resolve the V3 pool and WETH quote through `TokenRegistry` and the V3 adapter.
7. Later LP fee collection converts token-side fees to WETH, then splits WETH according to `ProtocolManager.lpFeeProtocolShareBps` between the protocol fee receiver and `CreatorFeeProcessor`.

The LP fee collection implementation is a separate task but must use this same WETH quote configuration.

## Permissions required at deployment

- `BondingCurve -> V3PoolDeployer.createPool`
- `BondingCurve -> TokenRegistry.registerV3`
- `BondingCurve -> LPManager.allocate`
- deployment admin -> `LPManager.setV3LiquidityActor`, used once during wiring
- Router role on `BondingCurve`
- V3 adapter registration on `TokenRegistry`

The legacy V2 `addLiquidity` permission must not be used by the new V3 lifecycle.

## Failure handling

- Deployment reverts if quote reserve values, fee tier, or LP split are invalid.
- Deployment verification checks that all modules expose the same WETH address or quote metadata.
- Token creation reverts if the WETH quote is inactive or the canonical V3 pool cannot be created and initialized.
- Graduation reverts atomically if pool metadata, actor ownership, permissions, balances, or V3 position minting are invalid.
- Native transfer failure during WETH withdrawal reverts the entire withdrawal, including the burn.

## Tests

### Wrapped asset

- `deposit`, direct native transfer, `withdraw`, transfer, allowance, and insufficient-balance behavior
- total supply and ETH backing invariant after successful operations
- no privileged minting or administrative control surface

### Deployment and configuration

- exactly one WETH deployment
- WETH registered as an active quote token
- expected V3 fee tier and LP protocol share
- Router, vault, and Treasury wiring use the same WETH address
- required selector permissions and V3 adapter registration

### Full lifecycle

- create a token against WETH
- buy until graduation
- verify canonical V3 pool and both liquidity positions
- verify curve and LPManager token/quote settlement
- execute post-graduation V3 buy and sell
- sell the user's entire post-graduation token balance and verify no token dust remains with the seller

## Out of scope

- Upgradeability or governance controls for WETH
- Multiple wrapped-native contracts
- Arbitrary owner minting
- Cross-chain bridge minting
- LP fee swap and distribution implementation beyond ensuring its quote-token dependency is compatible with this design
