#!/bin/bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
EXTRACTOR="$ROOT/script/extract-abis.sh"
if ! grep -q 'ABI_DEST' "$EXTRACTOR"; then
  echo "FAIL: extractor does not support isolated ABI_DEST output" >&2
  exit 1
fi

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/canonical-abis-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
REAL_JQ=$(command -v jq)
REAL_RM=$(command -v rm)
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "$1" = rev-parse ] && [ "$2" = --show-toplevel ]; then' \
  '  printf '\''%s\n'\'' "$FAKE_REPO"' \
  '  exit 0' \
  'fi' \
  'exit 2' > "$FAKE_BIN/git"
printf '%s\n' \
  '#!/bin/bash' \
  ': > "$FORGE_MARKER"' \
  'if [ -n "${FORGE_PAUSE_MARKER:-}" ]; then' \
  '  : > "$FORGE_PAUSE_MARKER"' \
  '  while [ ! -e "$FORGE_RELEASE_MARKER" ]; do sleep 0.05; done' \
  'fi' \
  '[ "${FORGE_FAIL:-0}" != 1 ] || exit 97' \
  'exit 0' > "$FAKE_BIN/forge"
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/forge"

RACE_BIN="$TEST_ROOT/race-bin"
mkdir -p "$RACE_BIN"
printf '%s\n' \
  '#!/bin/bash' \
  'inject=0' \
  'for arg in "$@"; do' \
  '  [ "$arg" != "./zz-publish-trigger.json" ] || inject=1' \
  'done' \
  '"$REAL_RM" "$@"' \
  'if [ "$inject" = 1 ] && [ "${INJECT_FIFO_AFTER_UNLINK:-0}" = 1 ]; then' \
  '  mkfifo ./BondingCurve.json' \
  'elif [ "$inject" = 1 ] && [ "${INJECT_DIRECTORY_AFTER_UNLINK:-0}" = 1 ]; then' \
  '  mkdir ./BondingCurve.json' \
  'fi' > "$RACE_BIN/rm"
chmod +x "$RACE_BIN/rm"

EXPECTED=(
  BondingCurve CreatorFeeProcessor CreatorFeeVault GiwaRouter LPManager ProtocolManager QuoterV2
  Token TokenRegistry UniswapV3Factory V3LiquidityActor V3PoolDeployer V3SwapAdapter VaultRegistry
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_case() {
  label=$1
  CASE_ROOT="$TEST_ROOT/$label"
  CASE_REPO="$CASE_ROOT/repo"
  CASE_DEST="$CASE_ROOT/dest"
  CASE_MARKER="$CASE_ROOT/forge-called"
  mkdir -p "$CASE_REPO/out"
  for name in "${EXPECTED[@]}"; do
    artifact_dir="$CASE_REPO/out/$name.sol"
    mkdir -p "$artifact_dir"
    printf '{"abi":[{"type":"function","name":"%s","inputs":[],"outputs":[]}]}\n' "$name" \
      > "$artifact_dir/$name.json"
  done
}

invoke_extractor() {
  FAKE_REPO="$CASE_REPO" \
    FORGE_MARKER="$CASE_MARKER" \
    PATH="$FAKE_BIN:$PATH" \
    ABI_DEST="$CASE_DEST" \
    "$EXTRACTOR"
}

invoke_default_extractor() (
  unset ABI_DEST
  FAKE_REPO="$CASE_REPO" \
    FORGE_MARKER="$CASE_MARKER" \
    PATH="$FAKE_BIN:$PATH" \
    "$EXTRACTOR"
)

snapshot_dest() {
  snapshot_dir=$1
  for snapshot_path in "$snapshot_dir"/*.json; do
    [ -e "$snapshot_path" ] || [ -L "$snapshot_path" ] || continue
    snapshot_name=${snapshot_path##*/}
    if [ -L "$snapshot_path" ]; then
      printf 'L %s %s\n' "$snapshot_name" "$(readlink "$snapshot_path")"
    elif [ -f "$snapshot_path" ]; then
      printf 'F %s %s\n' "$snapshot_name" "$(shasum -a 256 "$snapshot_path" | awk '{print $1}')"
    elif [ -d "$snapshot_path" ]; then
      printf 'D %s\n' "$snapshot_name"
    elif [ -p "$snapshot_path" ]; then
      printf 'P %s\n' "$snapshot_name"
    else
      printf 'O %s\n' "$snapshot_name"
    fi
  done | LC_ALL=C sort
}

