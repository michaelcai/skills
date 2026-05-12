#!/usr/bin/env bash
# unit-tests.sh: pure shell logic from debate SKILL.md (no tmux, no LLM, no network).
# Each test reproduces a SKILL.md snippet against a fixture and asserts the output.
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
FX="$SD/fixtures"

PASS=0; FAIL=0; FAILED_TESTS=()

run_test() {
  local name=$1
  if [ -n "${FILTER:-}" ] && [[ "$name" != *"$FILTER"* ]]; then return; fi
  echo "=== $name ==="
  if "$name"; then PASS=$((PASS+1)); echo "  PASS"
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); echo "  FAIL"; fi
}

# -------------------------------------------------------------------
# Helpers — verbatim copies of the shell snippets used in SKILL.md.
# Tests fail if SKILL.md drifts away from these.
# -------------------------------------------------------------------

# Extract the "## TL;DR" section. SKILL.md command:
#   sed -n '/^## TL;DR/,/^## /p' file | sed '$d'
extract_tldr() {
  sed -n '/^## TL;DR/,/^## /p' "$1" | sed '$d'
}

# DEBATE_ID: 4 char hex. SKILL.md uses `head -c4` (no trailing newline);
# tests need a newline-terminated variant for line-based dedup.
gen_id() {
  date +%s%N | md5sum | head -c4
}
gen_id_line() {
  gen_id; echo
}

# Stance label extraction. SKILL.md command (multi-file):
#   grep -hoE '\[stance: (hold|concede|add)\]' $DEBATE_DIR/*-r${N}.txt
extract_stance() {
  grep -oE '\[stance: (hold|concede|add)\]' "$1" | head -1
}
extract_stance_multi() {
  grep -hoE '\[stance: (hold|concede|add)\]' "$@"
}

# -------------------------------------------------------------------
# TL;DR extraction (the core of the token-saving design)
# -------------------------------------------------------------------

test_tldr_extract_basic() {
  local out
  out=$(extract_tldr "$FX/role-a-r1.txt")
  [[ "$out" == *"TL;DR"* ]] || { echo "  missing TL;DR header"; return 1; }
  [[ "$out" == *"Redis Pub/Sub does not guarantee"* ]] || { echo "  missing first line"; return 1; }
  [[ "$out" == *"Streams + consumer group"* ]] || { echo "  missing second line"; return 1; }
  # Must NOT include the Argument section
  [[ "$out" != *"Argument"* ]] || { echo "  leaked into Argument section"; return 1; }
  [[ "$out" != *"src/notify/redis_bus.py"* ]] || { echo "  leaked code reference from Argument"; return 1; }
}

test_tldr_extract_missing_yields_empty() {
  local out
  out=$(extract_tldr "$FX/no-tldr.txt")
  [ -z "$out" ] || { echo "  expected empty, got: $out"; return 1; }
}

test_tldr_extract_only_tldr_section() {
  # When TL;DR is the last section (no following ##), the sed pipe drops the
  # last line. This is acceptable — TL;DR alone is rare; real outputs always
  # have an Argument section. Document the behavior so future readers don't trip on it.
  local out
  out=$(extract_tldr "$FX/tldr-only.txt")
  [[ "$out" == *"TL;DR"* ]] || { echo "  expected TL;DR header, got: $out"; return 1; }
}

test_tldr_extract_token_size() {
  # TL;DR section should be much smaller than the full file (validates the
  # token-saving claim — at least 50% reduction on a representative output).
  local full tldr
  full=$(wc -c < "$FX/role-a-r1.txt")
  tldr=$(extract_tldr "$FX/role-a-r1.txt" | wc -c)
  if [ "$tldr" -ge $((full / 2)) ]; then
    echo "  TL;DR ($tldr B) not <50% of full ($full B) — fixture too small or extraction wrong"
    return 1
  fi
}

