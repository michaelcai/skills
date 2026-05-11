# Backend: opencode

[opencode](https://opencode.ai) is a multi-provider agent CLI (GPT, Claude, Gemini, Groq, local models). The driver wraps the native `opencode run` command — no extra wrappers required.

## Install

```bash
curl -fsSL https://opencode.ai/install | bash
# or: npm install -g opencode-ai
```

Verify:

```bash
opencode --version
opencode auth list
```

You need at least one provider authenticated. See `opencode auth login`.

## Models

Pass `--model <provider>/<model>` on `agent-session spawn` to pick the model. The string is forwarded verbatim to `opencode run -m`. List installed models with `opencode models`.

If you omit `--model`, the driver does **not** pass `-m` and opencode uses its configured default (which may fail if the default model is incompatible with your auth — explicitly pick one with `--model` if you hit "model not supported").

## Session model

The driver uses `opencode`'s native session lifecycle:

| Phase | Command |
|---|---|
| spawn | `opencode run "<prompt>" --title agent-session-<role> --format json [-m <model>] [--dir <cwd>] [--dangerously-skip-permissions]` |
| run | `opencode run "<prompt>" --title agent-session-run --format json [-m <model>] [--dir <cwd>] [--dangerously-skip-permissions]` |
| send | `opencode run "<prompt>" --session <sid> --format json [-m <model>] [--dir <cwd>] [--dangerously-skip-permissions]` |
| cleanup | `opencode session delete <sid>` |

`--format json` emits NDJSON events to stdout. The driver parses:
- `sessionID` from the first event that carries it (used as the `sid` for subsequent rounds)
- `part.text` from every `type:"text"` event (concatenated as the assistant's reply)
- `type:"error"` aborts with the embedded error message

The system prompt is prepended into the user prompt as `<system>...</system>` since opencode has no separate `--system-prompt` flag.

## Agent / permissions

The driver does **not** set a default `--agent` — opencode uses its default agent. If `OPENCODE_AGENT` is set in the environment when calling `agent-session run` or `spawn`, the value is forwarded to opencode as `--agent <value>`. This lets callers select a user-defined opencode agent profile without baking it into agent-session itself.

## Configuration

| Var | Effect |
|---|---|
| `--model` | Picks the opencode model (forwarded to `opencode run -m`); omit for opencode's default |
| `OPENCODE_AGENT` | Optional passthrough to `opencode run --agent <value>` |

## Limitations

- The driver assumes `opencode run --format json` keeps emitting `sessionID` and `type:"text"` events. If opencode's NDJSON shape changes, `_parse_run_output` needs updating.
- No streaming output exposed to the caller — the driver reads stdout to completion before writing to `output/r<n>.txt`.
- Each `agent-session spawn` creates a brand-new opencode session; sessions persist on disk under opencode's own state until explicitly deleted via `cleanup`.

## Permission behavior

`agent-session --yolo` maps to `opencode --dangerously-skip-permissions`.

`agent-session --cwd D` maps to `opencode --dir D`.

### Without `--yolo` in non-interactive mode

Empirical findings from `~/workspace/workshop/jams/active/agent-session-generic-entry/empirical-permission-results.md`:

- The configured default model failed in this environment because `openai/gpt-5.2-codex` is not supported with the active ChatGPT account.
- With explicit `-m openai/gpt-5.5`, read within cwd succeeded and returned `hello world` from `inside.txt`.
- With explicit `-m openai/gpt-5.5`, bash for `ls /tmp/aspermtest` succeeded without `--dangerously-skip-permissions` and returned `inside.txt`.
- With explicit `-m openai/gpt-5.5 --dangerously-skip-permissions`, the same bash prompt also succeeded.

The driver does not force a model or permission mode. Pass `--model` explicitly when your opencode default is incompatible with the active auth.
