# FeeTo Mainnet Safe Transactions

**Chain:** Monad-derived mainnet (chainId 143)
**Safe Multisig:** `0x63c46054C584231415d17A881f22b7898ceaDeB1`
**Target (all 3 txs):** ProtocolManager `0x71F846A560a4d68F53e5bd34ED084E7992f171C7`
**Value (all 3 txs):** `0`

## Deployed addresses

| Contract | Address |
|---|---|
| FeeTo Proxy | `0x9a6B8ADdFEC15A27C54570033c1EE02Af1d2c7E6` |
| FeeTo Impl | `0x376D54915e08d458f3c9e50f60f72cc6D534dCc2` |
| NadFunFactory | `0xA25b13127e63ddae6d0b35570FF3D39dBD621001` |
| NadFunRouter | `0x8986C8fD44eb85294A725a7e61AF35E76bA26F91` |
| CLAIM_BOT | `0x9A4673a0A047eD02598BE6D0AbceA872C04c478B` |

---

## Tx 1 — `setFactoryFeeTo(factory, feeTo)`

Routes NadFunFactory.feeTo() to the new FeeTo proxy. After this call, all V2 LP-dilution accrues on the proxy.

- **To:** `0x71F846A560a4d68F53e5bd34ED084E7992f171C7`
- **Value:** `0`
- **Data:**
```
0x62180460000000000000000000000000a25b13127e63ddae6d0b35570ff3d39dbd6210010000000000000000000000009a6b8addfec15a27c54570033c1ee02af1d2c7e6
```

Decoded:
- selector: `setFactoryFeeTo(address,address)` = `0x62180460`
- factory: `0xA25b13127e63ddae6d0b35570FF3D39dBD621001`
- feeTo:   `0x9a6B8ADdFEC15A27C54570033c1EE02Af1d2c7E6`

---

## Tx 2 — grant CLAIM_BOT `claim` permission

Allows the bot EOA to call `FeeTo.claim(...)`.

- **To:** `0x71F846A560a4d68F53e5bd34ED084E7992f171C7`
- **Value:** `0`
- **Data:**
```
0xa26546490000000000000000000000009a4673a0a047ed02598be6d0abcea872c04c478b0000000000000000000000009a6b8addfec15a27c54570033c1ee02af1d2c7e6b19e5036000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001
```

Decoded:
- selector: `setOperatorPermission(address,address,bytes4,bool)` = `0xa2654649`
- operator: `0x9A4673a0A047eD02598BE6D0AbceA872C04c478B` (CLAIM_BOT)
- target:   `0x9a6B8ADdFEC15A27C54570033c1EE02Af1d2c7E6` (FeeTo proxy)
- selector: `0xb19e5036` (`IFeeTo.claim.selector`)
- allowed:  `true`

---

## Tx 3 — grant CLAIM_BOT `burn` permission

Allows the bot EOA to call `FeeTo.burn(...)`.

- **To:** `0x71F846A560a4d68F53e5bd34ED084E7992f171C7`
- **Value:** `0`
- **Data:**
```
0xa26546490000000000000000000000009a4673a0a047ed02598be6d0abcea872c04c478b0000000000000000000000009a6b8addfec15a27c54570033c1ee02af1d2c7e66c5d6156000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001
```

Decoded:
- selector: `setOperatorPermission(address,address,bytes4,bool)` = `0xa2654649`
- operator: `0x9A4673a0A047eD02598BE6D0AbceA872C04c478B` (CLAIM_BOT)
- target:   `0x9a6B8ADdFEC15A27C54570033c1EE02Af1d2c7E6` (FeeTo proxy)
- selector: `0x6c5d6156` (`IFeeTo.burn.selector`)
- allowed:  `true`

---

## Safe UI submission

1. Open Safe `0x63c46054C584231415d17A881f22b7898ceaDeB1` on mainnet
2. **New Transaction → Transaction Builder**
3. For each of the 3 txs above:
   - **To:** `0x71F846A560a4d68F53e5bd34ED084E7992f171C7`
   - **Hex data:** paste the corresponding `data` block
   - **Value:** `0`
   - Click **Add new transaction**
4. **Create Batch → Simulate** → review
5. **Send Batch** → owners sign → execute

---

## Post-execution verification

```bash
source .env.mainnet
PROXY=0x9a6B8ADdFEC15A27C54570033c1EE02Af1d2c7E6

# Tx 1 effect
cast call $V2_NAD_FUN_FACTORY "feeTo()(address)" --rpc-url $RPC_URL
#   expected: 0x9a6B8ADdFEC15A27C54570033c1EE02Af1d2c7E6

# Tx 2 effect
cast call $V2_PROTOCOL_MANAGER "canCall(address,address,bytes4)(bool,uint32)" \
    $CLAIM_BOT $PROXY 0xb19e5036 --rpc-url $RPC_URL
#   expected: (true, 0)

# Tx 3 effect
cast call $V2_PROTOCOL_MANAGER "canCall(address,address,bytes4)(bool,uint32)" \
    $CLAIM_BOT $PROXY 0x6c5d6156 --rpc-url $RPC_URL
#   expected: (true, 0)
```
