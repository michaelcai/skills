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
| spawn | `opencode run "<prompt>" --title agent-session-<role> --format json [-m <model>]` |
| send | `opencode run "<prompt>" --session <sid> --format json [-m <model>]` |
| cleanup | `opencode session delete <sid>` |

`--format json` emits NDJSON events to stdout. The driver parses:
- `sessionID` from the first event that carries it (used as the `sid` for subsequent rounds)
- `part.text` from every `type:"text"` event (concatenated as the assistant's reply)
- `type:"error"` aborts with the embedded error message

The system prompt is prepended into the user prompt as `<system>...</system>` since opencode has no separate `--system-prompt` flag.

## Agent / permissions

The driver does **not** pass `--agent` — opencode uses its default agent (typically `build`). Debate-style usage doesn't need tool execution; the agents just answer text. If your default agent prompts for tool permission, configure a non-interactive agent in `~/.config/opencode/opencode.json` and reference it manually.

## Configuration

| Var | Effect |
|---|---|
| `--model` | Picks the opencode model (forwarded to `opencode run -m`); omit for opencode's default |

## Limitations

- The driver assumes `opencode run --format json` keeps emitting `sessionID` and `type:"text"` events. If opencode's NDJSON shape changes, `_parse_run_output` needs updating.
- No streaming output exposed to the caller — the driver reads stdout to completion before writing to `output/r<n>.txt`.
- Each `agent-session spawn` creates a brand-new opencode session; sessions persist on disk under opencode's own state until explicitly deleted via `cleanup`.
