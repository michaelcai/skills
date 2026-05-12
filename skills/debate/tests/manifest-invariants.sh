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

MODULE_RC=$?
if [ "$MODULE_RC" -ne 0 ]; then
  exit "$MODULE_RC"
fi

# ============================================================
# Preset coherence check
# ============================================================
# For every module declared with preset: X, verify:
# 1. A preset-spec module exists for X (loaded_by: preset-spec)
# 2. The preset spec file declares all 4 primitives in frontmatter:
#    role-topology, stance-contract, checkpoint-policy, output-format
echo ""
echo "=== Preset coherence check ==="

python3 - "$MANIFEST" "$SKILL_DIR" <<'PY2'
import sys, yaml, pathlib

manifest_path, skill_dir = sys.argv[1], pathlib.Path(sys.argv[2])
manifest = yaml.safe_load(open(manifest_path))
modules = manifest["modules"]
errors = []

# Group modules by preset (skip modules without preset field)
by_preset = {}
for m in modules:
    p = m.get("preset")
    if p:
        by_preset.setdefault(p, []).append(m)

required_primitives = {"role-topology", "stance-contract", "checkpoint-policy", "output-format"}

for preset_name, mods in by_preset.items():
    # Find the preset-spec module for this preset
    spec_modules = [m for m in mods if m.get("loaded_by") == "preset-spec"]
    if not spec_modules:
        errors.append(f"preset '{preset_name}': no preset-spec module declared")
        continue
    if len(spec_modules) > 1:
        errors.append(f"preset '{preset_name}': multiple preset-spec modules declared (expected exactly 1)")
        continue

    spec = spec_modules[0]
    spec_path = skill_dir / spec["path"]
    if not spec_path.exists():
        errors.append(f"preset '{preset_name}': spec file {spec_path} not found")
        continue

    content = spec_path.read_text()
    frontmatter = content
    if content.startswith("---\n"):
        parts = content.split("---\n", 2)
        if len(parts) >= 3:
            frontmatter = parts[1]

    # Check each required primitive appears as `<name>:` in the frontmatter region.
    for prim in required_primitives:
        marker = f"{prim}:"
        if marker not in frontmatter:
            errors.append(f"preset '{preset_name}' ({spec_path}): missing primitive declaration '{marker}'")

if errors:
    print("FAIL: preset coherence check failed:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"OK: {len(by_preset)} presets coherent, all 4 primitives declared in each")
PY2

PRESET_RC=$?
if [ "$PRESET_RC" -ne 0 ]; then
  echo ""
  echo "FAIL: preset coherence check returned $PRESET_RC"
  exit 1
fi
