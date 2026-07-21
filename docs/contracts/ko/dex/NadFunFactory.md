# NadFunFactory

**Path:** `src/dex/NadFunFactory.sol`
**Pattern:** Singleton

NadFunPair 배포를 관리하는 팩토리 컨트랙트. EIP-1167 minimal proxy clone으로 결정적 주소에 페어를 배포하고, 페어별 FeeCollector를 설정한다. 관리 함수는 `protocolManager`만 호출 가능.

---

## 상태 변수

| 변수 | 타입 | 설명 |
|------|------|------|
| `feeTo` | `address` | 프로토콜 수수료 수령 주소 (LP 수수료 1/5 민팅 대상) |
| `protocolManager` | `address` | `feeTo`, `implementation` 변경 권한 주소 |
| `feeCollector` | `address` | 페어 초기화 시 전달되는 FeeCollector 주소 |
| `implementation` | `address` | EIP-1167 clone용 NadFunPair 구현체 주소 |
| `getPair` | `mapping(address => mapping(address => address))` | (tokenA, tokenB) -> pair 주소 매핑 |
| `allPairs` | `address[]` | 생성된 모든 페어 배열 |

---

## 함수

| 함수 | 접근 | 설명 |
|------|------|------|
| `constructor(protocolManager, feeCollector, implementation)` | — | protocolManager, FeeCollector, 페어 구현체 설정 |
| `allPairsLength()` | view | 생성된 전체 페어 수 반환 |
| `createPair(tokenA, tokenB)` | external | `Clones.cloneDeterministic()`로 NadFunPair clone 배포 후 초기화 (factory, token0, token1, feeCollector) |
| `setFeeTo(feeTo)` | external | 프로토콜 수수료 수령 주소 변경 (protocolManager만 호출 가능) |
| `setImplementation(implementation)` | external | NadFunPair 구현체 주소 변경 (protocolManager만 호출 가능) |

---

## 이벤트

| 이벤트 | 설명 |
|--------|------|
| `PairCreated(token0, token1, pair, pairCount)` | 새 페어 생성 시 발생 |

---

## 에러

| 에러 | 설명 |
|------|------|
| `IdenticalAddresses()` | tokenA == tokenB |
| `ZeroAddress()` | 정렬 후 token0이 zero address |
| `PairExists()` | 이미 존재하는 페어 |
| `Forbidden()` | msg.sender != protocolManager |

---

## 핵심 설계: EIP-1167 Clone 배포

`createPair`는 `Clones.cloneDeterministic(implementation, salt)`를 사용하여 결정적 주소에 minimal proxy clone을 배포한다. salt는 `keccak256(abi.encodePacked(token0, token1))`. 오프체인에서 페어 주소를 미리 계산할 수 있으며, full bytecode 배포 대비 가스가 대폭 절약된다.
