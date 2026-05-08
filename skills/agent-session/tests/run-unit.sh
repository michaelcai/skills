#!/usr/bin/env bash
# Unit tests for agent-session — no real backend required.
# Tests CLI argparse, state utils, error paths, and idempotency.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AS="$SCRIPT_DIR/../bin/agent-session"
TMPDIR_BASE=$(mktemp -d -t agent-session-tests-XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" name="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $name"
    echo "       expected: $expected"
    echo "       actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if echo "$haystack" | grep -q -- "$needle"; then
    echo "  PASS $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $name"
    echo "       expected to contain: $needle"
    echo "       got: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local actual="$1" expected="$2" name="$3"
  if [ "$actual" -eq "$expected" ]; then
    echo "  PASS $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $name (rc=$actual, expected=$expected)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== argparse ==="

# unknown command
"$AS" frobnicate >/dev/null 2>&1
assert_rc $? 2 "unknown command exits 2"

# spawn missing required arg
"$AS" spawn --backend claude >/dev/null 2>&1
assert_rc $? 2 "spawn without --role-id exits 2"

# help
out=$("$AS" --help 2>&1)
assert_contains "$out" "doctor" "help lists doctor"
assert_contains "$out" "spawn" "help lists spawn"
assert_contains "$out" "cleanup" "help lists cleanup"

echo ""
echo "=== doctor ==="

out=$("$AS" doctor 2>&1)
rc=$?
assert_rc $rc 0 "doctor exits 0"
assert_contains "$out" "Detected backends" "doctor prints header"
assert_contains "$out" "Multi-model capability" "doctor prints multi-model verdict"

echo ""
echo "=== list-backends ==="

out=$("$AS" list-backends 2>&1)
rc=$?
assert_rc $rc 0 "list-backends exits 0"

echo ""
echo "=== state utils (via python -c) ==="

python3 - <<PY
import sys, tempfile
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("agent_session", "$SCRIPT_DIR/../bin/agent-session").load_module()
session_dir, read_meta, write_meta, state_root = m.session_dir, m.read_meta, m.write_meta, m.state_root
from pathlib import Path

# Default state root
assert state_root(None) == Path.home() / ".cache" / "agent-session", "default state_root"

# Custom state dir
with tempfile.TemporaryDirectory() as td:
    sd = state_root(td)
    assert sd == Path(td), "custom state_root"

    # read_meta on non-existent → None
    assert read_meta("nope", td) is None, "read_meta returns None for missing"

    # write + read round-trip
    meta = {"backend": "claude", "family": "anthropic", "model": "sonnet",
            "sid": "abc", "round_count": 0, "state": "active"}
    write_meta("test-role", td, meta)
    got = read_meta("test-role", td)
    assert got == meta, f"meta round-trip failed: {got}"

    # session_dir
    assert session_dir("test-role", td) == Path(td) / "test-role", "session_dir composition"

print("PY OK")
PY
rc=$?
assert_rc $rc 0 "state utils round-trip"

echo ""
echo "=== cleanup is idempotent ==="

CLEAN_DIR="$TMPDIR_BASE/clean"
"$AS" cleanup --role-id never-existed --state-dir "$CLEAN_DIR" >/dev/null 2>&1
assert_rc $? 0 "cleanup of missing role exits 0"

mkdir -p "$CLEAN_DIR/keep-me"
"$AS" cleanup --role-id keep-me --state-dir "$CLEAN_DIR" >/dev/null 2>&1
rc=$?
assert_rc $rc 0 "cleanup of dir-without-meta exits 0"
[ ! -d "$CLEAN_DIR/keep-me" ] && echo "  PASS cleanup removes dir" && PASS=$((PASS+1)) || { echo "  FAIL cleanup did not remove dir"; FAIL=$((FAIL+1)); }

echo ""
echo "=== spawn rejects unknown / uninstalled backend ==="

SP_DIR="$TMPDIR_BASE/spawn"
echo "hi" > "$TMPDIR_BASE/p.md"

"$AS" spawn --backend nosuch --role-id r --prompt-file "$TMPDIR_BASE/p.md" --state-dir "$SP_DIR" 2>&1 | grep -q "unknown backend"
assert_rc $? 0 "unknown backend reports 'unknown backend'"

echo ""
echo "=== describe on missing session ==="

"$AS" describe --role-id missing --state-dir "$SP_DIR" >/dev/null 2>&1
assert_rc $? 2 "describe missing session exits 2"

echo ""
echo "=== output on missing session ==="

"$AS" output --role-id missing --state-dir "$SP_DIR" >/dev/null 2>&1
assert_rc $? 2 "output missing session exits 2"

echo ""
echo "=== send on missing session ==="

"$AS" send --role-id missing --prompt-file "$TMPDIR_BASE/p.md" --state-dir "$SP_DIR" 2>&1 | grep -q "session not found"
assert_rc $? 0 "send missing session reports 'session not found'"

echo ""
echo "=== status on missing session ==="

out=$("$AS" status --role-id missing --state-dir "$SP_DIR" 2>&1)
assert_eq "$out" "error" "status of missing session prints 'error'"

echo ""
echo "=== spawn duplicate without --force ==="

mkdir -p "$SP_DIR/exists"
echo '{"backend":"claude","state":"active","round_count":1}' > "$SP_DIR/exists/meta.json"
out=$("$AS" spawn --backend claude --role-id exists --prompt-file "$TMPDIR_BASE/p.md" --state-dir "$SP_DIR" 2>&1)
rc=$?
assert_rc $rc 2 "duplicate spawn without --force exits 2"
assert_contains "$out" "already exists" "duplicate spawn says 'already exists'"

echo ""
echo "================================================"
echo "Result: $PASS passed, $FAIL failed"
echo "================================================"
exit $FAIL
