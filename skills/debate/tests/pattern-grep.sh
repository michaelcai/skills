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
# 2026-05-14 root-cause: opencode without --yolo hangs at 0% CPU.
# Red Flag #1 must call this out, and §2.5 must MUST it.
assert_match "不带 .--yolo." "§Red Flags must list 'agent-session spawn/send/run 不带 --yolo' (current root cause)"
assert_match "opencode backend blocks on its interactive permission prompt" "§2.5 MUST must explain opencode-yolo failure mode"
assert_match "ScheduleWakeup 等" "§Red Flags must list 'ScheduleWakeup 等 ...'"
assert_match "fan-out 跨多个 Bash" "§Red Flags must warn against multi-Bash-call fan-out"
assert_match "Bash tool 用默认 timeout" "§Red Flags must warn against using default Bash timeout"

# Inquiry preset assertions (Inquiry SKILL.md sections)
assert_match "##### 2.3-c Inquiry preset" "§2.3-c Inquiry preset assignment section must exist"
assert_match "inquiry\\)      STANCE_WHITELIST=\"supports,refutes,lateral,inconclusive\"" \
    "§2.5 case must set inquiry STANCE_WHITELIST"
assert_match "ACTIVE_ROLES=\\(verifier falsifier triangulator wildcard\\)" \
    "§2.5 case must set inquiry ACTIVE_ROLES"
assert_match "For \\*\\*inquiry\\*\\*:" "Inquiry checkpoint trigger / distribution / conclude blocks must reference preset by name"
assert_match "output-format-inquiry.md" "§2.4 must reference output-format-inquiry.md"

# Discovery preset assertions
assert_match "##### 2.3-d Discovery preset" "§2.3-d Discovery preset assignment section must exist"
assert_match "discovery\\)    STANCE_WHITELIST=\"expand,challenge,connect,converge\"" \
    "§2.5 case must set discovery STANCE_WHITELIST"
assert_match "ACTIVE_ROLES=\\(\"\\\$\\{EXPLORER_SLUGS\\[@\\]\\}\" wildcard\\)" \
    "§2.5 case must set discovery ACTIVE_ROLES (Explorer slugs + wildcard, no Compiler)"
assert_match "For \\*\\*discovery\\*\\*:" "Discovery sections must reference preset by name"
assert_match "output-format-discovery.md" "§2.4 must reference output-format-discovery.md"
assert_match "Discovery introduces a second tag" "After-round step must explain 2-tag stage extraction"
assert_no_match "Compiler recommends" "Compiler must NOT have 'recommends' verb anywhere in SKILL.md"
assert_no_match "Compiler[[:space:]]+chooses" "Compiler must NOT have 'chooses' verb"

# C-fix: runtime enforcement assertions
assert_match "role_stance_whitelist" "After-round must define role_stance_whitelist function (per-role narrowed whitelist)"
assert_match "Per-role stance whitelist \\(Inquiry / Discovery\\)" "§After-round must document per-role whitelist as runtime enforcement"
assert_match "bad-stage-r1" "Discovery stage round-number validation must surface bad-stage-r1 via failed array"
assert_match "bad-source-kind" "Inquiry source-kind closed-set validation must surface bad-source-kind via failed array"
assert_match "Compiler activation \\(Discovery only\\)" "§Checkpoint must document Compiler spawn/send/validate flow"
assert_match "compiler-correction.md" "Compiler reject-output path must emit a correction send"
assert_match "Periodic Compiler checkpoint" "Discovery checkpoint trigger must distinguish periodic vs final"
assert_match "Final Compiler synthesis" "Discovery checkpoint trigger must mention final-synthesis condition"

echo
if [[ $fail -gt 0 ]]; then
  echo "FAILED: $fail check(s)"
  exit 1
fi
echo "OK: all SKILL.md pattern checks pass"
