#!/usr/bin/env bash
# run-unit.sh: pure shell logic tests (no tmux, no LLM).
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SD/unit-tests.sh" "$@"
