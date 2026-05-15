#!/usr/bin/env bash
# detect-claude-backend.sh — recommend claude backend mode for debate
#
# Inputs (priority order, first match wins):
#   1. DEBATE_CLAUDE_BACKEND_FLAG env  (set by debate skill from --claude-backend arg)
#   2. DEBATE_CLAUDE_BACKEND env        (user/script preset)
#   3. claude.ai auth + CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 → teammates
#   4. claude.ai auth (any subscription) → subagent
#   5. otherwise → subprocess
#
# Usage:
#   detect-claude-backend.sh                       # reads `claude auth status` live
#   detect-claude-backend.sh /path/to/auth.json    # reads fixture
#
# Always echoes exactly one of: subprocess | subagent | teammates
set -u

# 1. Explicit flag override (highest priority)
if [ -n "${DEBATE_CLAUDE_BACKEND_FLAG:-}" ]; then
  echo "$DEBATE_CLAUDE_BACKEND_FLAG"
  exit 0
fi

# 2. Env preset
if [ -n "${DEBATE_CLAUDE_BACKEND:-}" ]; then
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

if [ "$logged_in" = "true" ] && [ "$auth_method" = "claude.ai" ]; then
  if [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" = "1" ]; then
    echo "teammates"
    exit 0
  fi
  echo "subagent"
  exit 0
fi

echo "subprocess"
