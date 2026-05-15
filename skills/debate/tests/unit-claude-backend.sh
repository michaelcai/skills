#!/usr/bin/env bash
# unit-claude-backend.sh: detect-claude-backend.sh mode recommendation logic
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
FX="$SD/fixtures"
LIB="$SD/../lib/detect-claude-backend.sh"

PASS=0; FAIL=0; FAILED=()

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1)); echo "  PASS $msg"
  else
    FAIL=$((FAIL+1)); FAILED+=("$msg (got=$got want=$want)"); echo "  FAIL $msg (got=$got want=$want)"
  fi
}

echo "=== detect-claude-backend mode recommendation ==="

# Scenario 1: no auth → subprocess
out=$(unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS DEBATE_CLAUDE_BACKEND; bash "$LIB" "$FX/auth-no-login.json")
assert_eq "$out" "subprocess" "no-login → subprocess"

# Scenario 2: api key auth → subprocess (no subscription benefit)
out=$(unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS DEBATE_CLAUDE_BACKEND; bash "$LIB" "$FX/auth-api-key.json")
assert_eq "$out" "subprocess" "api-key auth → subprocess"

# Scenario 3: Pro subscription, no teams flag → subagent
out=$(unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS DEBATE_CLAUDE_BACKEND; bash "$LIB" "$FX/auth-pro-no-teams.json")
assert_eq "$out" "subagent" "pro sub, no teams flag → subagent"

# Scenario 4: Max subscription + teams flag → teammates
out=$(env -u DEBATE_CLAUDE_BACKEND CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
      bash "$LIB" "$FX/auth-max-with-teams.json")
assert_eq "$out" "teammates" "max sub + teams flag → teammates"

# Scenario 5: env var override wins
out=$(DEBATE_CLAUDE_BACKEND=subprocess CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 bash "$LIB" "$FX/auth-max-with-teams.json")
assert_eq "$out" "subprocess" "DEBATE_CLAUDE_BACKEND env wins over autodetect"

# Scenario 6: --claude-backend arg wins (passed via env DEBATE_CLAUDE_BACKEND_FLAG)
out=$(DEBATE_CLAUDE_BACKEND_FLAG=teammates DEBATE_CLAUDE_BACKEND=subprocess bash "$LIB" "$FX/auth-no-login.json")
assert_eq "$out" "teammates" "--claude-backend flag wins even over env"

# Scenario 7: invalid env override value rejected with non-zero exit
out=$(DEBATE_CLAUDE_BACKEND=bogus bash "$LIB" "$FX/auth-pro-no-teams.json" 2>&1)
rc=$?
assert_eq "$rc" "1" "invalid env value rejected with non-zero exit"

# Scenario 8: invalid flag value rejected with non-zero exit
out=$(DEBATE_CLAUDE_BACKEND_FLAG=typo bash "$LIB" "$FX/auth-no-login.json" 2>&1)
rc=$?
assert_eq "$rc" "1" "invalid flag value rejected with non-zero exit"

# Scenario 9: claude.ai login but no subscriptionType → subprocess (conservative)
out=$(unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS DEBATE_CLAUDE_BACKEND; bash "$LIB" "$FX/auth-claudeai-no-sub.json")
assert_eq "$out" "subprocess" "claude.ai login without subscriptionType → subprocess (conservative)"

echo
echo "================================================"
echo "Result: $PASS passed, $FAIL failed"
echo "================================================"
if [ ${#FAILED[@]} -gt 0 ]; then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
