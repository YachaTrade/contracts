# INadFunCallee

**Path:** `src/dex/interfaces/INadFunCallee.sol`
**Type:** Interface

Flash loan 콜백 인터페이스. NadFunPair.swap()에서 `data.length > 0`일 때 수신자(`to`)에 대해 호출됨. Uniswap V2의 `IUniswapV2Callee`에 해당.

---

## 함수 시그니처

| 함수 | 반환값 | 설명 |
|------|--------|------|
| `nadFunCall(sender, amount0Out, amount1Out, data)` | — | 페어가 출력 토큰을 전송한 후 호출. 콜백 내에서 입력 토큰을 페어로 상환해야 K invariant 검증을 통과함 |

---

## 사용처

Flash swap를 구현하려는 컨트랙트가 이 인터페이스를 구현. NadFunPair가 `swap()` 내에서 출력 전송 후 `nadFunCall()`을 호출하고, 이후 K invariant를 검증한다.
