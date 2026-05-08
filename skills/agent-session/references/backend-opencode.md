# Backend: opencode

opencode is a multi-provider agent CLI (GPT, Claude, Gemini, local models). The driver wraps `oc-task`, a session-managing thin layer commonly bundled with opencode setups.

## Install

opencode CLI:

```bash
npm install -g opencode-ai
# or follow https://opencode.ai/docs/install
```

`oc-task` wrapper: comes from the [opencode skill](https://github.com/michaelcai/skills/tree/main/skills/opencode) (or your own setup). The driver looks for `oc-task` in:

1. `$PATH`
2. `~/workspace/.pai/skills/opencode/bin/oc-task` (PAI default install path)

If neither exists, the driver fails detection.

Verify:

```bash
oc-task --help
```

## Models

The driver does not hardcode any model list and does not pass `--model` to `oc-task spawn`. opencode picks the model entirely on its own — via env vars (`OC_MODEL`, etc.) and its config file.

Pass `--model` on `agent-session spawn` only if you have a custom driver wiring; the default driver currently ignores it for opencode (opencode's model selection happens out-of-band).

To set a default model:

```bash
export OC_MODEL=<your-model-name>
# or configure opencode directly — see https://opencode.ai/docs
```

## Session model

The driver uses `oc-task` daemons:

- `oc-task begin --yolo --cwd <path> --title <name>` starts a daemon and prints `OC_TASK_ID` / `OC_TASK_PORT` env exports
- `oc-task spawn <prompt-file> --agent autoaccept` creates a session within the daemon, prints session UUID
- `oc-task status <sid> --wait` blocks until completion
- `oc-task send <sid> <prompt-file>` sends a follow-up turn
- `oc-task end <oc-task-id>` shuts down the daemon

Each `agent-session spawn` starts its own daemon (per-role); subsequent `send` calls on the same role-id reuse it. `cleanup` calls `oc-task end`.

> Per-role daemon is wasteful but simple. A future optimization could share one daemon across all role-ids in the same `--state-dir`.

## Output format

The driver fetches the latest assistant message via:

```
GET http://127.0.0.1:$OC_TASK_PORT/session/<sid>/message
```

It extracts only `parts[].text` (filters out tool-use, ANSI metadata, etc).

## Permissions

The driver passes `--yolo` and `--agent autoaccept`, which bypasses confirmation prompts. This is intentional for non-interactive backend use. If you want stricter permission scoping, modify the driver to pass `--allow <path>` instead of `--yolo`.

## Configuration

| Var | Effect |
|---|---|
| `OC_MODEL` | Selects the model opencode runs (read by opencode itself, not by the driver) |
| `OC_TASK_CWD` | Override the cwd passed to `oc-task begin` (default: current `cwd`) |

## Limitations

- The driver assumes opencode's HTTP message API stays at `/session/<sid>/message`. If opencode's API shape changes, `_fetch_message` needs updating.
- Daemon-per-role is wasteful for many parallel roles.
- `OC_MODEL` reporting is purely informational — the driver cannot verify the actual model that ran.
