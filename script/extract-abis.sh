#!/bin/bash
set -euo pipefail

for tool in git forge jq ln mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool not found: $tool" >&2; exit 1; }
done

canonicalize_dest() {
  local candidate=$1
  local absolute probe suffix component resolved

  case "$candidate" in
    /*) absolute=$candidate ;;
    *) absolute="$PWD/$candidate" ;;
  esac
  case "/$absolute/" in
    *"/../"*|*"/./"*) return 1 ;;
  esac

  probe=${absolute%/}
  [ -n "$probe" ] || probe=/
  suffix=
  while [ ! -e "$probe" ]; do
    component=${probe##*/}
    [ -n "$component" ] || return 1
    suffix="/$component$suffix"
    probe=${probe%/*}
    [ -n "$probe" ] || probe=/
  done
  [ -d "$probe" ] || return 1
  resolved=$(cd -P "$probe" 2>/dev/null && pwd -P) || return 1
  if [ "$resolved" = / ]; then
    [ -n "$suffix" ] && printf '%s\n' "$suffix" || printf '/\n'
  else
    printf '%s%s\n' "$resolved" "$suffix"
  fi
}

physical_pwd() (
  unset PWD
  env pwd -P
)

ROOT=$(git rev-parse --show-toplevel)
ROOT_RESOLVED=$(cd -P "$ROOT" && pwd -P)
OUT="$ROOT/out"
if [ "${ABI_DEST+x}" = x ]; then
  requested_dest=$ABI_DEST
else
  requested_dest="$ROOT/abis"
fi
[ -n "$requested_dest" ] || { echo "ERROR: unsafe ABI destination: $requested_dest" >&2; exit 1; }
DEST=$(canonicalize_dest "$requested_dest") || { echo "ERROR: unsafe ABI destination: $requested_dest" >&2; exit 1; }
case "$DEST" in
  ""|/|"$ROOT_RESOLVED") echo "ERROR: unsafe ABI destination: $requested_dest" >&2; exit 1 ;;
esac
parent=${DEST%/*}
[ -n "$parent" ] || parent=/
dest_name=${DEST##*/}
case "$dest_name" in
  ""|.|..|*/*) echo "ERROR: unsafe ABI destination basename: $dest_name" >&2; exit 1 ;;
esac
[ -d "$parent" ] \
  || { echo "ERROR: ABI destination parent must already exist: $parent" >&2; exit 1; }
cd -P "$parent" || { echo "ERROR: cannot enter ABI staging parent: $parent" >&2; exit 1; }
held_parent=$(physical_pwd)
[ "$held_parent" = "$parent" ] \
  || { echo "ERROR: ABI staging parent changed before extraction: $parent" >&2; exit 1; }

staging_name=

valid_staging_name() {
  case "$1" in
    .abis-staging.?*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    */*) return 1 ;;
  esac
}

cleanup_staging() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$staging_name" ]; then
    if valid_staging_name "$staging_name"; then
      rm -rf "./$staging_name" || true
    else
      echo "ERROR: refusing unsafe ABI staging cleanup: $staging_name" >&2
      [ "$status" -ne 0 ] || status=1
    fi
  fi
  exit "$status"
}

exit_for_signal() {
  local status=$1
  trap - HUP INT TERM
  exit "$status"
}

trap cleanup_staging EXIT
trap 'exit_for_signal 129' HUP
trap 'exit_for_signal 130' INT
trap 'exit_for_signal 143' TERM

CONTRACTS=(
  "BondingCurve|BondingCurve.sol/BondingCurve.json"
  "CreatorFeeProcessor|CreatorFeeProcessor.sol/CreatorFeeProcessor.json"
  "CreatorFeeVault|CreatorFeeVault.sol/CreatorFeeVault.json"
  "YachaRouter|YachaRouter.sol/YachaRouter.json"
  "Lens|Lens.sol/Lens.json"
  "LPManager|LPManager.sol/LPManager.json"
  "ProtocolManager|ProtocolManager.sol/ProtocolManager.json"
  "QuoterV2|QuoterV2.sol/QuoterV2.json"
  "Token|Token.sol/Token.json"
  "TokenRegistry|TokenRegistry.sol/TokenRegistry.json"
  "UniswapV3Factory|UniswapV3Factory.sol/UniswapV3Factory.json"
  "V3LiquidityActor|V3LiquidityActor.sol/V3LiquidityActor.json"
  "V3PoolDeployer|V3PoolDeployer.sol/V3PoolDeployer.json"
  "V3SwapAdapter|V3SwapAdapter.sol/V3SwapAdapter.json"
  "VaultRegistry|VaultRegistry.sol/VaultRegistry.json"
)

