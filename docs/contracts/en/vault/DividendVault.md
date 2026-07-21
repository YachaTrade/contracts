# DividendVault

**Path:** `src/vault/DividendVault.sol`
**Interface:** `src/interfaces/IDividendVault.sol` (`IDividendVault is IVault`)
**Pattern:** UUPS Proxy (Singleton)
**Inheritance:** `IDividendVault`, `UUPSUpgradeable`, `AccessManagedUpgradeable`, `ReentrancyGuard`

Multi-token dividend distribution vault. Receives creator fee (quoteToken) from CreatorFeeProcessor and **records** the split into 1–10 creator-configured dividend tokens by BPS ratio — the quoteToken slot is credited immediately, every other slice accumulates in `pendingSwap`. An **operator bot converts** pending slices later through explicit hop paths (`executeConversion`) — the single conversion entry point. V2 nad.fun tokens convert via the **router hop** (`hop.adapter == router`) regardless of graduation state — `NadFunRouter` dispatches bonding curve vs DEX internally; general NadFunPair pools go through the `nadSwapAdapter` lane and external markets through the Uniswap adapter lanes. Distribution is unchanged: off-chain snapshot → global Merkle root → holder self-claim. Singleton deployed once, shared across all tokens.

The contract holds **no routing knowledge**: path construction lives entirely off-chain in the bot. On-chain, the vault only defends — adapter allowlist, path endpoint validation, mid-hop full-consumption guard, real `amountOutMin`, pending-slot bounds, and atomicity.

> The `ConversionHop` / `DividendConfig` structs and all events and errors below are declared in `IDividendVault` (`src/interfaces/IDividendVault.sol`) — the contract declares none of them locally (IVaultRegistry/ICreatorFeeProcessor pattern). External references qualify them as `IDividendVault.X`.