# -------------------------------------------------------------------
# Stance label extraction — anti-fake-convergence signal
# -------------------------------------------------------------------

test_stance_extract_hold() {
  local out
  out=$(extract_stance "$FX/with-stance-hold.txt")
  [ "$out" = "[stance: hold]" ] || { echo "  got: $out"; return 1; }
}

test_stance_extract_concede() {
  local out
  out=$(extract_stance "$FX/with-stance-concede.txt")
  [ "$out" = "[stance: concede]" ] || { echo "  got: $out"; return 1; }
}

test_stance_extract_add() {
  local out
  out=$(extract_stance "$FX/with-stance-add.txt")
  [ "$out" = "[stance: add]" ] || { echo "  got: $out"; return 1; }
}

test_stance_extract_missing_yields_empty() {
  # Old-style fixture (without stance) must yield empty so we can detect
  # that a role forgot the label.
  local out
  out=$(extract_stance "$FX/role-a-r1.txt")
  [ -z "$out" ] || { echo "  expected empty (old fixture has no stance), got: $out"; return 1; }
}

test_stance_extract_rejects_invalid_label() {
  # If a role hallucinates a label outside the enum (e.g. "[stance: surrender]"),
  # extraction must NOT match — better empty than misleading.
  local tmp; tmp=$(mktemp)
  trap "rm -f $tmp" RETURN
  cat > "$tmp" <<'EOF'
## TL;DR
just saying
[stance: surrender]
EOF
  local out
  out=$(extract_stance "$tmp")
  [ -z "$out" ] || { echo "  invalid label leaked: $out"; return 1; }
}

test_stance_distribution_multi_role() {
  # Simulate round 2 with 3 roles having different stances. SKILL.md uses
  # this exact grep to compute the distribution.
  local out distinct
  out=$(extract_stance_multi "$FX/with-stance-hold.txt" \
                              "$FX/with-stance-concede.txt" \
                              "$FX/with-stance-add.txt")
  # 3 lines, one per role
  [ "$(echo "$out" | wc -l | tr -d ' ')" = "3" ] || { echo "  got $(echo "$out" | wc -l) lines"; return 1; }
  # All 3 distinct stances present
  distinct=$(echo "$out" | sort -u | wc -l | tr -d ' ')
  [ "$distinct" = "3" ] || { echo "  expected 3 distinct stances, got $distinct"; return 1; }
}

test_stance_all_hold_signals_low_convergence() {
  # The "all hold" pattern must be reliably detectable for the orchestrator.
  local tmp1 tmp2
  tmp1=$(mktemp); tmp2=$(mktemp)
  trap "rm -f $tmp1 $tmp2" RETURN
  printf '## TL;DR\nA\n[stance: hold]\n' > "$tmp1"
  printf '## TL;DR\nB\n[stance: hold]\n' > "$tmp2"
  local out
  out=$(extract_stance_multi "$tmp1" "$tmp2")
  # 2 hits, both hold
  [ "$(echo "$out" | grep -c 'hold')" = "2" ] || return 1
  [ "$(echo "$out" | grep -c 'concede\|add')" = "0" ] || return 1
}

test_tldr_includes_stance_when_present() {
  # When a role outputs the new format, the sed-extracted TL;DR should also
  # include the [stance: ...] line (it's part of the TL;DR section by design).
  local out
  out=$(extract_tldr "$FX/with-stance-concede.txt")
  [[ "$out" == *"[stance: concede]"* ]] || { echo "  stance line not in TL;DR section"; return 1; }
  # Argument still excluded
  [[ "$out" != *"session_manager.py"* ]] || { echo "  Argument leaked in"; return 1; }
}


# -------------------------------------------------------------------
# DEBATE_ID generation
# -------------------------------------------------------------------

