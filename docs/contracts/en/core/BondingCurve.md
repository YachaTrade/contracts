# BondingCurve

> `src/core/BondingCurve.sol` — UUPS Upgradeable

Central state contract managing the full token lifecycle: creation, bonding curve trading, graduation (DEX migration), and anti-sniping.

## Overview

BondingCurve integrates the functionality of the former Router + TokenFactory into a single contract. It deploys EIP-1167 minimal proxy clones (Token — plain ERC20, no fee-on-transfer), coordinates with the singleton CreatorFeeProcessor (via MODULE_CREATOR_FEE_PROCESSOR), manages bonding curve state, and orchestrates graduation to DEX.

**Key changes from v1:**
- **ERC20 trading**: All bonding curve trading uses ERC20 quote tokens. BondingCurve uses a balance-detection pattern — callers must pre-transfer tokens before calling buy/sell. The core functions detect the deposited amount from balance deltas rather than accepting an explicit amount parameter.
- **ProtocolManager**: Replaces the former CurveRegistry + FeeManager + AdminModule. Each token's bonding curve parameters (virtualReserve, minTokenReserve) come from ProtocolManager's per-quote-token config
- **Multi-quote-token**: Different tokens can use different quote tokens (WMON, USDT, etc.)
- **Virtual reserve AMM**: Uses virtualQuoteReserve + virtualTokenReserve instead of reserve + circulatingSupply

## Token Creation Flow

**Access Control:** `create()` requires `ROUTER_ROLE` — only NadFunRouter can call it. Users create tokens via `NadFunRouter.create()` or `NadFunRouter.createWithNative()`.

```
NadFunRouter -> BondingCurve.create(params)  [ROUTER_ROLE required]
  |-- Balance detection: totalIn = balance - _totalQuoteReserved
  |-- Validate params (quoteToken allowlist, creatorFeeRate)
  |-- Send deployFee(quoteToken) to feeReceiver via safeTransfer
  |-- Clone: Token (plain ERC20) -> Singleton Vaults setup (via VaultRegistry)
  |   -> NadFunFactory.createPair(token, quoteToken)
  |   -> TokenRegistry.register(token, pair, quoteToken, dexType)
  |   -> FeeCollector.setup(pair, token, quoteToken, creatorFeeRate, curveProtocolFeeRate, dexProtocolFeeRate)
  |   -> Singleton CreatorFeeProcessor.setup(token, vaults)
  |   -> Token.initialize(name, symbol, tokenURI, bondingCurve, pair) (1B minted to BondingCurve)
  |-- Store Curve (virtualQuoteReserve, virtualTokenReserve)
  +-- If extra quote detected: _initialBuy (sniping-free, protocol fee only)
```

`create()` is a unified function — if extra quote tokens are detected after deployFee collection (via balance detection), it automatically executes a sniping-free initial buy. No slippage protection needed since the first buy is atomic.

**`CreateTokenParams.creator` field:** NadFunRouter passes `msg.sender` (real user) as creator.

## Buy/Sell (Balance-Detection Pattern)

**Buy:**
```
Router -> transfer quoteToken to BondingCurve
Router -> BondingCurve.buy(to, token)
  |-- Detect quoteIn from balance delta (balanceOf - _totalQuoteReserved)
  |-- _calculateFees(token, quoteIn, curve, withSniping=true)
  |     -> returns (protocolFee, snipingFee, creatorFee, quoteInAfterFees)
  |     -> during settling: all fees = 0, quoteInAfterFees = quoteIn
  |-- BondingCurveLibrary.getAmountOut(quoteInAfterFees, k, virtualQuoteReserve, virtualTokenReserve)
  |-- Buy cap check: if tokenOut > availableTokens (virtualTokenReserve - minTokenReserve):
  |     |-- Clamp tokenOut = availableTokens
  |     |-- requiredQuoteIn = getAmountIn(availableTokens, k, reserves)
  |     +-- excessQuoteIn = quoteInAfterFees - requiredQuoteIn -> added to protocolFee
  |-- Transfer protocolFee + snipingFee -> feeReceiver
  |-- Transfer creatorFee -> FeeCollector, call collectFee(pair)
  |-- Transfer tokenOut -> to
  +-- If virtualTokenReserve == minTokenReserve -> _graduate()
```

The same buy cap logic applies to `_initialBuy` (token creation with initial buy), except sniping penalty is not applied. Excess effective quote is added to the protocol fee and sent to feeReceiver.

**Sell:**
```
Router -> transfer token to BondingCurve
Router -> BondingCurve.sell(to, token)
  |-- Detect tokenIn from balance delta (balanceOf - _totalTokenReserved)
  |-- BondingCurveLibrary.getAmountOut(tokenIn, k, virtualTokenReserve, virtualQuoteReserve)
  |-- _calculateFees(token, quoteOutBeforeFees, curve, withSniping=false)
  |     -> returns (protocolFee, 0, creatorFee, quoteOutAfterFees)
  |     -> during settling: all fees = 0, quoteOutAfterFees = quoteOutBeforeFees
  |-- Transfer protocolFee -> feeReceiver
  |-- Transfer creatorFee -> FeeCollector, call collectFee(pair)
  +-- Transfer quoteOutAfterFees -> to
```

## Graduation

Triggered automatically when `virtualTokenReserve == minTokenReserve`:

1. `curve.graduated = true`
2. `Token.setIsGraduated()` — sets simple boolean flag (no state machine)
3. Deduct `graduateFee(quoteToken)` from quote balance
4. Calculate `graduatingTokenAmount` to match DEX listing price to bonding curve price
5. Transfer remaining tokens (excess) to `feeReceiver`
6. Transfer `graduatingTokenAmount` + `quoteBalance` to LPManager
7. `LPManager.addLiquidity()` — adds liquidity via DexAdapter

