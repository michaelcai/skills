#!/usr/bin/env bash
# detect-claude-backend.sh — recommend claude backend mode for debate
#
# Inputs (priority order, first match wins):
#   1. DEBATE_CLAUDE_BACKEND_FLAG env  (set by debate skill from --claude-backend arg)
#   2. DEBATE_CLAUDE_BACKEND env        (user/script preset)
#   3. claude.ai auth + subscriptionType in {pro,max} + CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 → teammates
#   4. claude.ai auth + subscriptionType in {pro,max} → subagent
#   5. otherwise (incl. claude.ai login without known subscriptionType) → subprocess
#
# Usage:
#   detect-claude-backend.sh                       # reads `claude auth status` live
#   detect-claude-backend.sh /path/to/auth.json    # reads fixture
#
# Always echoes exactly one of: subprocess | subagent | teammates
# Override values (DEBATE_CLAUDE_BACKEND_FLAG / DEBATE_CLAUDE_BACKEND) are validated
# against the whitelist; an invalid value prints to stderr and exits 1.
set -u

validate_mode() {
  case "$1" in
    subprocess|subagent|teammates) return 0 ;;
    *) echo "detect-claude-backend.sh: invalid mode '$1' (expected subprocess|subagent|teammates)" >&2
       return 1 ;;
  esac
}

# 1. Explicit flag override (highest priority)
if [ -n "${DEBATE_CLAUDE_BACKEND_FLAG:-}" ]; then
  validate_mode "$DEBATE_CLAUDE_BACKEND_FLAG" || exit 1
  echo "$DEBATE_CLAUDE_BACKEND_FLAG"
  exit 0
fi

# 2. Env preset
if [ -n "${DEBATE_CLAUDE_BACKEND:-}" ]; then
  validate_mode "$DEBATE_CLAUDE_BACKEND" || exit 1
  echo "$DEBATE_CLAUDE_BACKEND"
  exit 0
fi

# 3-5. Autodetect from auth
auth_src="${1:-}"
if [ -n "$auth_src" ] && [ -f "$auth_src" ]; then
  auth_json=$(cat "$auth_src")
else
  auth_json=$(claude auth status 2>/dev/null || echo '{}')
fi

auth_method=$(echo "$auth_json" | jq -r '.authMethod // ""' 2>/dev/null)
logged_in=$(echo "$auth_json" | jq -r '.loggedIn // false' 2>/dev/null)
sub_type=$(echo "$auth_json" | jq -r '.subscriptionType // ""' 2>/dev/null)

if [ "$logged_in" = "true" ] && [ "$auth_method" = "claude.ai" ]; then
  case "$sub_type" in
    pro|max)
      if [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" = "1" ]; then
        echo "teammates"
      else
        echo "subagent"
      fi
      exit 0
      ;;
    *)
      # claude.ai login but subscription unknown/free — fall through to subprocess (conservative)
      ;;
  esac
fi

echo "subprocess"
