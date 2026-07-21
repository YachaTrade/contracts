# NadFunFactory

> `src/dex/NadFunFactory.sol` — Singleton

Factory contract that deploys NadFunPair instances as EIP-1167 minimal proxy clones. Manages the pair registry, protocol fee destination, and pair implementation address. Admin functions are restricted to `protocolManager`.

## State Variables

| Variable | Type | Description |
|----------|------|-------------|
| `feeTo` | `address` | Recipient of protocol LP fees (mint fee) |
| `protocolManager` | `address` | Admin that can change `feeTo` and `implementation` |
| `feeCollector` | `address` | FeeCollector address passed to each new pair |
| `implementation` | `address` | NadFunPair implementation contract for EIP-1167 clones |
| `getPair` | `mapping(address => mapping(address => address))` | Token pair -> pair contract lookup (bidirectional) |
| `allPairs` | `address[]` | Ordered list of all deployed pairs |

## Functions

| Function | Params | Returns | Description |
|----------|--------|---------|-------------|
| `constructor` | `_protocolManager`, `_feeCollector`, `_implementation` | — | Sets protocol manager, fee collector, and pair implementation |
| `allPairsLength` | — | `uint256` | Number of deployed pairs |
| `createPair` | `tokenA`, `tokenB` | `address pair` | Deploys a new NadFunPair as an EIP-1167 clone using `Clones.cloneDeterministic()` with `keccak256(token0, token1)` as salt. Initializes the pair with `(factory, token0, token1, feeCollector)`. Reverts if pair exists or addresses are invalid |
| `setFeeTo` | `_feeTo` | — | Update protocol fee recipient. Restricted to `protocolManager` |
| `setImplementation` | `_implementation` | — | Update NadFunPair implementation address for future clones. Restricted to `protocolManager` |

## Events

| Event | Params | Description |
|-------|--------|-------------|
| `PairCreated` | `token0` (indexed), `token1` (indexed), `pair`, `pairCount` | Emitted when a new pair is deployed |

## Errors

| Error | Description |
|-------|-------------|
| `IdenticalAddresses` | `tokenA == tokenB` |
| `ZeroAddress` | Sorted `token0` is `address(0)` |
| `PairExists` | Pair already deployed for this token pair |
| `Forbidden` | Caller is not `protocolManager` |
