#!/usr/bin/env bash
# preset-behavior.sh — fixture-driven scenario tests for both presets.
# Tests moderator-side post-round shell logic against pre-rendered role outputs.
# No real LLM calls.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AS="$SCRIPT_DIR/../../agent-session/bin/agent-session"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"
TMPDIR_BASE=$(mktemp -d -t debate-preset-behavior-XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

assert_eq() {
  if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"
  else FAIL=$((FAIL+1)); echo "  FAIL $3 (got '$1', expected '$2')"; fi
}

# Helper: stage a fake session from a fixture so tldr verb can read it.
stage_session() {
  local preset="$1" role="$2" state_dir="$3"
  local role_dir="$state_dir/$role"
  mkdir -p "$role_dir/output"
  cp "$FIXTURE_DIR/$preset/round-1-$role.txt" "$role_dir/output/r0.txt"
  cat > "$role_dir/meta.json" <<META
{"role_id":"$role","backend":"claude","model":null,"round_count":1,"state":"active"}
META
}

# ============================================================
# Test 1: Persuasion preset — TL;DR extraction with default whitelist
# ============================================================
echo "Test: persuasion preset — TL;DR + stance extraction"

P_STATE="$TMPDIR_BASE/persuasion"
mkdir -p "$P_STATE"
for role in defender role-a wildcard; do
  stage_session "persuasion" "$role" "$P_STATE"
done

# Without --stance-whitelist (default): hold/concede/add allowed
for role in defender role-a wildcard; do
  expected=$(grep -oE '\[stance: [a-z]+\]' "$FIXTURE_DIR/persuasion/round-1-$role.txt" | head -1 | sed 's/\[stance: //; s/\]//')
  got=$("$AS" tldr --role-id "$role" --state-dir "$P_STATE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stance"])')
  assert_eq "$got" "$expected" "persuasion: $role stance = $expected"
done

# Cross-vocab rejection: same fixtures with deliberation whitelist → all null
for role in defender role-a wildcard; do
  got=$("$AS" tldr --role-id "$role" --state-dir "$P_STATE" --stance-whitelist "prefer,accept,oppose,abstain" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["stance"] is None)')
  assert_eq "$got" "True" "persuasion: $role stance = null under deliberation whitelist"
done

# ============================================================
# Test 2: Deliberation preset — TL;DR + stance extraction
# ============================================================
echo ""
echo "Test: deliberation preset — TL;DR + stance extraction"

D_STATE="$TMPDIR_BASE/deliberation"
mkdir -p "$D_STATE"
for role in stakeholder-a stakeholder-b synthesizer; do
  stage_session "deliberation" "$role" "$D_STATE"
done

# With deliberation whitelist: each stance recognized
for role in stakeholder-a stakeholder-b synthesizer; do
  expected=$(grep -oE '\[stance: [a-z]+\]' "$FIXTURE_DIR/deliberation/round-1-$role.txt" | head -1 | sed 's/\[stance: //; s/\]//')
  got=$("$AS" tldr --role-id "$role" --state-dir "$D_STATE" --stance-whitelist "prefer,accept,oppose,abstain" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["stance"])')
  assert_eq "$got" "$expected" "deliberation: $role stance = $expected"
done

# ============================================================
# Test 3: Mode-mismatch heuristic
# ============================================================
echo ""
echo "Test: mode-mismatch heuristic — detect-preset.sh"

DP="$SCRIPT_DIR/../lib/detect-preset.sh"

# Deliberation indicators
got=$("$DP" "我们该不该把 X 拆成两个 service" | cut -d: -f1)
assert_eq "$got" "deliberation" "deliberation: 该不该 trigger"

got=$("$DP" "X or Y, which one is worth doing" | cut -d: -f1)
assert_eq "$got" "deliberation" "deliberation: worth doing trigger"

got=$("$DP" "should we deprecate the old API" | cut -d: -f1)
assert_eq "$got" "deliberation" "deliberation: 'should we' trigger"

# Persuasion (default) — no indicator
got=$("$DP" "is approach X correct" | cut -d: -f1)
assert_eq "$got" "persuasion" "persuasion: correctness question"

# Inquiry preset detection
echo ""
echo "Test: inquiry preset detection — detect-preset.sh"

got=$("$DP" "$(cat "$FIXTURE_DIR/inquiry-hypothesis-en.txt")" | cut -d: -f1)
assert_eq "$got" "inquiry" "inquiry: english hypothesis fixture"

got=$("$DP" "$(cat "$FIXTURE_DIR/inquiry-hypothesis-cn.txt")" | cut -d: -f1)
assert_eq "$got" "inquiry" "inquiry: chinese hypothesis fixture"

got=$("$DP" "X 这个设计是不是有问题" | cut -d: -f1)
assert_eq "$got" "inquiry" "inquiry: 是不是 trigger"

# Discovery preset detection
echo ""
echo "Test: discovery preset detection — detect-preset.sh"

got=$("$DP" "$(cat "$FIXTURE_DIR/discovery-open-cn.txt")" | cut -d: -f1)
assert_eq "$got" "discovery" "discovery: chinese open-question fixture"

