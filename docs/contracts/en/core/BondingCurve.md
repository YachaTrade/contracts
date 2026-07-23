# BondingCurve

**Path:** `src/core/BondingCurve.sol`
**Pattern:** UUPS proxy
**Inheritance:** `IBondingCurve`, `AccessControlUpgradeable`, `ReentrancyGuard`

BondingCurve owns the pre-graduation token inventory and quote reserves. It creates V3-backed launches, executes virtual-reserve trades, and atomically allocates permanent V3 liquidity at graduation.

## Roles

| Role | Responsibility |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | Module configuration, role management, UUPS upgrades |
| `GUARDIAN_ROLE` | Halt and resume creation/trading |
| `ROUTER_ROLE` | Call `create`, `buy`, and `sell` |

## Modules

| Module | Responsibility |
| --- | --- |
| `TokenRegistry` | Register canonical V3 metadata |
| `LPManager` | Allocate graduation liquidity |
| `V3PoolDeployer` | Create and initialize the canonical pool |
| `CreatorFeeProcessor` | Configure the launch token's vault slots |

Modules are set by the admin and their authority wiring is validated during deployment.

## Lifecycle

### `create(params)`

1. Load the active quote configuration from ProtocolManager.
2. Charge `deployFee` to the current `feeReceiver`.
3. Clone the Token implementation with a deterministic salt.
4. Create or validate the canonical V3 pool and initialize its target price.
5. Initialize the Token with the pool address.
6. Register token, quote, pool, and V3 fee tier through `registerV3`.
7. Configure creator vault slots.
8. Store virtual and tracked reserves.
9. Execute an optional initial buy without the anti-sniping penalty.

### `buy(to, token, quoteIn)`

- Restricted to `ROUTER_ROLE`.
- Pulls the exact `quoteIn` from the router.
- Applies `curveProtocolFeeRate`.
- Applies the per-block anti-sniping penalty to ordinary buys.
- Prices output with `BondingCurveLibrary`.
- Updates tracked and virtual reserves.
- Transfers fees to `feeReceiver` and tokens to `to`.
- Triggers graduation when the minimum virtual token reserve is reached.

### `sell(to, token, tokenIn)`

- Restricted to `ROUTER_ROLE`.
- Pulls the exact token input.
- Prices quote output from virtual reserves.
- Applies `curveProtocolFeeRate`; sells have no anti-sniping penalty.
- Updates tracked and virtual reserves.
- Transfers the protocol fee and quote output.

### Graduation

Graduation marks the curve and token as graduated, charges `graduateFee`, transfers tracked launch assets to LPManager, and calls `allocate()`. LPManager and V3LiquidityActor create the two permanent V3 positions. Unused assets are sent to `feeReceiver`.

## Accounting guarantees

- Call-scoped balance deltas exclude donated balances.
- The curve rejects unsupported token versions and inactive quote assets.
- Creation, trades, and graduation are non-reentrant.
- A token can graduate only once.
- Direct transfers to the canonical pool are blocked by Token until graduation.
- UUPS upgrades require `DEFAULT_ADMIN_ROLE`.

## Events

The primary lifecycle events are `CurveCreate`, `CurveBuy`, `CurveSell`, `CurveGraduate`, `ModuleUpdate`, and `Halt`.
