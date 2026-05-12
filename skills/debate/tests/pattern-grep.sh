#!/usr/bin/env bash
# Pattern checks on debate SKILL.md — backstops _manifest.yaml invariants
# with the textual checks expressed as direct grep (faster, no yaml dep).
set -uo pipefail

cd "$(dirname "$0")/.."
SKILL="SKILL.md"
fail=0

assert_no_match() {
  local pat="$1" msg="$2"
  if grep -nE -- "$pat" "$SKILL" >/dev/null 2>&1; then
    echo "FAIL: $msg"
    grep -nE -- "$pat" "$SKILL" | head -5
    fail=$((fail+1))
  else
    echo "PASS: $msg"
  fi
}

assert_match() {
  local pat="$1" msg="$2"
  if ! grep -nE -- "$pat" "$SKILL" >/dev/null 2>&1; then
    echo "FAIL: $msg"
    fail=$((fail+1))
  else
    echo "PASS: $msg"
  fi
}

# Forbidden patterns — match instructional invocations, not warning/documentation mentions.
# ScheduleWakeup( matches an actual function call; warnings say "ScheduleWakeup 等" (no paren).
assert_no_match "ScheduleWakeup\(" "SKILL.md must not instruct invoking ScheduleWakeup"
# run_in_background used as a positive instruction (not preceded by Never/not/嵌套/包).
# Check: the word followed by a backtick-close without a negation on the same line.
# Simpler: check that there's no bare code-fence line `run_in_background` as a command.
assert_no_match "^\s+run_in_background\b" "SKILL.md must not have run_in_background as an executable instruction"
# wait pattern: 'wait "$<word>$<word>"' instructed as executable code.
# §Red Flags shows the bad pattern in prose with 拼接/被 shell context — exclude those lines.
if grep -nE 'wait[[:space:]]+"?\$[a-zA-Z_]+\$[a-zA-Z_]+' "$SKILL" \
    | grep -vE '拼接|被 shell|job not found' >/dev/null 2>&1; then
  echo "FAIL: shell 'wait' must not concatenate two \$vars (use independent quotes)"
  grep -nE 'wait[[:space:]]+"?\$[a-zA-Z_]+\$[a-zA-Z_]+' "$SKILL" \
    | grep -vE '拼接|被 shell|job not found' | head -5
  fail=$((fail+1))
else
  echo "PASS: shell 'wait' must not concatenate two \$vars (use independent quotes)"
fi

# Required patterns (key phrases from §Red Flags + §Reconcile)
assert_match "exit 3" "§Reconcile must reference exit 3"
assert_match "session-not-found" "§Reconcile must reference session-not-found"
assert_match "initial-round" "§Reconcile must reference --initial-round"
assert_match "send fan-out 嵌套" "§Red Flags must list 'send fan-out 嵌套'"
assert_match "ScheduleWakeup 等" "§Red Flags must list 'ScheduleWakeup 等 ...'"

echo
if [[ $fail -gt 0 ]]; then
  echo "FAILED: $fail check(s)"
  exit 1
fi
echo "OK: all SKILL.md pattern checks pass"
