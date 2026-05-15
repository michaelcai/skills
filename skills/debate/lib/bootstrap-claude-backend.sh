#!/usr/bin/env bash
# bootstrap-claude-backend.sh — read/write/clear claude_backend_mode in prefs.json
#
# Sub-commands:
#   read  <prefs-path>          echo current claude_backend_mode value
#                                 (empty string if field is null or missing,
#                                  empty string if prefs file is missing)
#   write <prefs-path> <mode>   set claude_backend_mode = <mode>, atomic
#                                 (validates mode ∈ {subprocess,subagent,teammates};
#                                  fails if prefs file is missing — caller must
#                                  ensure pool bootstrap created it first)
#   clear <prefs-path>          remove claude_backend_mode field, atomic
#                                 (no-op if file missing or field absent)
#
# Exit codes:
#   0  success
#   1  validation failure / missing prefs file (write only) / unknown sub-command
#   2  jq error (malformed prefs)
set -u

validate_mode() {
  case "$1" in
    subprocess|subagent|teammates) return 0 ;;
    *) echo "bootstrap-claude-backend.sh: invalid mode '$1' (expected subprocess|subagent|teammates)" >&2
       return 1 ;;
  esac
}

cmd="${1:-}"
path="${2:-}"

case "$cmd" in
  read)
    [ -z "$path" ] && { echo "usage: $0 read <prefs-path>" >&2; exit 1; }
    [ -f "$path" ] || { echo ""; exit 0; }
    jq -r '.claude_backend_mode // ""' "$path" 2>/dev/null || { echo "bootstrap-claude-backend.sh: malformed prefs at $path" >&2; exit 2; }
    ;;
  write)
    mode="${3:-}"
    [ -z "$path" ] || [ -z "$mode" ] && { echo "usage: $0 write <prefs-path> <mode>" >&2; exit 1; }
    [ -f "$path" ] || { echo "bootstrap-claude-backend.sh: prefs file not found at $path (run pool bootstrap first)" >&2; exit 1; }
    validate_mode "$mode" || exit 1
    tmp=$(mktemp)
    jq --arg m "$mode" '.claude_backend_mode = $m' "$path" > "$tmp" || { rm -f "$tmp"; echo "bootstrap-claude-backend.sh: jq write failed" >&2; exit 2; }
    mv "$tmp" "$path"
    ;;
  clear)
    [ -z "$path" ] && { echo "usage: $0 clear <prefs-path>" >&2; exit 1; }
    [ -f "$path" ] || exit 0
    tmp=$(mktemp)
    jq 'del(.claude_backend_mode)' "$path" > "$tmp" || { rm -f "$tmp"; echo "bootstrap-claude-backend.sh: jq clear failed" >&2; exit 2; }
    mv "$tmp" "$path"
    ;;
  *)
    echo "usage: $0 {read|write|clear} <prefs-path> [<mode>]" >&2
    exit 1
    ;;
esac
