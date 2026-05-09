#!/usr/bin/env bash
# smoke-suite.sh: integration of the SKILL.md tmux + tee + sed flow,
# using a fake `claude -p` to avoid LLM cost. Real tmux is used.
# Usage: bash tests/smoke-suite.sh [test_name_filter]
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

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "  SKIP: missing dependency: $1" >&2
    return 2
  }
}

# Each test gets a fresh DEBATE_DIR / DEBATE_TMUX / DEBATE_ID.
new_debate_env() {
  export DEBATE_ID="t$(date +%s%N | md5sum | head -c3)"
  export DEBATE_DIR="/tmp/debate-${DEBATE_ID}"
  export DEBATE_TMUX="debate-${DEBATE_ID}"
  rm -rf "$DEBATE_DIR"
  mkdir -p "$DEBATE_DIR"
  cp "$FX/shared-context.md" "$DEBATE_DIR/shared-context.md"
  cp "$FX/role-a-r1.md" "$DEBATE_DIR/role-a-r1.md"
  # Pre-canned "agent reply" — substitutes claude -p / oc-task spawn output.
  cp "$FX/role-a-r1.txt" "$DEBATE_DIR/role-a-r1-canned.txt"
}

cleanup_debate_env() {
  tmux kill-session -t "$DEBATE_TMUX" 2>/dev/null || true
  # Keep DEBATE_DIR for inspection on failure; CI-clean would `rm -rf` it.
}

# -------------------------------------------------------------------
# 1. tmux + tee + sed end-to-end with a fake claude.
#    This validates the actual SKILL.md round-1 pipeline shape, minus the LLM.
# -------------------------------------------------------------------

test_smoke_round1_pipeline_with_fake_claude() {
  require tmux || return 2
  new_debate_env
  trap cleanup_debate_env RETURN

  # Fake claude: reads stdin (the concatenated prompt), echos the canned reply.
  # We embed it in the tmux command line via a shell function; tmux runs bash,
  # so we pass the function through `bash -c`.
  tmux new-session -d -s "$DEBATE_TMUX" -x 200 -y 50 -n agents

  # Build the same command structure SKILL.md uses, replacing `claude -p ...`
  # with `cat $DEBATE_DIR/role-a-r1-canned.txt` to avoid network/cost.
  tmux send-keys -t "$DEBATE_TMUX:agents.0" \
    "cat $DEBATE_DIR/shared-context.md $DEBATE_DIR/role-a-r1.md > $DEBATE_DIR/role-a-r1-prompt.tmp && cat $DEBATE_DIR/role-a-r1-canned.txt | tee $DEBATE_DIR/role-a-r1.txt && tmux wait-for -S ${DEBATE_ID}-role-a-r1" Enter

  # Wait for the role to "finish"
  tmux wait-for "${DEBATE_ID}-role-a-r1" || { echo "  wait-for never signaled"; return 1; }

  # The canned output must be in the file
  [ -f "$DEBATE_DIR/role-a-r1.txt" ] || { echo "  output file not created"; return 1; }
  grep -q "Redis Pub/Sub does not guarantee" "$DEBATE_DIR/role-a-r1.txt" \
    || { echo "  output content missing"; return 1; }

  # The prompt assembly happened (cat shared + spec)
  [ -f "$DEBATE_DIR/role-a-r1-prompt.tmp" ] || { echo "  prompt not assembled"; return 1; }
  grep -q "Original proposal" "$DEBATE_DIR/role-a-r1-prompt.tmp" || return 1
  grep -q "Your role" "$DEBATE_DIR/role-a-r1-prompt.tmp" || return 1

  # TL;DR extraction works on the live output (the orchestrator's bread and butter)
  local tldr
  tldr=$(sed -n '/^## TL;DR/,/^## /p' "$DEBATE_DIR/role-a-r1.txt" | sed '$d')
  [[ "$tldr" == *"Streams + consumer group"* ]] || { echo "  TL;DR extraction broke"; return 1; }
  [[ "$tldr" != *"src/notify/redis_bus.py"* ]] || { echo "  TL;DR leaked into Argument"; return 1; }
}