echo "Building current Foundry artifacts..."
(cd -P "$ROOT_RESOLVED" && forge build)
staging_name=$(mktemp -d '.abis-staging.XXXXXX')
valid_staging_name "$staging_name" \
  || { echo "ERROR: invalid ABI staging directory: $staging_name" >&2; exit 1; }

captured_abis=()
captured_index=0
for entry in "${CONTRACTS[@]}"; do
  name=${entry%%|*}
  relative_artifact=${entry#*|}
  artifact="$OUT/$relative_artifact"
  generated="./$staging_name/$name.json"
  [ -f "$artifact" ] || { echo "ERROR: required artifact not found: $artifact" >&2; exit 1; }
  jq -e '.abi | type == "array"' "$artifact" >/dev/null || { echo "ERROR: invalid artifact ABI: $artifact" >&2; exit 1; }
  jq '.abi' "$artifact" > "$generated"
  jq -e 'type == "array"' "$generated" >/dev/null
  [ -f "$generated" ] && [ ! -L "$generated" ] \
    || { echo "ERROR: invalid staged ABI entry: $held_parent/$staging_name/$name.json" >&2; exit 1; }
  captured_abis[$captured_index]=$(cat "$generated")
  captured_index=$((captured_index + 1))
done

mkdir -p "./$dest_name"
(
  parent_before=$(physical_pwd)
  cd -P "./$dest_name" || { echo "ERROR: cannot enter ABI destination: $parent_before/$dest_name" >&2; exit 1; }
  held_dest=$(physical_pwd)
  entered_parent=$(cd -P .. && physical_pwd)
  [ "$entered_parent" = "$parent_before" ] \
    || { echo "ERROR: ABI destination parent changed during extraction: expected $parent_before, got $entered_parent" >&2; exit 1; }
  if [ "$parent_before" = / ]; then
    expected_dest="/$dest_name"
  else
    expected_dest="$parent_before/$dest_name"
  fi
  case "$held_dest" in
    ""|/|"$ROOT_RESOLVED") echo "ERROR: unsafe ABI destination: $held_dest" >&2; exit 1 ;;
  esac
  [ "$held_dest" = "$expected_dest" ] \
    || { echo "ERROR: ABI destination redirected during extraction: $expected_dest" >&2; exit 1; }

  for existing in ./*.json; do
    [ -e "$existing" ] || [ -L "$existing" ] || continue
    if [ ! -L "$existing" ] && [ ! -f "$existing" ]; then
      echo "ERROR: non-regular ABI destination entry: $held_dest/${existing#./}" >&2
      exit 1
    fi
  done

  for existing in ./*.json; do
    [ -e "$existing" ] || [ -L "$existing" ] || continue
    rm -f "$existing"
  done

  captured_index=0
  for entry in "${CONTRACTS[@]}"; do
    name=${entry%%|*}.json
    staged="../$staging_name/$name"
    [ -f "$staged" ] && [ ! -L "$staged" ] \
      || { echo "ERROR: invalid staged ABI entry before install: $held_parent/$staging_name/$name" >&2; exit 1; }
    if [ -e "./$name" ] || [ -L "./$name" ]; then
      echo "ERROR: invalid installed ABI entry: $held_dest/$name" >&2
      exit 1
    fi
    if ! ln -n "$staged" "./$name" 2>/dev/null; then
      echo "ERROR: ABI destination entry appeared during install: $held_dest/$name" >&2
      exit 1
    fi
    [ -f "./$name" ] && [ ! -L "./$name" ] \
      || { echo "ERROR: invalid installed ABI entry: $held_dest/$name" >&2; exit 1; }
    if ! installed_abi=$(cat "./$name"); then
      echo "ERROR: cannot read installed ABI: $held_dest/$name" >&2
      exit 1
    fi
    [ "$installed_abi" = "${captured_abis[$captured_index]}" ] \
      || { echo "ERROR: installed ABI bytes changed during install: $held_dest/$name" >&2; exit 1; }
    captured_index=$((captured_index + 1))
  done
  echo "Done: ${#CONTRACTS[@]}/${#CONTRACTS[@]} canonical ABIs extracted to $held_dest"
)
