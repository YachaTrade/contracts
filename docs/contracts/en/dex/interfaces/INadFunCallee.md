# INadFunCallee

> `src/dex/interfaces/INadFunCallee.sol` — Interface

Callback interface for flash swap recipients. Implement this to receive tokens during a swap and execute arbitrary logic before the k-invariant is checked.

## Functions

| Function | Params | Returns | Description |
|----------|--------|---------|-------------|
| `nadFunCall` | `sender`, `amount0Out`, `amount1Out`, `data` | — | Called by NadFunPair during a swap when `data.length > 0`. The callee receives the output tokens, executes custom logic (e.g., arbitrage), and must ensure the pair has sufficient input tokens before returning |

## Usage

To perform a flash swap:
1. Call `NadFunPair.swap()` with non-empty `data`
2. The pair transfers output tokens to `to`, then calls `to.nadFunCall()`
3. Inside `nadFunCall`, repay the required input tokens to the pair
4. After the callback returns, the pair verifies the k-invariant holds
