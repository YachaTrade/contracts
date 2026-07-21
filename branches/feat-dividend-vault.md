# feat/dividend-vault

## Purpose

DividendVault 신설 — creator fee의 일부를 다중 배당 토큰으로 변환해 홀더에게 Merkle claim으로
분배하는 vault. 기록(afterDeposit 비율 분할) / 변환(operator bot 주도) / 분배(Merkle root → claim)
3단 분리 구조. PR #209.

## Changes

- **DividendVault 본체** — 비율 분할 기록(`pendingSwap`/`dividendBalance` 회계), bot 주도 변환
  (단일 진입점 `executeConversion`: V2 토큰=router hop, 일반/외부 풀=어댑터 lane), Merkle 기반 `claim`
  (WMON native unwrap 지원). 설계: `docs/plans/2026-06-12-dividend-bot-conversion-design.md` +
  `docs/plans/2026-06-13-dividend-router-lane-design.md`
- **어댑터 3-lane allowlist** — NadSwap(일반 NadFunPair) / UniswapV2 / UniswapV3(Capricorn CL 콜백 포함)
  명시 배선, 미등록 어댑터로는 자금 이동 불가 (V2 토큰 buy는 별도 router hop)
- **V1 admission gate** — 졸업 전 V1 토큰은 변환 lane이 없어(CL pool 부재, router hop은
  V2 전용) `pendingSwap` quote가 잠기는 문제를 입구에서 차단. `setAllowedDividendToken(token, true)`
  시 codeless 주소 거부(`NotContract` — CREATE2 예측 주소 우회 봉쇄) + V1 BondingCurve
  `createdAt`/`isGraduated` 조회로 미졸업 V1 거부(`V1TokenNotGraduated`). V1 curve는 `initialize`
  파라미터로 배선 (`IBondingCurveV1` 최소 인터페이스 신설). 설계 §3.1
- **배포 스크립트** — `DeployDividendVaultSafe.s.sol`: EOA 배포 + Safe 서명용 calldata 출력,
  `V1_BONDING_CURVE` env 포함. 런북: `docs/plans/2026-06-12-dividend-vault-deploy-runbook.md`
- **executeBondingBuy → executeConversion 내 router 직접 분기 통합** — `executeBondingBuy` 삭제,
  변환 엔트리포인트를 `executeConversion` 하나로 단일화. V2 nad.fun 토큰(본딩·졸업 무관)은 hop 루프가
  `hop.adapter == router`를 인식해 `NadFunRouter.buy`를 직접 호출(라우터가 커브/DEX 분기·환불 소유).
  어댑터 wrapper를 만들지 않음 — NadFunRouter는 풀 어댑터가 아닌 상위 라우터라 `IDexAdapter`에
  부적합. `router`는 `initialize` 파라미터로 유지(슬롯 시프트 없음). 일반 NadFunPair 풀(USDC↔WMON,
  cross-quote 중간 다리)을 위해 **`nadSwapAdapter` lane은 유지** — 라우터는 토큰 주소로만 사므로
  임의 풀을 못 함. 최종 = router hop(V2 토큰) + 어댑터 3-lane(nadSwap·uniV2·uniV3), `setAdapters` 3-arg.
  설계: `docs/plans/2026-06-13-dividend-router-lane-design.md`

## Outcome

(머지 시 기록)
