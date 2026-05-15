#!/usr/bin/env bash
# unit-bootstrap-claude-backend.sh: bootstrap-claude-backend.sh read/write/clear logic
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
FX="$SD/fixtures"
LIB="$SD/../lib/bootstrap-claude-backend.sh"

PASS=0; FAIL=0; FAILED=()

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1)); echo "  PASS $msg"
  else
    FAIL=$((FAIL+1)); FAILED+=("$msg (got=$got want=$want)"); echo "  FAIL $msg (got=$got want=$want)"
  fi
}

echo "=== bootstrap-claude-backend.sh read/write/clear ==="

TMP=$(mktemp -d)
cp "$FX/prefs-with-mode.json" "$TMP/with.json"
cp "$FX/prefs-without-mode.json" "$TMP/without.json"
cp "$FX/prefs-with-mode-only.json" "$TMP/with-only.json"
trap 'rm -rf "$TMP"' EXIT

# 1. read on prefs that has mode → echo it
out=$(bash "$LIB" read "$TMP/with.json")
assert_eq "$out" "subagent" "read returns existing mode"

# 2. read on prefs without mode → empty
out=$(bash "$LIB" read "$TMP/without.json")
assert_eq "$out" "" "read returns empty when field missing"

# 3. read on prefs with mode but no lang → still returns mode (additive)
out=$(bash "$LIB" read "$TMP/with-only.json")
assert_eq "$out" "teammates" "read works on prefs missing other optional fields"

# 4. write valid mode to prefs without the field
bash "$LIB" write "$TMP/without.json" subagent
out=$(bash "$LIB" read "$TMP/without.json")
assert_eq "$out" "subagent" "write adds field when missing"

# 5. write overwrites existing mode
bash "$LIB" write "$TMP/with.json" subprocess
out=$(bash "$LIB" read "$TMP/with.json")
assert_eq "$out" "subprocess" "write overwrites existing mode"

# 6. write preserves other fields (lang, agents)
lang=$(jq -r '.lang // ""' "$TMP/with.json")
agents=$(jq -r '.agents | length' "$TMP/with.json")
assert_eq "$lang" "zh" "write preserves lang"
assert_eq "$agents" "2" "write preserves agents pool"

# 7. write rejects invalid mode
out=$(bash "$LIB" write "$TMP/with.json" bogus 2>&1)
rc=$?
assert_eq "$rc" "1" "write rejects invalid mode with non-zero exit"

# 8. clear removes the field
bash "$LIB" clear "$TMP/with.json"
out=$(bash "$LIB" read "$TMP/with.json")
assert_eq "$out" "" "clear removes the field"

# 9. clear preserves other fields
lang=$(jq -r '.lang // ""' "$TMP/with.json")
assert_eq "$lang" "zh" "clear preserves lang"

# 10. read on missing file → empty (treats as no-mode)
out=$(bash "$LIB" read "$TMP/does-not-exist.json" 2>/dev/null)
assert_eq "$out" "" "read on missing file returns empty"

# 11. write to missing file → fails (caller must ensure file exists; this is pool's bootstrap job)
out=$(bash "$LIB" write "$TMP/does-not-exist.json" subagent 2>&1)
rc=$?
assert_eq "$rc" "1" "write on missing file fails (pool bootstrap must create prefs.json first)"

echo
echo "================================================"
echo "Result: $PASS passed, $FAIL failed"
echo "================================================"
if [ ${#FAILED[@]} -gt 0 ]; then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
