# Live debate viewer (cmux + Textual TUI)

**When to use**: you want to watch the debate unfold in a side pane with markdown-rendered output, instead of waiting for each checkpoint.

**Prerequisites**:

- `cmux` (terminal multiplexer with split-pane control: `cmux new-split`, `cmux send`)
- `uv` (Python package manager) and Python ≥3.10
- A viewer script that polls `$SESSIONS_DIR/<role-id>/output/r*.txt` and renders to a Textual TUI

> **Note**: this skill repo does not (yet) bundle a viewer script. The `debate-viewer.py` referenced below is part of [PAI](https://github.com/your-username/pai) tooling. To use this enhancement standalone, copy or adapt your own polling-and-rendering script.

## Conceptual flow

1. Before spawning roles, open a right split-pane via cmux
2. Inside that pane, activate a Python venv and run the viewer script, pointing it at `$SESSIONS_DIR`
3. The viewer polls `output/rN.txt` files; each new write shows up in the pane
4. After the debate concludes, close the split-pane

## Detect cmux

```bash
command -v cmux >/dev/null && cmux identify >/dev/null 2>&1 \
  || { echo "cmux not available; skipping live viewer"; exit 1; }
```

## Open the pane (call exactly once)

`cmux new-split right` outputs `OK surface:N workspace:N` (**not JSON**). Parse with `grep -oE 'surface:[0-9]+'`. **On parse failure, do NOT retry `new-split`** — that creates extra panes. Use `cmux list-panes` to locate the surface manually.

```bash
bash -c '
set -e
RAW=$(cmux new-split right 2>&1)
VIEWER_SURFACE=$(echo "$RAW" | grep -oE "surface:[0-9]+" | head -1)
if [ -z "$VIEWER_SURFACE" ]; then
  echo "[debate] failed to parse new-split output, raw: $RAW" >&2
  echo "[debate] confirm latest surface via cmux list-panes; do NOT call new-split again" >&2
  exit 1
fi
echo "VIEWER_SURFACE=$VIEWER_SURFACE" > "'"$DEBATE_DIR"'/viewer.env"
'
```

## Viewer venv (first use)

```bash
VIEWER_VENV="$HOME/.cache/agent-session/debate-viewer-venv"
if [ ! -d "$VIEWER_VENV" ]; then
  uv venv "$VIEWER_VENV" --python 3.12
  source "$VIEWER_VENV/bin/activate"
  uv pip install textual rich
fi
```

## Launch the viewer in the pane

Adapt the viewer-script path to your environment.

```bash
VIEWER_SCRIPT="$HOME/path/to/debate-viewer.py"  # adjust to your install

bash -c '
source "'"$DEBATE_DIR"'/viewer.env"
cmux send --surface "$VIEWER_SURFACE" \
  "source '"$VIEWER_VENV"'/bin/activate.fish && python '"$VIEWER_SCRIPT"' '"$SESSIONS_DIR"'"
cmux send-key --surface "$VIEWER_SURFACE" enter
'
```

The viewer polls `$SESSIONS_DIR/<role-id>/output/r*.txt`; spawn / send writes there, viewer picks up.

## Cleanup additions

In step 5:

```bash
source "$DEBATE_DIR/viewer.env" 2>/dev/null
if [ -n "${VIEWER_SURFACE:-}" ]; then
  cmux close-surface --surface "$VIEWER_SURFACE" 2>/dev/null || true
fi
```

## Fallback

If cmux is unavailable, the main agent already prints a complete checkpoint summary every 3 rounds — this is enough to follow the debate. The live viewer is a quality-of-life enhancement, not a requirement.

## Adapting the viewer script

A working viewer needs to:

1. Take `$SESSIONS_DIR` as argv[1]
2. List subdirs (each is a role-id)
3. Watch `output/r*.txt` files (e.g. via `watchdog` or a poll loop)
4. Render each role's latest message as markdown grouped by round

The simplest implementation is `<100` lines with Textual; build to taste. A reference implementation is in PAI under `bin/debate-viewer.py` — copy and adapt.
