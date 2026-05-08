# Backend: claude

Anthropic Claude via the official `claude` CLI.

## Install

See https://claude.com/install or:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Verify:

```bash
claude --version
```

## Authentication

`claude` handles auth via its own login flow. Run `claude` once interactively to log in (browser flow).

## Models

The driver does not hardcode any model list. Pass any value `claude -p --model <name>` accepts (e.g. an alias like `sonnet`/`opus`/`haiku`, or a fully-qualified model id). If `--model` is omitted on `agent-session spawn`, the driver does not pass `--model` to `claude`, and `claude` uses its own built-in default.

To pin a default for your own use, configure it in your shell:

```bash
# in your shell rc, or wrap the claude binary
alias claude='claude --model sonnet'
```

…or just always pass `--model` explicitly when spawning sessions.

## Session model

- `claude -p --session-id <UUID>` creates a session with a caller-provided UUID
- `claude -p --resume <UUID>` continues the session
- Session jsonl files live under `~/.claude/projects/`. The driver removes them on cleanup.

## Synchronous semantics

`claude -p` blocks until the assistant's response is complete. The driver runs it inline; `status` reflects whether the last call succeeded (`done`) or failed (`error`).

## Limitations

- No streaming output (driver captures final stdout only).
- `--system-prompt` is passed only on `spawn`; subsequent `send` calls cannot change it.
- Token usage / cost is not exposed by the driver.

## Configuration

| Var | Effect |
|---|---|
| (none) | The driver shells out to `claude` directly with no env var customization |

If `claude` is not on `PATH`, the driver fails detection — install it system-wide or symlink.
