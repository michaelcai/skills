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
assert_contains "$out" "run" "help lists run"

# --session-id alias works where --role-id is accepted.
out=$(
  "$AS" describe --session-id ghost 2>&1
)
assert_contains "$out" "session not found" "describe accepts --session-id"

# run validates required args and unknown backends.
"$AS" run --prompt-file /tmp/x >/dev/null 2>&1
assert_rc $? 2 "run without --backend exits 2"

out=$("$AS" run --backend frobnicate --prompt-file /tmp/x 2>&1)
rc=$?
assert_rc $rc 2 "run unknown backend exits 2"
assert_contains "$out" "unknown backend" "run unknown backend names it"

if command -v claude >/dev/null 2>&1; then
  out=$("$AS" run --backend claude --prompt-file "$TMPDIR_BASE/p.md" --cwd "$TMPDIR_BASE/missing-cwd" 2>&1)
  rc=$?
  assert_rc $rc 2 "run with missing cwd exits 2"
  assert_contains "$out" "cwd does not exist" "run with missing cwd has clear error"
  if echo "$out" | grep -q "Traceback"; then
    echo "  FAIL run with missing cwd does not show traceback"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS run with missing cwd does not show traceback"
    PASS=$((PASS + 1))
  fi
fi

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

# ============================================================
# tldr verb
# ============================================================
echo ""
echo "Test: tldr verb (7 fixture-based cases)"

TLDR_FIXTURE_DIR="$SCRIPT_DIR/fixtures"
TLDR_DIR="$TMPDIR_BASE/tldr"
mkdir -p "$TLDR_DIR"

# Helper: set up a fake session with a given fixture as r0 output, round_count=1
setup_tldr_session() {
  local role="$1" fixture="$2"
  local d="$TLDR_DIR/$role/output"
  mkdir -p "$d"
  cp "$TLDR_FIXTURE_DIR/$fixture" "$d/r0.txt"
  cat > "$TLDR_DIR/$role/meta.json" <<EOF
{"role_id": "$role", "backend": "claude", "model": null, "round_count": 1, "state": "active"}
EOF
}

# Case 1: standard format → tldr_text non-null, stance == "hold"
setup_tldr_session "tldr1" "tldr-standard.txt"
out=$("$AS" tldr --role-id tldr1 --state-dir "$TLDR_DIR")
assert_eq "$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["stance"])')" "hold" "tldr standard: stance=hold"
assert_eq "$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("yes" if d["tldr_text"] and "canonical" in d["tldr_text"] else "no")')" "yes" "tldr standard: tldr_text contains 'canonical'"

# Case 2: multiline TL;DR preserves internal newlines, trims edges
setup_tldr_session "tldr2" "tldr-multiline.txt"
out=$("$AS" tldr --role-id tldr2 --state-dir "$TLDR_DIR")
assert_eq "$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["stance"])')" "concede" "tldr multiline: stance=concede"
assert_eq "$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["tldr_text"].count("\n"))')" "2" "tldr multiline: 3-line body has 2 internal newlines"

# Case 3: no stance tag → stance == null
setup_tldr_session "tldr3" "tldr-no-stance.txt"
out=$("$AS" tldr --role-id tldr3 --state-dir "$TLDR_DIR")
assert_eq "$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["stance"] is None)')" "True" "tldr no-stance: stance is null"

# Case 4: no TL;DR section → tldr_text == null, stance found mid-text
setup_tldr_session "tldr4" "tldr-no-section.txt"
out=$("$AS" tldr --role-id tldr4 --state-dir "$TLDR_DIR")
rc=$?
assert_rc $rc 0 "tldr no-section: exit 0 (silent-failure observability)"
assert_eq "$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["tldr_text"] is None)')" "True" "tldr no-section: tldr_text is null"
assert_eq "$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["stance"])')" "add" "tldr no-section: stance still detected mid-text"

# Case 5: empty output → exit 2 with error
setup_tldr_session "tldr5" "tldr-empty.txt"
out=$("$AS" tldr --role-id tldr5 --state-dir "$TLDR_DIR" 2>&1 >/dev/null)
rc=$?
assert_rc $rc 2 "tldr empty: exit 2"
assert_contains "$out" "empty output" "tldr empty: stderr says 'empty output'"

# Case 6: invalid stance value → stance == null (whitelist enforced)
setup_tldr_session "tldr6" "tldr-invalid-stance.txt"
out=$("$AS" tldr --role-id tldr6 --state-dir "$TLDR_DIR")
assert_eq "$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["stance"] is None)')" "True" "tldr invalid stance: stance is null (not 'maybe')"

# Case 7: session not found
out=$("$AS" tldr --role-id ghost --state-dir "$TLDR_DIR" 2>&1 >/dev/null)
rc=$?
assert_rc $rc 2 "tldr ghost: exit 2"
assert_contains "$out" "session not found" "tldr ghost: stderr says 'session not found'"

echo ""
echo "================================================"
echo "Result: $PASS passed, $FAIL failed"
echo "================================================"
exit $FAIL
