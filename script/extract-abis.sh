#!/bin/bash
# ABI 추출 스크립트 — 주요 컨트랙트 ABI를 abis/ 폴더에 저장
# Usage: ./script/extract-abis.sh

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
OUT="$ROOT/out"
DEST="$ROOT/abis"

# 빌드 확인
if [ ! -d "$OUT" ]; then
  echo "Building..."
  forge build
fi

mkdir -p "$DEST"

# Remove retired Router artifacts that are no longer part of the canonical ABI set.
rm -f "$DEST/NadFunRouter.json" "$DEST/NadFunRouter02.json"

# 주요 컨트랙트 목록
CONTRACTS=(
  "BondingCurve"
  "ProtocolManager"
  "TokenRegistry"
  "LPManager"
  "GiwaRouter"
  "V3SwapAdapter"
  "CreatorFeeProcessor"
  "Treasury"
  "Token"
  "VaultRegistry"
  "BurnVault"
  "CreatorFeeVault"
  "GiftVault"
  "TokenInfoLens"
)

count=0
for name in "${CONTRACTS[@]}"; do
  json="$OUT/${name}.sol/${name}.json"
  if [ ! -f "$json" ]; then
    echo "SKIP: $name (not found in out/)"
    continue
  fi
  jq '.abi' "$json" > "$DEST/${name}.json"
  count=$((count + 1))
done

echo "Done: ${count}/${#CONTRACTS[@]} ABIs extracted to abis/"