## Fee-Free Settling

During FeeCollector settlement, vault buybacks call `BondingCurve.buy()`. To prevent recursive fee accumulation:
- `_calculateFees` checks `IFeeCollector.isSettling(curve.pair)` — returns 0 for all fees during settling
- `_getTotalFeeRate` returns 0 during settling
- This ensures vault buybacks (BurnVault, GiftVault) execute at the raw bonding curve rate

## Anti-Sniping

```
elapsed       = block.number - curve.createdAtBlock
penaltyTable  = ProtocolManager.snipingPenaltyTable()  // BPS array, indexed by elapsed

penaltyBps    = elapsed < penaltyTable.length ? penaltyTable[elapsed] : 0
penaltyQuote  = quoteAmount * penaltyBps / 10000
effectiveQuoteIn = quoteAmount - protocolFee - penaltyQuote - creatorFee
penaltyQuote -> feeReceiver (in quote tokens)
```

Block-number based lookup table — uses `block.number` instead of `block.timestamp`, which removes any reliance on validator timestamp drift. Default curve (elapsed-block index → BPS): `[8000, 4000, 2000, 1500, 1000, 1000, 500]`, 0% from block 7 onwards. The table can be replaced live via ProtocolManager's `setSnipingPenaltyTable(uint256[])` without an upgrade. Same-block buys map to index 0 (peak penalty). Penalty is applied to the quote input, not the token output.

## Curve Struct

```solidity
struct Curve {
    address token;                  // Token clone (plain ERC20)
    address creator;                // Token creator
    address quoteToken;             // Quote token (e.g., WMON, USDT)
    uint256 virtualQuoteReserve;    // AMM quote reserve (virtual + real)
    uint256 virtualTokenReserve;    // AMM token reserve (virtual + real)
    uint64 createdAtBlock;          // Creation block number (anti-sniping index)
    bool graduated;                 // DEX migration complete
    CurveVersion version;           // Contract version at creation
    ITokenRegistry.DexType dexType; // V2 or V3
    address pair;                   // DEX pair address
}
```

Curve struct fields (not separate mappings):
- `curve.k` — constant product k = virtualQuoteReserve_init * virtualTokenReserve_init
- `curve.initialTokenReserve` — initial virtualTokenReserve (for graduation check and real quote balance calculation)
- `curve.minTokenReserve` — graduation threshold (minimum virtualTokenReserve)
- `curve.initialQuoteReserve` — initial virtualQuoteReserve

## Version Strategy

BondingCurve manages curve versioning through the `CurveVersion` enum and a `VERSION` constant, enabling backward-compatible UUPS upgrades.

**How it works:**

- **CurveVersion enum**: Starts with `V1` (constant product AMM: `x * y = k`). New versions are appended to the enum.
- **Version recorded at creation**: When a token is created, `curve.version = VERSION` permanently records the current contract version.
- **UUPS upgrade**: When the implementation is upgraded with `VERSION = V2`, only tokens created after the upgrade get version V2. Existing V1 tokens retain `curve.version == V1`.
- **Version-based branching**: `buy()`, `sell()`, and `_graduate()` branch on `curve.version` to execute the appropriate logic for each version.
- **V2 AMM introduction**: A new `CurveV2` struct and `curvesV2` mapping would be added — no storage slot collisions with existing V1 data.
- **V1 curves are immutable**: The AMM structure (reserves, k value) of V1 curves cannot change. They operate under V1 logic for their entire lifetime.

```
// Example branching after upgrade:
if (curve.version == CurveVersion.V1) _buyV1(...)
else if (curve.version == CurveVersion.V2) _buyV2(...)
```

## Admin Functions

| Function | Access | Description |
|----------|--------|-------------|
| `setModule(moduleId, module)` | DEFAULT_ADMIN_ROLE | Register/update module |
| `halt(halted)` | GUARDIAN_ROLE | Emergency pause |
| `_authorizeUpgrade` | DEFAULT_ADMIN_ROLE | UUPS upgrade |

## Module Registry

| Module ID | Constant | Purpose |
|-----------|----------|---------|
| `keccak256("LP_MANAGER")` | `MODULE_LP_MANAGER` | Liquidity management |
| `keccak256("TOKEN_REGISTRY")` | `MODULE_TOKEN_REGISTRY` | Token metadata and DEX adapter registry |
| `keccak256("VAULT_REGISTRY")` | `MODULE_VAULT_REGISTRY` | Vault template registry |
| `keccak256("CREATOR_FEE_PROCESSOR")` | `MODULE_CREATOR_FEE_PROCESSOR` | Singleton CreatorFeeProcessor address |
| `keccak256("FEE_COLLECTOR")` | `MODULE_FEE_COLLECTOR` | Fee collection and settlement |
| `keccak256("FACTORY")` | `MODULE_FACTORY` | NadFunFactory for DEX pair creation |

## View Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `getCurve(token)` | `Curve memory` | Full curve state |
| `getQuoteToken(token)` | `address` | Quote token for a token |
| `isHalted()` | `bool` | Protocol pause status |
| `getAmountOut(token, amountIn, isBuy)` | `uint256` | Output amount for given input |
| `getAmountIn(token, amountOut, isBuy)` | `uint256` | Required input for desired output |
| `getSnipingPenalty(token)` | `uint256 penaltyBps` | Current anti-sniping penalty |
