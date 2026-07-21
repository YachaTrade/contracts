# INadFunFactory

> `src/dex/interfaces/INadFunFactory.sol` — Interface

Interface for the NadFunFactory contract. Defines the pair creation and fee management API.

## Functions

| Function | Params | Returns | Description |
|----------|--------|---------|-------------|
| `feeTo` | — | `address` | Protocol fee recipient |
| `feeToSetter` | — | `address` | Admin address |
| `feeCollector` | — | `address` | FeeCollector contract address |
| `getPair` | `tokenA`, `tokenB` | `address pair` | Lookup pair by token addresses |
| `allPairs` | `index` | `address pair` | Pair address by index |
| `allPairsLength` | — | `uint256` | Total number of pairs |
| `createPair` | `tokenA`, `tokenB` | `address pair` | Deploy a new pair |
| `setFeeTo` | `address` | — | Update fee recipient |
| `setFeeToSetter` | `address` | — | Transfer admin role |

## Events

| Event | Params | Description |
|-------|--------|-------------|
| `PairCreated` | `token0` (indexed), `token1` (indexed), `pair`, `pairCount` | New pair deployed |
