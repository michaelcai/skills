#!/usr/bin/env bash
# run-all.sh: unit + pattern-grep + preset-behavior (no LLM cost).
# For LLM-judge scenarios see scenarios.md (run manually).
# manifest-invariants.sh requires pyyaml and is skipped here when unavailable.
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
rc=0
echo "=== UNIT ==="
bash "$SD/run-unit.sh" || rc=1
echo
echo "=== PATTERN GREP ==="
bash "$SD/pattern-grep.sh" || rc=1
echo
echo "=== PRESET BEHAVIOR ==="
bash "$SD/preset-behavior.sh" || rc=1
exit $rc
