# Backend: codex

OpenAI Codex CLI.

## Install

```bash
npm install -g @openai/codex
# or follow https://platform.openai.com/docs/codex
```

Verify:

```bash
codex --version
```

## Authentication

Run `codex login` once to authenticate (browser flow). Auth is stored locally and reused.

## Models

The driver does not hardcode any model list. Pass any value `codex exec -m <name>` accepts. If `--model` is omitted on `agent-session spawn`, the driver does not pass `-m` to codex, and codex uses whatever your `~/.codex/config.toml` has set (or its built-in default).

To pin a default, configure `~/.codex/config.toml`:

```toml
model = "gpt-5"
```

…or pass `--model` explicitly when spawning.

## Session model

codex auto-generates a session id; the driver does **not** track it explicitly. Instead, each role gets an isolated working directory at `<state-dir>/<role-id>/cwd/`, and follow-up turns are sent via:

```
codex exec resume --last --cd <session-cwd>
```

`--last` is scoped to the cwd by default in codex, so it unambiguously picks "the most recent session in this working directory" — i.e. the session this role just spawned.

## Output capture

The driver passes `-o, --output-last-message <FILE>` to write the assistant's final message directly to a file. No JSON parsing needed.

## Permissions / sandbox

The driver passes `--full-auto` and `--skip-git-repo-check`:

- `--full-auto` — auto-approves model-issued shell commands (non-interactive)
- `--skip-git-repo-check` — the per-role cwd is not a git repo by design, so this avoids the warning

If you want stricter sandboxing, modify `_common_flags()` in `bin/agent-session` to add `-s read-only` (full-auto + read-only is a common combo for non-mutating roles).

## Permission behavior

`agent-session --yolo` maps to `codex exec --dangerously-bypass-approvals-and-sandbox`.

`agent-session --cwd D` maps to `codex exec --cd D` for `spawn`. Follow-up `send` calls resume from the recorded cwd via subprocess cwd because `codex exec resume --last` does not accept `--cd`.

### `run()` not implemented

Codex driver currently only implements `spawn` / `send` / etc. for multi-turn sessions; the `run` verb raises `NotImplementedError`. Track this in a follow-up issue.

### Without `--yolo` in non-interactive mode

Empirical findings from `~/workspace/workshop/jams/active/agent-session-generic-entry/empirical-permission-results.md`:

- `codex exec` refused the non-git `/tmp/aspermtest` cwd until `--skip-git-repo-check` was supplied.
- After that, default non-interactive mode reported `approval: never`, `sandbox: read-only`, and model `gpt-5.4`.
- Read within cwd succeeded and returned `hello world` from `inside.txt`.
- Bash for `ls /tmp/aspermtest` succeeded in the read-only sandbox and returned `inside.txt`.
- With `--dangerously-bypass-approvals-and-sandbox`, the same bash prompt succeeded and codex reported `sandbox: danger-full-access`.

## Limitations

- The driver assumes `--last` is cwd-scoped, which is codex's current default behavior. If codex changes the default to global, sessions could collide and the driver would need to parse session ids from `--json` output instead.
- No streaming — driver waits for completion and reads the final message.
- Token usage / cost is not exposed by the driver.

## Configuration

| Var | Effect |
|---|---|
| `~/.codex/config.toml` | Codex's own config (model defaults, profile, etc.); the driver does not override it |