seed_preserved_output() {
  mkdir -p "$CASE_DEST"
  printf 'sentinel bytes must survive\n' > "$CASE_DEST/sentinel.json"
  ln -s "$CASE_ROOT/never-created.json" "$CASE_DEST/stale-link.json"
}

assert_preserved() {
  before=$1
  after=$(snapshot_dest "$CASE_DEST")
  [ "$before" = "$after" ] || fail "$2 changed destination output"
}

assert_exact_output() {
  output_dir=$1
  entries=("$output_dir"/*.json)
  [ "${#entries[@]}" -eq "${#EXPECTED[@]}" ] \
    || fail "expected ${#EXPECTED[@]} JSON entries, found ${#entries[@]}"
  for entry in "${entries[@]}"; do
    [ -f "$entry" ] || fail "non-regular output entry: $entry"
    [ ! -L "$entry" ] || fail "symlink output entry: $entry"
  done
  for name in "${EXPECTED[@]}"; do
    generated="$output_dir/$name.json"
    artifact="$CASE_REPO/out/$name.sol/$name.json"
    [ -f "$generated" ] || fail "missing $name.json"
    diff -u <(jq -S '.abi' "$artifact") <(jq -S '.' "$generated")
  done
}

assert_rejected_before_build() {
  unsafe_dest=$1
  label=$2
  rm -f "$CASE_MARKER"
  if FAKE_REPO="$CASE_REPO" \
    FORGE_MARKER="$CASE_MARKER" \
    FORGE_FAIL=1 \
    PATH="$FAKE_BIN:$PATH" \
    ABI_DEST="$unsafe_dest" \
    "$EXTRACTOR" >/dev/null 2>&1; then
    fail "extractor accepted unsafe ABI_DEST ($label)"
  fi
  [ ! -e "$CASE_MARKER" ] || fail "extractor built before rejecting unsafe ABI_DEST ($label)"
}

make_case missing-destination-parent
missing_parent="$CASE_ROOT/missing-parent"
CASE_DEST="$missing_parent/child/abis"
assert_rejected_before_build "$CASE_DEST" missing-parent
[ ! -e "$missing_parent" ] || fail "missing destination parent suffix was created"

make_case prebuild-parent-rename
rename_parent="$TEST_ROOT/prebuild-destination-parent"
moved_rename_parent="$TEST_ROOT/prebuild-destination-parent-moved"
CASE_DEST="$rename_parent/abis"
mkdir -p "$rename_parent"
pause_marker="$CASE_ROOT/forge-paused"
release_marker="$CASE_ROOT/forge-release"
rename_log="$CASE_ROOT/extractor.log"
FAKE_REPO="$CASE_REPO" \
  FORGE_MARKER="$CASE_MARKER" \
  FORGE_PAUSE_MARKER="$pause_marker" \
  FORGE_RELEASE_MARKER="$release_marker" \
  PATH="$FAKE_BIN:$PATH" \
  ABI_DEST="$CASE_DEST" \
  "$EXTRACTOR" >"$rename_log" 2>&1 &
extractor_pid=$!
attempt=0
while [ ! -e "$pause_marker" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail "timed out waiting for paused fake forge build"
  sleep 0.05
done
mv "$rename_parent" "$moved_rename_parent"
mkdir -p "$rename_parent"
printf 'replacement parent guard\n' > "$rename_parent/cleanup-guard"
: > "$release_marker"
set +e
wait "$extractor_pid"
rename_status=$?
set -e
if [ "$rename_status" -ne 0 ]; then
  cat "$rename_log" >&2
  fail "pre-build renamed-parent extraction exited with status $rename_status"
fi
[ -d "$moved_rename_parent/abis" ] \
  || fail "pre-build rename did not publish into the held original parent"
assert_exact_output "$moved_rename_parent/abis"
replacement_json_count=$(find "$rename_parent" -type f -name '*.json' | wc -l | tr -d ' ')
[ "$replacement_json_count" -eq 0 ] \
  || fail "pre-build rename wrote JSON through the replacement parent pathname"
[ "$(cat "$rename_parent/cleanup-guard")" = 'replacement parent guard' ] \
  || fail "pre-build rename changed the replacement parent guard"

make_case unsafe-destinations
mkdir -p "$CASE_REPO/existing"
assert_rejected_before_build "" empty
assert_rejected_before_build / root
assert_rejected_before_build "$CASE_REPO/existing/.." root-alias
ln -s "$CASE_REPO" "$CASE_ROOT/root-link"
assert_rejected_before_build "$CASE_ROOT/root-link" root-symlink

make_case successful-replacement
CASE_DEST="$CASE_REPO/abis"
EXTERNAL_DIR="$CASE_ROOT/external"
mkdir -p "$CASE_DEST" "$EXTERNAL_DIR"
printf 'stale regular file\n' > "$CASE_DEST/Stale.json"
ln -s "$EXTERNAL_DIR" "$CASE_DEST/BondingCurve.json"
ln -s "$EXTERNAL_DIR/never-created.json" "$CASE_DEST/StaleLink.json"
invoke_default_extractor >/dev/null
[ -e "$CASE_MARKER" ] || fail "successful extraction did not run forge build"
external_count=$(find "$EXTERNAL_DIR" -mindepth 1 | wc -l | tr -d ' ')
[ "$external_count" -eq 0 ] || fail "extractor wrote outside ABI_DEST through a symlink"
assert_exact_output "$CASE_DEST"
first_hashes=$(for file in "$CASE_DEST"/*.json; do shasum -a 256 "$file"; done | LC_ALL=C sort)
printf 'another stale file\n' > "$CASE_DEST/Stale.json"
ln -s "$EXTERNAL_DIR/never-created-again.json" "$CASE_DEST/StaleLink.json"
invoke_extractor >/dev/null
assert_exact_output "$CASE_DEST"
second_hashes=$(for file in "$CASE_DEST"/*.json; do shasum -a 256 "$file"; done | LC_ALL=C sort)
[ "$first_hashes" = "$second_hashes" ] || fail "repeated extraction changed canonical output"
external_count=$(find "$EXTERNAL_DIR" -mindepth 1 | wc -l | tr -d ' ')
[ "$external_count" -eq 0 ] || fail "repeat extraction wrote outside ABI_DEST"

make_case publish-fifo-injection
mkdir -p "$CASE_DEST"
printf 'publication race trigger\n' > "$CASE_DEST/zz-publish-trigger.json"
EXTERNAL_DIR="$CASE_ROOT/external"
mkdir -p "$EXTERNAL_DIR"
publish_log="$CASE_ROOT/extractor.log"
FAKE_REPO="$CASE_REPO" \
  FORGE_MARKER="$CASE_MARKER" \
  REAL_RM="$REAL_RM" \
  INJECT_FIFO_AFTER_UNLINK=1 \
  PATH="$RACE_BIN:$FAKE_BIN:$PATH" \
  ABI_DEST="$CASE_DEST" \
  "$EXTRACTOR" >"$publish_log" 2>&1 &
extractor_pid=$!
timed_out=0
attempt=0
while kill -0 "$extractor_pid" 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    timed_out=1
    kill -TERM "$extractor_pid" 2>/dev/null || true
    sleep 0.1
    kill -KILL "$extractor_pid" 2>/dev/null || true
    break
  fi
  sleep 0.05
done
set +e
wait "$extractor_pid"
publish_status=$?
set -e
if [ "$timed_out" -ne 0 ]; then
  cat "$publish_log" >&2
  fail "FIFO publication collision caused extractor to hang"
fi
[ "$publish_status" -ne 0 ] || fail "extractor accepted injected FIFO publication collision"
grep -q 'invalid installed ABI entry' "$publish_log" \
  || { cat "$publish_log" >&2; fail "FIFO publication collision lacked a clear failure"; }
[ -p "$CASE_DEST/BondingCurve.json" ] || fail "FIFO injection did not remain inside ABI_DEST"
external_count=$(find "$EXTERNAL_DIR" -mindepth 1 | wc -l | tr -d ' ')
[ "$external_count" -eq 0 ] || fail "FIFO publication collision wrote outside ABI_DEST"

make_case publish-directory-injection
mkdir -p "$CASE_DEST"
printf 'publication race trigger\n' > "$CASE_DEST/zz-publish-trigger.json"
EXTERNAL_DIR="$CASE_ROOT/external"
mkdir -p "$EXTERNAL_DIR"
publish_log="$CASE_ROOT/extractor.log"
set +e
FAKE_REPO="$CASE_REPO" \
  FORGE_MARKER="$CASE_MARKER" \
  REAL_RM="$REAL_RM" \
  INJECT_DIRECTORY_AFTER_UNLINK=1 \
  PATH="$RACE_BIN:$FAKE_BIN:$PATH" \
  ABI_DEST="$CASE_DEST" \
  "$EXTRACTOR" >"$publish_log" 2>&1
publish_status=$?
set -e
[ "$publish_status" -ne 0 ] || fail "extractor accepted injected directory publication collision"
grep -q 'invalid installed ABI entry' "$publish_log" \
  || { cat "$publish_log" >&2; fail "directory publication collision lacked a clear validation failure"; }
[ -d "$CASE_DEST/BondingCurve.json" ] || fail "directory injection did not remain inside ABI_DEST"
directory_entry_count=$(find "$CASE_DEST/BondingCurve.json" -mindepth 1 | wc -l | tr -d ' ')
[ "$directory_entry_count" -eq 0 ] || fail "extractor published inside an injected directory collision"
external_count=$(find "$EXTERNAL_DIR" -mindepth 1 | wc -l | tr -d ' ')
[ "$external_count" -eq 0 ] || fail "directory publication collision wrote outside ABI_DEST"

make_case build-failure
seed_preserved_output
before=$(snapshot_dest "$CASE_DEST")
if FORGE_FAIL=1 invoke_extractor >/dev/null 2>&1; then
  fail "extractor accepted forge build failure"
fi
[ -e "$CASE_MARKER" ] || fail "build-failure case did not invoke forge"
assert_preserved "$before" "forge build failure"

make_case missing-artifact
seed_preserved_output
rm -f "$CASE_REPO/out/VaultRegistry.sol/VaultRegistry.json"
before=$(snapshot_dest "$CASE_DEST")
if invoke_extractor >/dev/null 2>&1; then
  fail "extractor accepted a missing artifact"
fi
assert_preserved "$before" "missing artifact failure"

make_case invalid-abi
seed_preserved_output
printf '{"abi":{}}\n' > "$CASE_REPO/out/LPManager.sol/LPManager.json"
before=$(snapshot_dest "$CASE_DEST")
if invoke_extractor >/dev/null 2>&1; then
  fail "extractor accepted an invalid ABI"
fi
assert_preserved "$before" "invalid ABI failure"

make_case non-regular-entry
seed_preserved_output
mkfifo "$CASE_DEST/blocked.json"
before=$(snapshot_dest "$CASE_DEST")
if invoke_extractor >/dev/null 2>&1; then
  fail "extractor accepted a non-regular JSON entry"
fi
assert_preserved "$before" "non-regular entry failure"

SIGNAL_BIN="$TEST_ROOT/signal-bin"
mkdir -p "$SIGNAL_BIN"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "${JQ_FAIL_GENERATED:-0}" = 1 ] && [ "$1" = -e ] && [ "$2" = '\''type == "array"'\'' ]; then' \
  '  exit 88' \
  'fi' \
  'if [ -n "${JQ_PAUSE_MARKER:-}" ] && [ ! -e "$JQ_PAUSE_MARKER" ]; then' \
  '  : > "$JQ_PAUSE_MARKER"' \
  '  if [ -n "${JQ_RELEASE_MARKER:-}" ]; then' \
  '    while [ ! -e "$JQ_RELEASE_MARKER" ]; do sleep 0.05; done' \
  '  else' \
  '    sleep 1' \
  '  fi' \
  'fi' \
  'exec "$REAL_JQ" "$@"' > "$SIGNAL_BIN/jq"
chmod +x "$SIGNAL_BIN/jq"

make_case generated-validation-failure
seed_preserved_output
before=$(snapshot_dest "$CASE_DEST")
if FAKE_REPO="$CASE_REPO" \
  FORGE_MARKER="$CASE_MARKER" \
  REAL_JQ="$REAL_JQ" \
  JQ_FAIL_GENERATED=1 \
  PATH="$SIGNAL_BIN:$FAKE_BIN:$PATH" \
  ABI_DEST="$CASE_DEST" \
  "$EXTRACTOR" >/dev/null 2>&1; then
  fail "extractor accepted failed generated ABI validation"
fi
assert_preserved "$before" "generated ABI validation failure"

make_case normal-parent-rename
rename_parent="$TEST_ROOT/normal-destination-parent"
moved_rename_parent="$TEST_ROOT/normal-destination-parent-moved"
CASE_DEST="$rename_parent/abis"
mkdir -p "$rename_parent"
pause_marker="$CASE_ROOT/normal-jq-paused"
release_marker="$CASE_ROOT/normal-jq-release"
rename_log="$CASE_ROOT/normal-extractor.log"
FAKE_REPO="$CASE_REPO" \
  FORGE_MARKER="$CASE_MARKER" \
  REAL_JQ="$REAL_JQ" \
  JQ_PAUSE_MARKER="$pause_marker" \
  JQ_RELEASE_MARKER="$release_marker" \
  PATH="$SIGNAL_BIN:$FAKE_BIN:$PATH" \
  ABI_DEST="$CASE_DEST" \
  "$EXTRACTOR" >"$rename_log" 2>&1 &
extractor_pid=$!
attempt=0
while [ ! -e "$pause_marker" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail "timed out waiting for normal staged extraction"
  sleep 0.05
done
staging_count=$(find "$rename_parent" -maxdepth 1 -type d -name '.abis-staging.*' | wc -l | tr -d ' ')
[ "$staging_count" -eq 1 ] || fail "normal paused extraction did not create one staging directory"
mv "$rename_parent" "$moved_rename_parent"
mkdir -p "$rename_parent"
printf 'replacement parent guard\n' > "$rename_parent/cleanup-guard"
: > "$release_marker"
set +e
wait "$extractor_pid"
rename_status=$?
set -e
if [ "$rename_status" -ne 0 ]; then
  cat "$rename_log" >&2
  fail "renamed-parent extraction exited with status $rename_status"
fi
assert_exact_output "$moved_rename_parent/abis"
replacement_json_count=$(find "$rename_parent" -type f -name '*.json' | wc -l | tr -d ' ')
[ "$replacement_json_count" -eq 0 ] || fail "renamed-parent extraction wrote JSON through the replacement pathname"
[ "$(cat "$rename_parent/cleanup-guard")" = 'replacement parent guard' ] \
  || fail "renamed-parent extraction changed the replacement guard"
staging_count=$(find "$moved_rename_parent" -maxdepth 1 -type d -name '.abis-staging.*' | wc -l | tr -d ' ')
[ "$staging_count" -eq 0 ] || fail "normal completion left anchored staging behind"

make_case signal-cleanup
seed_preserved_output
before=$(snapshot_dest "$CASE_DEST")
pause_marker="$TEST_ROOT/anchored-jq-paused"
FAKE_REPO="$CASE_REPO" \
  FORGE_MARKER="$CASE_MARKER" \
  REAL_JQ="$REAL_JQ" \
  JQ_PAUSE_MARKER="$pause_marker" \
  PATH="$SIGNAL_BIN:$FAKE_BIN:$PATH" \
  ABI_DEST="$CASE_DEST" \
  "$EXTRACTOR" >/dev/null 2>&1 &
extractor_pid=$!
attempt=0
while [ ! -e "$pause_marker" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail "timed out waiting for staged extraction"
  sleep 0.05
done
staging_path=$(find "$CASE_ROOT" -maxdepth 1 -type d -name '.abis-staging.*' | head -n 1)
[ -n "$staging_path" ] || fail "paused extraction did not create staging"
staging_name=${staging_path##*/}
moved_case_root="$CASE_ROOT-moved"
mv "$CASE_ROOT" "$moved_case_root"
mkdir -p "$CASE_ROOT/$staging_name"
printf 'replacement path must survive cleanup\n' > "$CASE_ROOT/$staging_name/cleanup-guard"
kill -TERM "$extractor_pid"
set +e
wait "$extractor_pid"
signal_status=$?
set -e
[ "$signal_status" -eq 143 ] || fail "TERM exited with status $signal_status instead of 143"
after=$(snapshot_dest "$moved_case_root/dest")
[ "$before" = "$after" ] || fail "TERM handling changed destination output"
[ -f "$CASE_ROOT/$staging_name/cleanup-guard" ] \
  || fail "cleanup followed the replaced staging-parent pathname"
[ ! -e "$moved_case_root/$staging_name" ] \
  || fail "anchored TERM cleanup left the original staging directory behind"

echo "PASS: canonical ABI extraction"
