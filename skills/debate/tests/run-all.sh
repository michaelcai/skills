#!/usr/bin/env bash
# run-all.sh: unit + smoke (no LLM cost).
# For LLM-judge scenarios see scenarios.md (run manually).
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
echo "=== UNIT ==="
bash "$SD/run-unit.sh" || exit 1
echo
echo "=== SMOKE ==="
bash "$SD/smoke-suite.sh"
