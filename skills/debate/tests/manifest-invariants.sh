#!/usr/bin/env bash
# manifest-invariants.sh: verify references/_manifest.yaml against its module files.
#
# Soft dependency on pyyaml: if not installed, exits 0 with SKIP message
# (preserves existing zero-dep test infra). Strict CI must install pyyaml.

set -u
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SD/.." && pwd)"
MANIFEST="$SKILL_DIR/references/_manifest.yaml"

if [ ! -f "$MANIFEST" ]; then
  echo "FAIL: manifest not found: $MANIFEST"
  exit 1
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "SKIP: pyyaml not installed. Manifest invariants not verified this run."
  echo "      For full verification, run: pip install pyyaml  (or: uv pip install pyyaml)"
  exit 0
fi

python3 - "$MANIFEST" "$SKILL_DIR" <<'PY'
import sys, yaml, pathlib

manifest_path, skill_dir = sys.argv[1], pathlib.Path(sys.argv[2])
data = yaml.safe_load(open(manifest_path))
fail = 0

for m in data.get("modules", []):
    fp = skill_dir / m["path"]
    if not fp.exists():
        print(f"FAIL [{m['id']}]: file not found: {m['path']}")
        fail += 1
        continue
    text = fp.read_text()
    for inv in m.get("invariants", []):
        kind = inv["kind"]
        if kind == "contains":
            if inv["value"] not in text:
                print(f"FAIL [{m['id']}]: missing required substring {inv['value']!r}")
                fail += 1
        elif kind == "forbidden":
            if inv["value"] in text:
                print(f"FAIL [{m['id']}]: contains forbidden substring {inv['value']!r}")
                fail += 1
        elif kind == "contains_any":
            vs = inv["values"]
            if not any(v in text for v in vs):
                print(f"FAIL [{m['id']}]: contains none of {vs!r}")
                fail += 1
        elif kind == "contains_all":
            missing = [v for v in inv["values"] if v not in text]
            if missing:
                print(f"FAIL [{m['id']}]: missing all-required {missing!r}")
                fail += 1
        else:
            print(f"FAIL [{m['id']}]: unknown invariant kind {kind!r}")
            fail += 1

if fail == 0:
    print(f"OK: {len(data.get('modules', []))} modules verified, all invariants pass")
    sys.exit(0)
else:
    print(f"FAILED: {fail} invariant violations")
    sys.exit(1)
PY