got=$("$DP" "$(cat "$FIXTURE_DIR/discovery-open-en.txt")" | cut -d: -f1)
assert_eq "$got" "discovery" "discovery: english open-question fixture"

# C-fix: ordering — "我不知道该不该 X" should now route to discovery, not deliberation
got=$("$DP" "我不知道该不该用 X" | cut -d: -f1)
assert_eq "$got" "discovery" "C-fix: 我不知道该不该 → discovery (was deliberation pre-reorder)"

# ============================================================
# Test 4: C-fix — per-role narrowed whitelist catches mutex violations
# ============================================================
# Stage a fake Verifier session whose output emits stance=refutes (illegal —
# Verifier's narrowed whitelist is {supports,inconclusive}). Without the
# narrowed whitelist, tldr would return stance="refutes" (preset-wide set
# accepts it); with the narrowed whitelist, stance must be null (format drift).
echo ""
echo "Test: C-fix — per-role narrowed whitelist enforces mutex"

V_STATE="$TMPDIR_BASE/inquiry-violation"
mkdir -p "$V_STATE/verifier/output"
cp "$FIXTURE_DIR/violation-verifier-refutes.txt" "$V_STATE/verifier/output/r0.txt"
cat > "$V_STATE/verifier/meta.json" <<META
{"role_id":"verifier","backend":"claude","model":null,"round_count":1,"state":"active"}
META

# Preset-wide whitelist: stance=refutes IS accepted (this is the bug C-fix closes)
got=$("$AS" tldr --role-id verifier --state-dir "$V_STATE" \
      --stance-whitelist "supports,refutes,lateral,inconclusive" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["stance"])')
assert_eq "$got" "refutes" "preset-wide whitelist would let Verifier:refutes through (the gap C-fix closes)"

# Narrowed whitelist (Verifier mutex): stance must be null (format drift signal)
got=$("$AS" tldr --role-id verifier --state-dir "$V_STATE" \
      --stance-whitelist "supports,inconclusive" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["stance"] is None)')
assert_eq "$got" "True" "C-fix: narrowed whitelist {supports,inconclusive} → stance=null for refutes"

# Same shape for Discovery Explorer emitting stance=challenge (illegal — Explorer set is {expand,connect,converge})
E_STATE="$TMPDIR_BASE/discovery-violation"
mkdir -p "$E_STATE/explorer-a/output"
cp "$FIXTURE_DIR/violation-explorer-challenge.txt" "$E_STATE/explorer-a/output/r0.txt"
cat > "$E_STATE/explorer-a/meta.json" <<META
{"role_id":"explorer-a","backend":"claude","model":null,"round_count":1,"state":"active"}
META

got=$("$AS" tldr --role-id explorer-a --state-dir "$E_STATE" \
      --stance-whitelist "expand,connect,converge" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["stance"] is None)')
assert_eq "$got" "True" "C-fix: Explorer narrowed whitelist {expand,connect,converge} → stance=null for challenge"

# Wildcard's wider whitelist DOES accept `challenge` (only Explorers are blocked)
got=$("$AS" tldr --role-id explorer-a --state-dir "$E_STATE" \
      --stance-whitelist "expand,challenge,connect,converge" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["stance"])')
assert_eq "$got" "challenge" "C-fix: Wildcard's full whitelist accepts challenge (sanity check)"

# ============================================================
# Test 5: C-fix — runtime validation patterns documented in SKILL.md
# ============================================================
# Belt-and-suspenders: the runtime stage-validator + source-kind-validator
# are documented as shell snippets that downstream LLMs will execute.
# Cover their presence via SKILL.md pattern grep (the assertions live in
# pattern-grep.sh; here we test the underlying string/format the validator
# would emit so a future refactor doesn't silently drop them).
echo ""
echo "Test: C-fix — Discovery stage round-number validation snippet"

SKILL_FILE="$SCRIPT_DIR/../SKILL.md"
got=$(grep -c '"\$r:bad-stage-r1' "$SKILL_FILE")
assert_eq "$got" "1" "Discovery R1 stage violator emits 'bad-stage-r1'"

got=$(grep -c 'bad-stage-r\${N}' "$SKILL_FILE")
assert_eq "$got" "1" "Discovery R2+ stage violator emits 'bad-stage-r\${N}'"

got=$(grep -c '"\$r:bad-source-kind' "$SKILL_FILE")
assert_eq "$got" "1" "Inquiry bad-source-kind validator emits 'bad-source-kind'"

# Compiler runtime guard against Recommendation/Best Option/Ranking
got=$(grep -cE '\^## Recommendation\|\^## Best Option\|\^## Ranking' "$SKILL_FILE")
[ "$got" -ge 1 ] && got=1 || got=0
assert_eq "$got" "1" "Compiler output validator greps for forbidden sections (Recommendation/Best Option/Ranking)"

echo ""
echo "================================================"
echo "Result: $PASS passed, $FAIL failed"
echo "================================================"
exit $FAIL