---

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MAX_DIVIDEND_TOKENS` | `10` | Maximum dividend tokens per source token |

---

## State

State variables are grouped in the source under section headers — Protocol wiring / Dividend config / Conversion accounting / Merkle distribution / Setup allowlist — mirrored below.

### Protocol wiring

| Variable | Type | Purpose |
|----------|------|---------|
| `tokenRegistryV2` | `ITokenRegistry` | TokenRegistry (V2) for source-quote lookup and dividend-token admission (`setup`) |
| `creatorFeeProcessor` | `address` | Authorization for `afterDeposit` calls |
| `bondingCurve` | `address` | Authorization for `setup` calls |
| `router` | `address` | NadFunRouter — `executeConversion`'s router hop calls `buy` on it for V2 token conversions (bonding or graduated; the router dispatches curve vs DEX). Wired at `initialize`, NOT a `setAdapters` lane |
| `bondingCurveV1` | `IBondingCurveV1` | V1 BondingCurve (`src/integration/interfaces/IBondingCurveV1.sol`) — admission gate source of truth: `createdAt != 0` = V1 membership (survives graduation), `isGraduated` = one-way graduation flag |
| `nadSwapAdapter` | `IDexAdapter` | Vault-held allowlist lane for general NadFunPair pool hops — vanilla pools (e.g. USDC/WMON) and cross-quote bridge legs the router can't express, since the router only buys nad.fun tokens by address (0 = lane disabled) |
| `uniswapV2Adapter` | `IDexAdapter` | Vault-held allowlist lane for external Uniswap V2 pair hops (0 = lane disabled) |
| `uniswapV3Adapter` | `IDexAdapter` | Vault-held allowlist lane for Capricorn CL / Uniswap V3 pool hops (0 = lane disabled) |
| `wmon` | `address` | WMON singleton used ONLY to unwrap native MON on claim (0 = unwrap disabled) |

> **Two hop kinds, both fund-safe.** `executeConversion` dispatches each hop one of two ways: a **router hop** (`hop.adapter == router`) calls `NadFunRouter.buy` directly — the router is the init-time trusted address, so the equality check IS the router-lane allowlist; or an **adapter hop** through one of the three held lanes (`nadSwapAdapter`/`uniswapV2Adapter`/`uniswapV3Adapter`, wired via `setAdapters`), membership-checked with flat ifs BEFORE pushing tokens (`UnknownAdapter`). A rogue or mistyped adapter in a bot-supplied path can never receive funds, and an unset (zero) lane can never match (router is nonzero, so `address(0)` falls through to `UnknownAdapter`). Supporting a new adapter kind requires a contract upgrade adding a held lane and a flat dispatch branch — extension friction traded for fail-loud path safety. NadFunRouter is **not** wrapped in `IDexAdapter`: it is a higher-level router (no pool address, `transferFrom` pull pattern, owns graduation dispatch), so the vault calls it directly rather than forcing it into the pool-adapter mold. `nadSwapAdapter` (the NadFunPair AMM adapter) handles general/vanilla NadFunPair pools the router can't reach.

### Dividend config

| Variable | Type | Purpose |
|----------|------|---------|
| `_config` | `mapping(sourceToken => DividendConfig)` | Per-source dividend config (private, accessible via `getConfig`); configured-ness == `dividendTokens.length != 0` |

### Conversion accounting

| Variable | Type | Purpose |
|----------|------|---------|
| `dividendBalance` | `mapping(sourceToken => mapping(dividendToken => uint256))` | Accumulated dividend balance available for claim |
| `pendingSwap` | `mapping(sourceToken => mapping(dividendToken => uint256))` | Pending quoteToken awaiting bot conversion into a specific dividend token; keyed per (sourceToken, dividendToken) so each slot converts independently, in full or in parts |

### Merkle distribution

| Variable | Type | Purpose |
|----------|------|---------|
| `merkleRoot` | `bytes32` | Current global Merkle root (period identifier) |
| `claimedCumulative` | `mapping(sourceToken => mapping(holder => mapping(dividendToken => uint256)))` | Cumulative dividend already paid out per (source, holder, dividend). Monotonic high-water mark; `claim` pays only `leafAmount - claimedCumulative`, so a republished/equal/lower root pays 0 (race-free across roots) |

### Setup allowlist

| Variable | Type | Purpose |
|----------|------|---------|
| `allowedDividendToken` | `mapping(token => bool)` | Admin admission for external (non-V2-registered) dividend tokens at `setup` time — graduated V1 tokens, USDT-quoted assets, any external ERC20 |

> **V1 admission gate:** `setAllowedDividendToken(token, true)` reverts `NotContract` for codeless
> addresses and `V1TokenNotGraduated` for V1 tokens the V1 BondingCurve reports as created but not
> graduated. A pre-graduation V1 token has NO conversion lane (no Capricorn CL pool yet;
> the router hop is V2-only), so admitting one would strand its `pendingSwap` quote until a
> graduation that may never come. The code check closes the predicted-CREATE2-clone bypass: V1 deploys
> token code and records `createdAt` atomically in `create()`, so a not-yet-created V1 address can
> never slip through as an "external ERC20". Graduation is one-way, so the gate runs once at
> admission — no re-check at `setup` or conversion time. The removal path (`allowed = false`) is
> check-free.

`metadataURI` (`string`, the IVault metadata URI) is declared between the Merkle group and the setup allowlist.

### Structs

**`DividendConfig`**

| Field | Type | Description |
|-------|------|-------------|
| `dividendTokens` | `address[]` | 1–10 dividend token addresses |
| `ratios` | `uint16[]` | BPS ratios summing to 10000; parallel with `dividendTokens` |
| `minBalance` | `uint256` | Minimum sourceToken holdings required to claim (eligibility gate) |

> Configured-ness is `dividendTokens.length != 0` — `setup` rejects reconfiguration (`AlreadyConfigured`) and there is no deactivation path. `claim` reverts on unconfigured sources (`SourceNotConfigured`) by the same length check.

**`ConversionOrder`**

| Field | Type | Description |
|-------|------|-------------|
| `sourceToken` | `address` | Source token whose pending slot this order consumes |
| `dividendToken` | `address` | Target dividend token (must equal the last hop's `tokenOut`) |
| `path` | `ConversionHop[]` | Bot-supplied hop sequence from the source quote to the dividend token |
| `quoteIn` | `uint256` | Source-quote amount to convert (≤ the pending slot, `ExcessiveConversion`) |
| `amountOutMin` | `uint256` | Bot's live minimum-output quote (`InsufficientOutput`) |

**`ConversionHop`**

| Field | Type | Description |
|-------|------|-------------|
| `adapter` | `IDexAdapter` | Hop dispatch key. If it equals `router` → router hop (`NadFunRouter.buy`); else must be `nadSwapAdapter`/`uniswapV2Adapter`/`uniswapV3Adapter` (`UnknownAdapter` otherwise) |
| `pair` | `address` | NadFunPair / V2 pair / V3 pool address for an adapter hop. **Ignored for a router hop** (the router keys markets by token — no pool address). Bot-supplied; funds are protected by the dispatch key + `amountOutMin`, not by pair validation |
| `tokenOut` | `address` | Output token of this hop; the last hop's `tokenOut` must equal the target dividend token (`InvalidPath`) |

---

## Functions

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(protocolManager, tokenRegistryV2, creatorFeeProcessor, bondingCurve, router, bondingCurveV1, metadataURI)` | external (initializer) | UUPS initializer — every address zero-checked; `bondingCurveV1` additionally requires deployed code (`NotContract`) so a wrong address cannot silently disable the V1 gate |
| `setup(sourceToken, data)` | bondingCurve only | Configure dividend tokens, ratios, and minBalance for a source token |
| `afterDeposit(sourceToken, quoteToken, amount)` | creatorFeeProcessor only | Record-only entry point: split the deposit by ratios (quoteToken slot → `dividendBalance`, others → `pendingSwap`); zero external calls, no conversion |
| `executeConversion(ConversionOrder[] orders)` | restricted (operator bot) | The single conversion entry point: convert pending quote slices through explicit `ConversionHop[]` adapter paths — batched, sequential, atomic (any order's failure reverts the whole batch); `nonReentrant` |
| `setMerkleRoot(newRoot)` | restricted (operator) | Publish a new global Merkle root (starts a new claim period) |
| `claim(sourceTokens[], dividendTokens[], amounts[], merkleProofs[])` | anyone (self-claim) | Claim dividend allocations; leaf amount is the full cumulative accrued, pays only `amount - claimedCumulative` |
| `setWmon(newWmon)` | restricted (admin) | Set WMON address for native unwrap on claim (`0` disables unwrap) |
| `setAdapters(nadSwapAdapter, uniswapV2Adapter, uniswapV3Adapter)` | restricted (admin) | Replace the three adapter lanes (individual `0` = that lane disabled). The router hop needs no lane wiring — it's the init-time `router` |
| `setAllowedDividendToken(token, allowed)` | restricted (admin) | Open or close `setup` admission for an external (non-V2-registered) dividend token. Admission (`true`) requires deployed code (`NotContract`) and blocks pre-graduation V1 tokens (`V1TokenNotGraduated`); removal is check-free |
| `getConfig(sourceToken)` | external view | Returns `DividendConfig` for a source token |
| `supportsInterface(interfaceId)` | external pure | ERC-165: supports `IVault` and `IERC165` |

---

## Key Logic: setup

```
BondingCurve -> DividendVault.setup(sourceToken, abi.encode(dividendTokens, ratios, minBalance))
  |-- Validates: 1 ≤ length ≤ 10, ratios.length == dividendTokens.length, sum(ratios) == 10000
  |-- Per dividendToken dt:
  |     |-- dt == quoteToken                       → OK (no-conversion slot, credited at afterDeposit)
  |     |-- tokenRegistryV2.isRegistered(dt)       → OK (nad.fun V2 token, bonding or graduated)
  |     |-- allowedDividendToken[dt]               → OK (admin-admitted external token)
  |     |-- protocolManager.isAllowed(dt)          → OK (configured quote token, e.g. WMON / LvMON)
  |     |-- bondingCurveV1.createdAt(dt) != 0 && isGraduated(dt) → OK (graduated V1 token, has a DEX pool)
  |     +-- else                                   → revert UnsupportedDividendToken
  |-- No duplicate dividendTokens
  +-- Stores _config[sourceToken] (configured-ness == dividendTokens.length != 0); emit DividendSetup
```

> **No quote-match validation.** `setup` only gates *admission* — it does not care which quote a dividend
> token trades against. Cross-quote markets (e.g. an LvMON-quoted source paying a WMON-quoted dividend
> token, or a USDT-quoted asset like XAUT) are handled entirely by the bot's path construction at
> conversion time. Graduated V1 tokens and external ERC20s enter through `setAllowedDividendToken(dt,
> true)` — which itself blocks codeless addresses and pre-graduation V1 tokens (see the V1 admission
> gate above) — preserving the "unregistered token reverts" defense without any on-chain routing
> knowledge.
>
> **Configured quote tokens are auto-admitted.** Any token marked active in the ProtocolManager
> (`protocolManager.isAllowed(dt)`) — the protocol's blessed quote assets such as WMON and LvMON — is
> accepted as a dividend token for *any* source without a manual `allowedDividendToken` entry. The bot
> bridges the quote at conversion time.

---

## Key Logic: afterDeposit (record only)

```
CreatorFeeProcessor -> transfer(quoteToken, vault, amount)
CreatorFeeProcessor -> vault.afterDeposit(sourceToken, quoteToken, amount)
  |-- Record the deposit split ONLY (zero external calls; amount == 0 → empty split):
  |     Split amount by ratios (last slot takes rounding remainder; slice == 0 → skip the state write):
  |       |-- dt == quoteToken: dividendBalance[sourceToken][dt] += slice  (pending[i] = false)
  |       +-- else:             pendingSwap[sourceToken][dt]     += slice  (pending[i] = true)
  |-- emit Deposit(sourceToken, dividendTokens[], slices[], pending[]) ONCE after the loop (tokenCount > 0)
  +-- Done. No conversion, no self-calls, no try/catch — conversion happens later via the operator bot.
```

> `afterDeposit` cannot fail on routing or liquidity — it touches storage only, which protects the
> settle pipeline by construction (the previous design needed a try/catch self-call for this).
> Every non-quote slice waits in `pendingSwap` until the bot converts it.

---

## Key Logic: executeConversion (bot-supplied path)

```
operator bot -> executeConversion(ConversionOrder[] orders)   [restricted, nonReentrant]
  |-- orders.length == 0                            → revert InvalidPath
  |-- Per order {sourceToken, dividendToken, path[], quoteIn, amountOutMin} — sequential, atomic
  |   (any order's failure reverts the WHOLE batch; the bot drops the failing order and resubmits):
  |-- pending = pendingSwap[sourceToken][dividendToken]
  |-- quoteIn > pending                             → revert ExcessiveConversion
  |-- path.length == 0                              → revert InvalidPath
  |-- path[last].tokenOut != dividendToken          → revert InvalidPath  (endpoint validation)
  |-- currentToken = tokenRegistryV2.getQuoteToken(sourceToken); currentAmount = quoteIn
  |-- sourceQuoteBalanceBefore = balanceOf(currentToken, this)
  |-- Per hop i:
  |     |-- snapshot inputBalanceBefore / tokenOutBalanceBefore, then dispatch by hop kind:
  |     |   ROUTER HOP (hop.adapter == router):
  |     |     forceApprove(currentToken → router, currentAmount)
  |     |     router.buy({amountIn: currentAmount, amountOutMin: 0, token: tokenOut, to: this, deadline: now})
  |     |     forceApprove(currentToken → router, 0)
  |     |     (router pulls currentAmount from this vault, refunds the unconsumed remainder back here)
  |     |   ADAPTER HOP (else): membership BEFORE pushing tokens (flat ifs; zero/unset lane never matches):
  |     |     hop.adapter ∉ {nadSwapAdapter, uniswapV2Adapter, uniswapV3Adapter}
  |     |                                           → revert UnknownAdapter   (address(0) lands here; router is nonzero)
  |     |     safeTransfer(currentToken, hop.adapter, currentAmount)    (push pattern)
  |     |     adapter.swap(hop.pair, currentToken, tokenOut, currentAmount, this, "")
  |     |-- i == 0: consumed = sourceQuoteBalanceBefore - inputBalanceAfter
  |     |     (first-hop partial fill is ACCEPTED — the refund flows back via balance delta and
  |     |      pendingSwap is decremented by actual consumption only)
  |     |-- i != 0: inputBalanceAfter > inputBalanceBefore - currentAmount → revert PathResidue
  |     |     (mid-hop partial fill refunds an INTERMEDIATE token that sits outside pendingSwap
  |     |      accounting — revert the whole conversion; the bot retries with a fresh path/size.
  |     |      Delta-based check: the vault's pre-existing balance of that token is untouched)
  |     +-- currentAmount = balanceOf(hop.tokenOut, this) delta; currentToken = hop.tokenOut
  |-- received = final hop's currentAmount
  |-- received < amountOutMin                       → revert InsufficientOutput (bot supplies a real
  |                                                    off-chain quote — not a fixed minimum)
  |-- pendingSwap[sourceToken][dividendToken] = pending - consumed
  |-- dividendBalance[sourceToken][dividendToken] += received
  +-- After all orders: emit Converted(sourceTokens[], dividendTokens[], consumedQuote[], received[])
```

> **Atomicity:** any revert at any stage (`ExcessiveConversion`, `InvalidPath`, `UnknownAdapter`,
> adapter swap failure, `PathResidue`, `InsufficientOutput`) rolls back the entire batch —
> `pendingSwap` is preserved and the bot simply retries without the failing order. This is an operator
> transaction, so there is no try/catch softening: failures surface loudly in the bot's tx receipt.

---

## Key Logic: the router hop (V2 dividend tokens)

V2 dividend tokens — bonding or graduated — convert through the same `executeConversion` hop loop via
a **router hop**: the bot sets `hop.adapter == router` and the loop calls `NadFunRouter.buy` directly
(no adapter wrapper). The router owns graduation dispatch (bonding curve vs DEX) and the exact-in
refund math, so the vault never inspects graduation state and a token graduating between order
construction and execution cannot revert the conversion.

```
hop with hop.adapter == router:
  |-- forceApprove(currentToken → router, currentAmount)
  |-- router.buy({amountIn: currentAmount, amountOutMin: 0, token: tokenOut, to: vault, deadline: now})
  |     (slippage is enforced by the VAULT's order-level amountOutMin after the path completes;
  |      output goes straight to the vault)
  +-- forceApprove(currentToken → router, 0)
  # router pulls currentAmount from the vault (msg.sender) and refunds the unconsumed remainder
  # directly to the vault within buy() — so the vault's balance-delta `consumed` accounting deducts
  # only the actually-consumed quote from pendingSwap, with no adapter intermediary.
```

`hop.pair` is unused for a router hop (the router keys markets by token — there is no pool address).
A graduation-cap partial fill behaves exactly like any first-hop partial fill: the refund stays in the
vault and the unconsumed slice remains in `pendingSwap` for a later order. On a non-first hop the same
refund triggers `PathResidue` (intermediate tokens sit outside pending accounting), so cross-quote
paths ending in a bonding buy settle only when the buy fully consumes its input.

---

## Key Logic: claim (cumulative-claimed model)

The merkle leaf `amount` is the holder's **full cumulative accrued** for `(sourceToken, dividendToken)` — the
off-chain scheduler does NOT subtract anything. The contract pays only the unclaimed delta
(`amount - claimedCumulative`) and advances `claimedCumulative` to the leaf amount (a monotonic high-water
mark). A republished root with the same or lower cumulative pays 0, so distribution is **race-free
regardless of root timing** — a holder's total payout can never exceed the latest leaf amount.

```
holder -> DividendVault.claim(sourceTokens[], dividendTokens[], amounts[], merkleProofs[])
  |-- nonReentrant
  |-- length > 0 and all arrays same length, else InvalidArrayLength
  |-- merkleRoot != bytes32(0), else InvalidMerkleRoot
  |-- Per item i:
  |     1. amount == 0                             → skip
  |     2. leaf = keccak256(abi.encode(sourceToken, msg.sender, dividendToken, amount))
  |        MerkleProof.verify(proof, root, leaf)   → fail: revert InvalidMerkleProof
  |     3. _config[sourceToken].dividendTokens.length == 0 → revert SourceNotConfigured
  |     4. balanceOf(sourceToken, msg.sender) < minBalance → revert BelowMinBalance  (eligibility gate)
  |     5. alreadyClaimed = claimedCumulative[sourceToken][msg.sender][dividendToken]
  |        amount <= alreadyClaimed                 → skip  (nothing new accrued; republished/lower root)
  |        payout = amount - alreadyClaimed
  |     6. balanceOf(dividendToken, vault) < payout → revert InsufficientVaultBalance
  |        (cumulative NOT advanced — reclaimable once vault is funded)
  |     7. claimedCumulative[sourceToken][msg.sender][dividendToken] = amount  (CEI: high-water mark before transfer)
  |     8. payout (inline):
  |           dividendToken == wmon && wmon != 0:
  |             IWrappedNative(wmon).withdraw(payout)
  |             TransferHelper.safeTransferMon(msg.sender, payout)
  |           else: IERC20(dividendToken).safeTransfer(msg.sender, payout)
  +-- After all items: emit Claim(msg.sender, sourceTokens[], dividendTokens[], paidAmounts[])

receive() external payable { if (msg.sender != wmon) revert UnexpectedNative(); }
```

---

## Bot Conversion (operator operational guide)

The vault separates the dividend pipeline into three stages:

```
[Record     — on-chain, automatic] afterDeposit: auth + ratio split recording only (zero external calls)
[Convert    — bot-driven]          operator bot calls executeConversion with a path
[Distribute — unchanged]           setMerkleRoot → claim
```

All routing knowledge lives **off-chain in the operator bot** — the contract holds no route table, no
registry cascade, no quote-normalization logic. New quotes, new markets (e.g. XAUT/USDT), and V1 tokens
are all bot path-construction problems; the contract never changes.

| Dividend token | Conversion call | Bot path |
|---|---|---|
| Source quoteToken itself | none — `afterDeposit` credits `dividendBalance` directly | — |
| V2 token (bonding **or** graduated — the router dispatches) | `executeConversion` | single router hop: `hop.adapter = router`, `tokenOut = the token` (`pair` ignored) |
| V1 graduated token (Capricorn CL) | `executeConversion` | `uniswapV3Adapter` hops; multi-hop if the source quote differs from the pool quote (e.g. LvMON→WMON→token). Admin admits at setup via `setAllowedDividendToken` |
| General NadFunPair pool (vanilla pool / cross-quote bridge leg) | `executeConversion` | `nadSwapAdapter` hop: `hop.adapter = nadSwapAdapter`, `pair = the NadFunPair` |
| Other external ERC20 / cross-quote markets (e.g. XAUT/USDT) | `executeConversion` | any multi-hop combination of router hops + the three adapter lanes. Admin admits at setup via `setAllowedDividendToken` |
| Cross-quote V2 bonding token | multi-hop ending in the router lane (e.g. `quoteA →(uni) quoteB →(router) token`) — settles only on full consume: a graduation-cap refund on a non-first hop reverts `PathResidue`; the bot retries with a smaller `quoteIn` | — |
| Pre-graduation V1 token | **not admissible** — `setAllowedDividendToken` reverts `V1TokenNotGraduated` (no conversion lane exists; admission would strand `pendingSwap`); admit after graduation | — |

**On-chain defenses (what the contract still enforces):**

- **Hop dispatch allowlist** — router hop keyed on the init-time `router`; adapter hops on three
  vault-held lanes (`nadSwapAdapter` / `uniswapV2Adapter` / `uniswapV3Adapter`, wired via `setAdapters`); per-hop flat-if
  membership check BEFORE pushing tokens (`UnknownAdapter`).
- **Path endpoint validation** — non-empty path whose last hop outputs the target dividend token (`InvalidPath`).
- **Mid-hop full consumption** — a partial fill on any intermediate hop reverts the whole conversion
  (`PathResidue`); only the first hop may partially fill, with `pendingSwap` decremented by actual consumption.
- **Real `amountOutMin`** — supplied per order from the bot's live quote and checked by the VAULT after
  the path completes (`InsufficientOutput`); the router lane forwards `amountOutMin = 0` downstream
  because the order-level check is the same atomic revert boundary.
- **Pending bounds** — `quoteIn` can never exceed the recorded pending slot (`ExcessiveConversion`).
- **Atomicity** — any revert preserves `pendingSwap`; nothing is lost mid-path.

**Trust model:** the operator is already fully trusted for Merkle roots — it decides who gets paid how
much. Supplying conversion paths is a strictly smaller power: funds move only vault → allowlisted
adapter → vault, endpoints and minimum output are enforced on-chain. `setMerkleRoot` (distribution) and
`executeConversion` (conversion) are granted to **separate EOAs** — `restricted` is per-selector operator
permission, so this needs no contract change and shrinks the blast radius if one key leaks. Conversion
happens at bot cadence rather than at settle time — equivalent product-wise, since distribution itself is
already periodic root publishing.

- Supporting a new adapter *kind* requires a contract upgrade adding a held lane and a flat dispatch
  branch — extension friction traded for fail-loud path safety.
- `wmon` now serves ONLY the claim native-unwrap; it plays no role in conversion.

---

## Access Control

| Function | Caller | Guard |
|----------|--------|-------|
| `setup` | BondingCurve | `msg.sender == bondingCurve` |
| `afterDeposit` | CreatorFeeProcessor | `msg.sender == creatorFeeProcessor` |
| `executeConversion` | operator bot | `restricted` + `nonReentrant` |
| `setMerkleRoot` | operator | `restricted` |
| `setWmon` | admin | `restricted` |
| `setAdapters` | admin | `restricted` |
| `setAllowedDividendToken` | admin | `restricted` |
| `_authorizeUpgrade` | admin | `restricted` |
| `claim` | anyone (self only) | `nonReentrant` + proof + skip gates |

---

## Events

| Event | Parameters |
|-------|------------|
| `DividendSetup` | `address indexed sourceToken, address[] dividendTokens, uint16[] ratios, uint256 minBalance` |
| `Deposit` | `address indexed sourceToken, address[] dividendTokens, uint256[] slices, bool[] pending` — ONE event per `afterDeposit` covering the full split (config order); `pending[i] == true` = added to `pendingSwap`, `false` = credited to `dividendBalance` (quote slot) |
| `Converted` | `address[] sourceTokens, address[] dividendTokens, uint256[] consumedQuote, uint256[] received` (one entry per batch order) |
| `SetMerkleRoot` | `bytes32 indexed merkleRoot` |
| `Claim` | `address indexed holder, address[] sourceTokens, address[] dividendTokens, uint256[] amounts` (skipped items report `0`) |
| `SetWmon` | `address wmon` |
| `SetAdapters` | `address nadSwapAdapter, address uniswapV2Adapter, address uniswapV3Adapter` |
| `SetAllowedDividendToken` | `address indexed token, bool allowed` |

---

## Errors

| Error | Description |
|-------|-------------|
| `NotAuthorized()` | Caller is not the expected contract |
| `ZeroAddress()` | A required address parameter is zero |
| `InvalidTokenCount()` | dividendTokens length is 0 or > 10 |
| `LengthMismatch()` | ratios and dividendTokens lengths differ |
| `AlreadyConfigured()` | Source token is already configured (`dividendTokens.length != 0`) |
| `ZeroRatio()` | A ratio entry is zero |
| `UnsupportedDividendToken()` | `setup`: token is not the source quote, not V2-registered, not admin-allowlisted, and not a configured quote token (`isAllowed`) |
| `SourceNotConfigured()` | `claim`: source token has no dividend config |
| `BelowMinBalance()` | `claim`: holder balance below `minBalance` (eligibility gate) |
| `InsufficientVaultBalance()` | `claim`: vault's dividend-token balance is less than the payout (reclaimable once funded) |
| `DuplicateDividendToken()` | Same address appears twice in dividendTokens |
| `InvalidRatioTotal()` | Sum of ratios does not equal BPS (10000) |
| `InvalidMerkleRoot()` | Root is zero or merkleRoot not set |
| `InvalidMerkleProof()` | Merkle proof verification failed (entire call reverts) |
| `InvalidArrayLength()` | Claim arrays are empty or lengths differ |
| `UnexpectedNative()` | Native MON received from address other than wmon |
| `UnknownAdapter()` | A hop's adapter is not one of the three vault-held allowlist lanes — checked BEFORE pushing tokens |
| `InvalidPath()` | Conversion path is empty, or the last hop's `tokenOut` is not the target dividend token |
| `PathResidue()` | An intermediate hop partially filled and refunded a mid-path token — intermediate tokens sit outside `pendingSwap` accounting, so the whole conversion reverts for a clean retry |
| `InsufficientOutput()` | Final received amount is below the bot-supplied order-level `amountOutMin` |
| `ExcessiveConversion()` | `quoteIn` exceeds the pending slot `pendingSwap[sourceToken][dividendToken]` |
| `V1TokenNotGraduated()` | `setAllowedDividendToken(token, true)`: the V1 BondingCurve reports the token as created (`createdAt != 0`) but not graduated — no conversion lane exists yet |
| `NotContract()` | `initialize`: `bondingCurveV1` has no deployed code. `setAllowedDividendToken(token, true)`: token has no deployed code (closes the predicted-CREATE2-clone bypass) |
