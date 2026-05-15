#!/usr/bin/env bash
# run-unit.sh: pure shell unit tests (no tmux, no LLM, no network).
# Runs unit-tests.sh + unit-claude-backend.sh + unit-bootstrap-claude-backend.sh.
#
# NOTE: this is a focused unit entrypoint. For FULL test coverage including
# pattern-grep.sh (SKILL.md text invariants) and preset-behavior.sh
# (fixture-driven scenario tests + C-fix runtime-enforcement assertions),
# run `tests/run-all.sh` and `tests/preset-behavior.sh` instead.
# `tests/manifest-invariants.sh` covers _manifest.yaml — requires pyyaml.
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
rc=0
bash "$SD/unit-tests.sh" "$@" || rc=1
echo
bash "$SD/unit-claude-backend.sh" || rc=1
echo
bash "$SD/unit-bootstrap-claude-backend.sh" || rc=1
exit $rc