# -------------------------------------------------------------------
# 2. cleanup is idempotent — Step 5 in SKILL.md must work twice.
# -------------------------------------------------------------------

test_smoke_cleanup_idempotent() {
  require tmux || return 2
  new_debate_env

  tmux new-session -d -s "$DEBATE_TMUX" -x 80 -y 24

  # First cleanup — kills the session
  tmux kill-session -t "$DEBATE_TMUX" 2>/dev/null
  tmux has-session -t "$DEBATE_TMUX" 2>/dev/null \
    && { echo "  session still alive after cleanup"; return 1; }

  # Second cleanup — must not error
  tmux kill-session -t "$DEBATE_TMUX" 2>/dev/null
  # Exit code is non-zero (no such session), but our cleanup uses `|| true`.
  # Reproduce that pattern here:
  tmux kill-session -t "$DEBATE_TMUX" 2>/dev/null || true
}

# -------------------------------------------------------------------
# 3. Empty/unset DEBATE_TMUX must NOT silently target the current session.
#    The SKILL.md guard requires `: "${DEBATE_TMUX:?...}"`.
# -------------------------------------------------------------------

test_smoke_unset_tmux_var_aborts() {
  # Simulate the guard from SKILL.md 2.4 — must abort instead of operating
  # on a fallback target.
  local out rc
  out=$(bash -c '
    set -eu
    unset DEBATE_TMUX
    : "${DEBATE_TMUX:?DEBATE_TMUX must be set}"
    echo "should not reach here"
  ' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "  guard did not fire"; return 1; }
  [[ "$out" == *"DEBATE_TMUX must be set"* ]] || { echo "  unexpected error: $out"; return 1; }
}

# -------------------------------------------------------------------
# 4. multi-instance isolation — two debate IDs must not collide.
# -------------------------------------------------------------------

test_smoke_multi_instance_isolation() {
  require tmux || return 2
  local id1 id2 dir1 dir2 sess1 sess2
  id1="t$(date +%s%N | md5sum | head -c3)"
  sleep 0.01
  id2="t$(date +%s%N | md5sum | head -c3)"
  [ "$id1" != "$id2" ] || { echo "  IDs collided: $id1"; return 1; }

  dir1="/tmp/debate-${id1}"; dir2="/tmp/debate-${id2}"
  sess1="debate-${id1}"; sess2="debate-${id2}"
  mkdir -p "$dir1" "$dir2"
  trap "rm -rf $dir1 $dir2; tmux kill-session -t $sess1 2>/dev/null; tmux kill-session -t $sess2 2>/dev/null" RETURN

  tmux new-session -d -s "$sess1" -x 80 -y 24
  tmux new-session -d -s "$sess2" -x 80 -y 24

  # Both sessions must be alive simultaneously
  tmux has-session -t "$sess1" 2>/dev/null || { echo "  $sess1 not alive"; return 1; }
  tmux has-session -t "$sess2" 2>/dev/null || { echo "  $sess2 not alive"; return 1; }

  # Killing one must not affect the other
  tmux kill-session -t "$sess1"
  tmux has-session -t "$sess2" 2>/dev/null || { echo "  $sess2 died with $sess1"; return 1; }
}

# -------------------------------------------------------------------
# MAIN
# -------------------------------------------------------------------

FILTER=${1:-}
SKIPPED=0
for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then continue; fi
  echo "=== $t ==="
  "$t"
  rc=$?
  if [ $rc -eq 0 ]; then
    PASS=$((PASS+1)); echo "  PASS"
  elif [ $rc -eq 2 ]; then
    SKIPPED=$((SKIPPED+1)); echo "  SKIPPED"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$t"); echo "  FAIL"
  fi
done
echo
echo "Result: $PASS passed, $FAIL failed, $SKIPPED skipped"
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
