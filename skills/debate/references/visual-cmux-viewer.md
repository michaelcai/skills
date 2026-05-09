# Live debate viewer (cmux + Textual TUI)

**When to use**: you want to watch the debate unfold in a side pane with markdown-rendered output, instead of waiting for each every-3-round checkpoint.

**Activation**: set `"view": "cmux"` in `~/.config/agents/debate/prefs.json`. Step 1.5 of the main flow detects this, opens a cmux split, and launches the bundled viewer at `bin/debate-viewer.py` (no extra config). Step 5 cleanup closes the pane.

**Prerequisites**:
- `cmux` (terminal multiplexer with split-pane control: `cmux new-split`, `cmux send`)
- `uv` and Python ≥3.10
- A working cmux session (i.e. you're inside one — `cmux identify` succeeds)

The viewer script (`skills/debate/bin/debate-viewer.py`) is bundled with this skill. It depends on `textual` + `rich`; the activation flow below sets up a venv at `~/.cache/agent-session/debate-viewer-venv` on first use.

## Conceptual flow

1. Step 1.5 sees `prefs.view == "cmux"` and `cmux` + `uv` + Python all available
2. Opens a right split-pane via `cmux new-split right`
3. Inside that pane, activates a Python venv and runs `debate-viewer.py $SESSIONS_DIR`
4. The viewer polls `<sessions-dir>/<role-id>/output/r*.txt` and renders new content as colored markdown panels
5. Step 5 closes the pane and kills the viewer process

## Detect cmux

```bash
command -v cmux >/dev/null && cmux identify >/dev/null 2>&1 \
  || { echo "cmux not available; degrading to no viewer"; }
```

## Open the pane (call exactly once)

`cmux new-split right` outputs `OK surface:N workspace:N` (**not JSON**). Parse with `grep -oE 'surface:[0-9]+'`. **On parse failure, do NOT retry `new-split`** — that creates extra panes. Use `cmux list-panes` to locate the surface manually.

```bash
RAW=$(cmux new-split right 2>&1)
VIEWER_SURFACE=$(echo "$RAW" | grep -oE "surface:[0-9]+" | head -1)
if [ -z "$VIEWER_SURFACE" ]; then
  echo "[debate] failed to parse new-split output, raw: $RAW" >&2
  echo "[debate] confirm latest surface via cmux list-panes; do NOT call new-split again" >&2
  exit 1
fi
echo "VIEWER_SURFACE=$VIEWER_SURFACE" > "$DEBATE_DIR/viewer.env"
```

## First-use venv setup

```bash
VIEWER_VENV="$HOME/.cache/agent-session/debate-viewer-venv"
if [ ! -d "$VIEWER_VENV" ]; then
  uv venv "$VIEWER_VENV" --python 3.12
  uv pip install --python "$VIEWER_VENV/bin/python" textual rich
fi
```

## Launch the viewer in the pane

The viewer is the bundled script — no path adaptation needed:

```bash
VIEWER_SCRIPT="$(dirname "$(realpath "$(command -v agent-session)")")/../../debate/bin/debate-viewer.py"
# Or for non-symlinked installs, hardcode the repo path you cloned to.
# A robust alternative is to look up the script via the skill's known location:
#     ~/.claude/skills/debate/bin/debate-viewer.py
# (works for both Option-1 marketplace + Option-2 manual symlink installs)

cmux send --surface "$VIEWER_SURFACE" \
  "source $VIEWER_VENV/bin/activate.fish; and python $VIEWER_SCRIPT $SESSIONS_DIR"
cmux send-key --surface "$VIEWER_SURFACE" enter
```

The viewer polls `$SESSIONS_DIR/<role-id>/output/r*.txt`; spawn / send writes there, viewer picks up.

## Cleanup additions

In Step 5 (already in the main SKILL.md flow):

```bash
if [ -f "$DEBATE_DIR/viewer.env" ]; then
  source "$DEBATE_DIR/viewer.env"
  [ -n "${VIEWER_SURFACE:-}" ] && cmux close-surface --surface "$VIEWER_SURFACE" 2>/dev/null || true
  pkill -f "debate-viewer.py.*$SESSIONS_DIR" 2>/dev/null || true
fi
```

## Fallback

If cmux / uv / Python is unavailable, Step 1.5 prints `View: off (cmux not found, falling back)` and the debate continues without a viewer — the main agent's every-3-round checkpoint is enough to follow the flow. The live viewer is a quality-of-life enhancement, not a requirement.

## Keybindings

Inside the viewer:

| Key | Action |
|---|---|
| `q` | Quit |
| PgUp / PgDn | Page up/down |
| ↑ / ↓ | Line up/down |
| Home / End | Jump to top/bottom |
| Mouse wheel | Scroll (auto-scroll resumes when you reach bottom) |
