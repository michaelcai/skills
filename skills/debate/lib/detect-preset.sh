#!/usr/bin/env bash
# detect-preset.sh — classify challenge text → recommended preset.
#
# Usage: ./detect-preset.sh "<challenge text>"
#   Prints one line: <preset>:<keyword-matched-or-default>
#   e.g. "deliberation:该不该" or "persuasion:default"
#
# Exit code: 0 always (heuristic, never fails).

set -eu

challenge="${1:?usage: detect-preset.sh <challenge text>}"

# Deliberation indicators (CJK + English). One match wins.
# These signal: trade-off, multi-option choice, stakeholder conflict.
declare -a deliberation_keywords=(
  # Chinese
  "该不该"
  "应不应该"
  "做不做"
  "划算吗"
  "值得吗"
  "权衡"
  "trade-off"
  "tradeoff"
  # English (multi-option choice)
  " or stay"
  " or do nothing"
  " worth doing"
  " should we "
  " is it worth "
  " weigh "
  # CJK choice patterns
  "选.*还是"
  ".*还是.*"  # weaker — placed last; specific patterns above take precedence
)

for kw in "${deliberation_keywords[@]}"; do
  if echo " $challenge " | grep -qiE -- "$kw"; then
    echo "deliberation:${kw}"
    exit 0
  fi
done

echo "persuasion:default"
exit 0
