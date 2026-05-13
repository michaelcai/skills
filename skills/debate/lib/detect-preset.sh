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

# Discovery indicators: open exploration when user doesn't know options/proposal/hypothesis.
declare -a discovery_keywords=(
  # Chinese
  "怎么写"
  "怎么做"
  "如何(写|做|设计|实现|选|安排|处理)"
  "用什么"
  "什么样"
  "不知道(用|选|怎么|该|从哪|该不该|该用|该选)"
  "没想好"
  "想了解"
  # English
  " how should "
  " how do i "
  " what kind of "
  " not sure what "
  " don't know how "
)

for kw in "${discovery_keywords[@]}"; do
  if echo " $challenge " | grep -qiE -- "$kw"; then
    echo "discovery:${kw}"
    exit 0
  fi
done

# Inquiry indicators: hypothesis verification phrasing.
declare -a inquiry_keywords=(
  # Chinese
  "真的.*吗"
  "对吗"
  "是不是"
  "验证"
  "假设.*对"
  "假设.*真"
  "是否成立"
  # English
  " is (this|that|it|the) .* true"
  " does .* hold"
  " verify (the |this |if |whether )"
  " hypothesis "
  " is (this|that|it|the) .* actually "
)

for kw in "${inquiry_keywords[@]}"; do
  if echo " $challenge " | grep -qiE -- "$kw"; then
    echo "inquiry:${kw}"
    exit 0
  fi
done

echo "persuasion:default"
exit 0
