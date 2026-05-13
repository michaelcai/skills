#!/usr/bin/env bash
# run-unit.sh: pure shell logic tests (no tmux, no LLM).
#
# NOTE: this is a narrow entrypoint. For FULL test coverage including
# pattern-grep.sh (SKILL.md text invariants) and preset-behavior.sh
# (fixture-driven scenario tests + C-fix runtime-enforcement assertions),
# run `tests/run-all.sh` and `tests/preset-behavior.sh` instead.
# `tests/manifest-invariants.sh` covers _manifest.yaml — requires pyyaml.
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SD/unit-tests.sh" "$@"