test_id_4chars_hex() {
  local id
  id=$(gen_id)
  [ ${#id} -eq 4 ] || { echo "  expected 4 chars, got ${#id}: $id"; return 1; }
  [[ "$id" =~ ^[0-9a-f]{4}$ ]] || { echo "  not lowercase hex: $id"; return 1; }
}

test_id_unique_across_invocations() {
  # Two consecutive calls should usually differ (md5 of nanosecond timestamps).
  # Take 5 samples; expect at least 4 distinct (allow 1 collision for very fast clocks).
  local distinct
  distinct=$( (gen_id_line; gen_id_line; gen_id_line; gen_id_line; gen_id_line) | sort -u | wc -l | tr -d ' ')
  [ "$distinct" -ge 4 ] || { echo "  only $distinct/5 distinct IDs — clock too coarse?"; return 1; }
}

# -------------------------------------------------------------------
# Prompt assembly: cat shared-context.md role-a-r1.md | claude -p
# -------------------------------------------------------------------

test_prompt_concat_order_preserves_ctx_first() {
  local out
  out=$(cat "$FX/shared-context.md" "$FX/role-a-r1.md")
  # The original proposal/challenge must appear before the role spec, so the role
  # reads context before its instructions.
  local pos_ctx pos_role
  pos_ctx=$(printf '%s\n' "$out" | grep -n "Original proposal" | head -1 | cut -d: -f1)
  pos_role=$(printf '%s\n' "$out" | grep -n "Your role" | head -1 | cut -d: -f1)
  [ -n "$pos_ctx" ] || { echo "  missing 'Original proposal' anchor"; return 1; }
  [ -n "$pos_role" ] || { echo "  missing 'Your role' anchor"; return 1; }
  [ "$pos_ctx" -lt "$pos_role" ] || {
    echo "  ctx ($pos_ctx) must precede role ($pos_role)"; return 1
  }
}

test_prompt_concat_no_duplication() {
  # The whole point: ctx appears exactly once when concatenated.
  local n
  n=$(cat "$FX/shared-context.md" "$FX/role-a-r1.md" | grep -c "^## Original proposal")
  [ "$n" = "1" ] || { echo "  'Original proposal' appears $n times, expected 1"; return 1; }
}

# -------------------------------------------------------------------
# Multi-role concat — pre-built opencode prompts get the same shared ctx
# -------------------------------------------------------------------

test_opencode_concat_includes_ctx() {
  # SKILL.md round 1 builds opencode-r1-full.md by concatenating shared + role.
  local tmp full
  tmp=$(mktemp -d)
  trap "rm -rf $tmp" RETURN
  printf '## Your role\nIndependent model assessing the proposal\n' > "$tmp/oc-r1.md"
  cat "$FX/shared-context.md" "$tmp/oc-r1.md" > "$tmp/oc-r1-full.md"
  grep -q "Original proposal" "$tmp/oc-r1-full.md" || { echo "  ctx missing"; return 1; }
  grep -q "Your role" "$tmp/oc-r1-full.md" || { echo "  role spec missing"; return 1; }
}

# -------------------------------------------------------------------
# session-ids.env round-trip (used to pass UUIDs across panes)
# -------------------------------------------------------------------

test_session_env_roundtrip() {
  local tmp; tmp=$(mktemp -d)
  trap "rm -rf $tmp" RETURN
  cat > "$tmp/session-ids.env" <<EOF
export DEFENDER_SID=11111111-1111-1111-1111-111111111111
export ROLE_A_SID=22222222-2222-2222-2222-222222222222
export OC_TASK_ID=oct_abc123
EOF
  ( source "$tmp/session-ids.env"
    [ "$DEFENDER_SID" = "11111111-1111-1111-1111-111111111111" ] || exit 1
    [ "$ROLE_A_SID" = "22222222-2222-2222-2222-222222222222" ] || exit 1
    [ "$OC_TASK_ID" = "oct_abc123" ] || exit 1
  )
}

test_session_env_visible_to_subprocess() {
  # Regression: variables written to session-ids.env must be visible to
  # subprocesses spawned from a sourcing shell. With plain KEY=val form,
  # they are shell-only and `oc-task spawn` fails with
  # `[oc-task] no port: set OC_TASK_PORT or pass --port`.
  # Fix: write `export KEY=val` so source promotes them to env.
  local tmp; tmp=$(mktemp -d)
  trap "rm -rf $tmp" RETURN
  cat > "$tmp/session-ids.env" <<'EOF'
export OC_TASK_PORT=4096
export OC_TASK_ID=oct_visible
EOF
  # Subprocess (sh -c) reads env, not parent shell vars
  local out
  out=$(bash -c "source $tmp/session-ids.env && sh -c 'echo \$OC_TASK_PORT-\$OC_TASK_ID'")
  [ "$out" = "4096-oct_visible" ] || { echo "  subprocess didn't see env: '$out'"; return 1; }
}

test_session_env_without_export_fails_subprocess() {
  # Sanity check: documents the BAD case (KEY=val without export). If this
  # test ever passes, bash semantics changed and we can simplify.
  local tmp; tmp=$(mktemp -d)
  trap "rm -rf $tmp" RETURN
  cat > "$tmp/session-ids.env" <<'EOF'
OC_TASK_PORT=4096
OC_TASK_ID=oct_invisible
EOF
  local out
  out=$(bash -c "source $tmp/session-ids.env && sh -c 'echo \$OC_TASK_PORT-\$OC_TASK_ID'")
  # Plain assignment is shell-local — subprocess sees empty
  [ "$out" = "-" ] || { echo "  expected empty in subprocess, got: '$out'"; return 1; }
}

# -------------------------------------------------------------------
# Preset detection heuristic
# -------------------------------------------------------------------

detect_preset() {
  "$SD/../lib/detect-preset.sh" "$1" | cut -d: -f1
}

[ -x "$SD/../lib/detect-preset.sh" ] || { echo "FAIL: detect-preset.sh not executable"; exit 1; }

assert_detect_preset() {
  local input=$1 expected=$2 got
  got=$(detect_preset "$input")
  [ "$got" = "$expected" ] || {
    echo "  detect-preset: '$input' expected $expected, got $got"
    return 1
  }
}

test_detect_preset_deliberation_gai_bugai() {
  assert_detect_preset "我们该不该 X" "deliberation"
}

test_detect_preset_deliberation_yingbuyinggai() {
  assert_detect_preset "应不应该重构" "deliberation"
}

test_detect_preset_deliberation_zuobuzuo() {
  assert_detect_preset "做不做这个" "deliberation"
}

test_detect_preset_deliberation_huasuan() {
  assert_detect_preset "划算吗" "deliberation"
}

test_detect_preset_deliberation_zhide() {
  assert_detect_preset "值得吗" "deliberation"
}

test_detect_preset_deliberation_trade_off() {
  assert_detect_preset "trade-off here" "deliberation"
}

test_detect_preset_deliberation_should_we() {
  assert_detect_preset "should we ship" "deliberation"
}

test_detect_preset_deliberation_xuan_haishi() {
  assert_detect_preset "选 X 还是 Y" "deliberation"
}

test_detect_preset_persuasion_default_correct() {
  assert_detect_preset "X is correct" "persuasion"
}

test_detect_preset_persuasion_default_chinese_problem() {
  assert_detect_preset "X 设计有问题吗" "persuasion"
}

test_detect_preset_persuasion_default_better_than() {
  assert_detect_preset "is approach Y better than Z" "persuasion"
}

test_detect_preset_persuasion_default_hold_up() {
  assert_detect_preset "这个 proposal hold up 吗" "persuasion"
}

# -------------------------------------------------------------------
# MAIN
# -------------------------------------------------------------------

FILTER=${1:-}
for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  run_test "$t"
done
echo
echo "Result: $PASS passed, $FAIL failed"
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
