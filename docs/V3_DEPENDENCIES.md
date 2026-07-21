# Uniswap V3 Dependencies

- v3-core: 6562c52e8f75f0c10f9deaf44861847585fc8129
- v3-periphery: b325bb0905d922ae61fcc7df85ee802e8df5e96c
- Source worktree: /Users/gyu/project/nads-pump/contract-v3
- Local delta: exact-version Solidity pragmas in deployable/test contracts are relaxed to the current contract-v3 worktree values; mathematical library bodies are unchanged.
- PoolAddress delta: `POOL_INIT_CODE_HASH` is `0x367752ac78d27e54ea28c034da350086d0844159dd0761b767172761728fc7c3`, measured from `UniswapV3Pool` compiled with this repository's Solidity 0.8.24, Cancun, optimizer-runs-200 profile. The reference periphery value `0xa598dd...a31ff` does not derive the factory pool under that profile; compatibility tests assert both the creation hash and factory/computed address equality.
- Runtime validation: external or already-deployed factories must be treated as the source of truth through `createPool`/`getPool` and pool immutable checks. Do not assume this local creation hash applies to bytecode produced by another compiler profile.
