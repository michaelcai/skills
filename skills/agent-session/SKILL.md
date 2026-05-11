---
name: agent-session
description: "Persistent multi-turn LLM session abstraction over heterogeneous backend CLIs (claude, opencode, codex...). Caller passes role-id + prompt files, gets assistant messages back. Multi-backend dispatch via a single CLI."
user-invocable: false
---

# agent-session

Persistent multi-turn session abstraction over heterogeneous LLM backend CLIs. Used by other skills (e.g. `debate`) to spawn role-played LLM sessions, send follow-up turns, and collect outputs — without knowing which backend (`claude` / `opencode` / `codex` / ...) is actually running.

## Why

Different backend CLIs have different commands, session models, and output formats:

- `claude -p --session-id $SID` / `--resume $SID` (Claude Anthropic)
- `opencode run --session $SID` (opencode, multi-provider)
- `codex exec` (OpenAI)
- ...

A skill that wants multi-model multi-turn dialogue should not hard-code any of these. `agent-session` provides a backend-neutral CLI that hides backend differences:

```
agent-session doctor                                                # health check
agent-session list-backends                                         # programmatic: which backends are available
agent-session describe   --role-id R                                # what backend/model is this role using
agent-session spawn      --backend X --role-id R --prompt-file P [--model M] [--state-dir D] [--system-prompt S] [--cwd D] [--yolo]
                         (--session-id is an alias for --role-id)
agent-session run        --backend X --prompt-file P [--model M] [--system-prompt S] [--cwd D] [--yolo]
                         (codex run is not implemented yet; spawn/send still work)
agent-session send       --role-id R --prompt-file P [--state-dir D]
agent-session status     --role-id R [--state-dir D]
agent-session output     --role-id R [--round N] [--state-dir D]
agent-session cleanup    --role-id R [--state-dir D]
```

## Backend installation is NOT this skill's job

Users install `claude` / `opencode` / `codex` / etc. independently. `agent-session` only **detects** what's already installed and dispatches calls to whatever's there.

If a backend is missing, `doctor` reports it; downstream skills (e.g. debate) decide whether to fail or degrade.

## Architecture

```
caller skill (debate, ...)
    │ shell exec
    ▼
bin/agent-session (dispatcher)
    │
    ├── Backend Registry  ← detect available backends
    │       claude   → drivers/claude.py
    │       opencode → drivers/opencode.py
    │       codex    → drivers/codex.py    (future)
    │
    ├── Driver interface  ← every backend implements:
    │       detect()  spawn()  run()  send()  status()  output()  cleanup()
    │
    └── Session State (filesystem)
        $AGENT_SESSION_DIR/<role-id>/
          meta.json    {backend, model, sid, round_count, state}
          input/rN.md  prompts written by caller
          output/rN.txt assistant messages written by driver
          log          debug
          .lock        concurrency control
```

The caller holds only `role-id`. Backend-specific session ids (`SID`) live in `meta.json` and are never exposed.

## Lifecycle

```
[uninitialized]
    │ spawn --backend X --role-id R --prompt-file r0.md
    ▼
[spawning] ─ driver.spawn(): detect, run first turn, write meta + output/r0.txt
    │
    ▼
[active]
    ↻ send --role-id R --prompt-file rN.md → driver.send() → output/rN.txt, round_count++
    ↻ status --role-id R                    → running | done | error
    ↻ output --role-id R [--round N]       → reads output/rN.txt
    │
    │ cleanup --role-id R
    ▼
[cleaning] ─ driver.cleanup(): close backend session, delete state dir
    │
    ▼
[gone]
```

Notes:
- `spawn` runs the first turn and includes its prompt — no separate "create empty session" step (most backend CLIs require an initial prompt).
- `cleanup` is idempotent — safe to call on a non-existent role-id.
- Same role-id concurrent `spawn`/`send` is rejected via `.lock`. Different role-ids in parallel are fully supported.

## Verbs

### `doctor`

Read-only health check. Prints which backends are detected, where they live, what models they advertise. No filesystem writes outside stdout.

```
$ agent-session doctor
Detected:
  ✓ claude    /usr/local/bin/claude
  ✓ opencode  /usr/local/bin/opencode
  ✗ codex     not installed   see references/backend-codex.md

Multi-model: ✓ (claude + opencode)
```

### `list-backends`

Programmatic, machine-readable.

```
$ agent-session list-backends
claude
opencode
```

Exit 0 even if zero backends are detected — caller decides what to do.

### `spawn`

Creates a new session and runs the first turn.

| Arg | Required | Notes |
|---|---|---|
| `--backend` | yes | One of the names from `list-backends` |
| `--role-id` | yes | Any string unique within `$AGENT_SESSION_DIR`. Caller chooses. |
| `--prompt-file` | yes | Path to first-turn prompt (markdown / plain text) |
| `--model` | no | Backend-specific model name; driver picks default if omitted |
| `--state-dir` | no | Override `$AGENT_SESSION_DIR`; e.g. debate passes `$DEBATE_DIR/sessions/` |
| `--system-prompt` | no | System-level instructions; passed to backend if it supports it |
| `--cwd` | no | Working directory for the backend subprocess. claude inherits via subprocess cwd; opencode uses `--dir`; codex uses `--cd`. |
| `--yolo` | no | Bypass permission prompts (`--dangerously-skip-permissions` on claude/opencode, `--dangerously-bypass-approvals-and-sandbox` on codex). For autonomous Agent invocations, see references/backend-<name>.md for default-mode behavior. |
| `--timeout` | no | Subprocess timeout in seconds. Persists to `meta.json` so `send` inherits it for follow-up rounds. Priority: explicit `--timeout` > meta-persisted > `$AGENT_SESSION_TIMEOUT` > default 1800s. |

stdout: nothing significant on success (caller reads via `output --round 0`). Non-zero exit on failure; stderr explains. On `subprocess.TimeoutExpired` the state is marked `error`, `meta.error` records the timeout, and a clean `RuntimeError` (exit 1) describes the override mechanism.

### `run`

One-shot, stateless invocation. Returns the assistant's reply to stdout. No state directory, no cleanup needed — the driver disposes of any backend-side session it creates.

| Arg | Required | Notes |
|---|---|---|
| `--backend` | yes | One of the names from `list-backends` |
| `--prompt-file` | yes | Path to prompt (markdown / plain text) |
| `--model` | no | Backend-specific model name |
| `--system-prompt` | no | System-level instructions (opencode has no native flag — driver prepends to prompt) |
| `--cwd` | no | Working directory for the backend subprocess. claude inherits via subprocess cwd; opencode uses `--dir`; codex uses `--cd`. |
| `--yolo` | no | Bypass permission prompts (`--dangerously-skip-permissions` on claude/opencode, `--dangerously-bypass-approvals-and-sandbox` on codex). For autonomous Agent invocations, see references/backend-<name>.md for default-mode behavior. |
| `--timeout` | no | Subprocess timeout in seconds. Priority: explicit `--timeout` > `$AGENT_SESSION_TIMEOUT` > default 1800s. |

stdout: full assistant text. Non-zero exit + stderr on failure.

Example (Agent ad-hoc review):

```bash
cd ~/workspace/some-repo
agent-session run --backend opencode --cwd "$PWD" --yolo --prompt-file /tmp/review-prompt.md
```

### `send`

Sends a follow-up turn on an existing session.

```
agent-session send --role-id role-a --prompt-file r3.md
```

stdout: nothing on success; caller reads via `output --round N`.

| Arg | Required | Notes |
|---|---|---|
| `--role-id` / `--session-id` | yes | Existing session identifier |
| `--prompt-file` | yes | Path to this turn's prompt |
| `--state-dir` | no | Same value used at `spawn` |
| `--timeout` | no | Override the ceiling for this send AND persist it back to `meta.json` so subsequent sends inherit. Priority: `--timeout` > meta-persisted (from spawn or a previous `send --timeout`) > `$AGENT_SESSION_TIMEOUT` > 1800s. |
| `--force` | no | Recover a session stuck in `state=error` (typically from a previous timeout). Moves `meta.error` aside to `meta.last_error` and re-attempts. The retry may still fail — that's fine, you get an explicit attempt instead of being permanently blocked. |

### Timeout

All drivers run subprocess synchronously. The default ceiling is 1800s (30 min), tuned to accommodate gpt-5.5-class reasoning models on a multi-round resume. Override priority:

1. `--timeout N` on `spawn` / `run` (per-call; spawn persists into `meta.json` so subsequent `send`s inherit)
2. `AGENT_SESSION_TIMEOUT=N` env (process-wide)
3. Default `1800`

On `subprocess.TimeoutExpired` the session is marked `state="error"` with `meta.error` set to the timeout message — `describe` surfaces it, `send` refuses to continue. Callers wanting a different ceiling should re-`spawn` rather than try to resume an errored session.

### `status`

```
agent-session status --role-id role-a
```

stdout: `running` | `done` | `error` (one line). All current drivers are synchronous — `spawn`/`send` block until the turn is complete — so `status` is a pure read of `meta.json`, never a polling primitive.

### `output`

```
agent-session output --role-id role-a              # latest assistant message
agent-session output --role-id role-a --round 2    # round 2 specifically
```

stdout: full text of the assistant message (no trimming, no JSON wrapping).

### `cleanup`

Closes the backend session and deletes the state directory. Idempotent.

### `describe`

```
agent-session describe --role-id role-a
```

stdout: JSON like `{"backend": "opencode", "binary_family": "openai", "model_family": "anthropic", "model": "anthropic/claude-opus", "round_count": 4, "state": "active"}`.

`model` is `"default"` when caller did not pass `--model` to `spawn` (in which case the backend uses its own configured default). Otherwise it's the literal model name the caller requested.

There are **two** family classifiers — they answer different questions, and a caller asking the wrong one gets misleading answers:

- **`binary_family`** (static per driver: `claude→anthropic`, `codex→openai`, `opencode→openai` default) — *which CLI binary, which credentials, which network egress are we trusting?* This is supply-chain identity. Network policies that route by binary use this.
- **`model_family`** (per-model resolver) — *which provider actually served the response?* For `opencode -m anthropic/claude-opus` this is `"anthropic"`, even though `binary_family` is `"openai"`. Cross-family debate-role assignment uses this.

Both fall back to `binary_family` when the model is unknown — never to `"unknown"` (that would silently break "≥2 distinct families" logic for any default model without a slash prefix).

`doctor` additionally probes **auth identity** per backend (`anthropic-api` / `openai-chatgpt` / `openai-api` / ...) — two backends with distinct binaries can still share an upstream account, in which case "cross-family" is notional, not actual. The doctor warning surfaces this collision.

### CLI flag aliases

`--session-id` is an accepted alias for `--role-id` on every verb that takes one. The two are mutually substitutable; `meta.json` / `describe` JSON output retains the `role_id` field name for backward compatibility with existing callers (debate).

When integrating a new multi-turn caller that doesn't have a "role" concept, prefer `--session-id`.

## Caller conventions (for skills using agent-session)

When integrating, follow these:

1. **Generate role-id by purpose, not by random**: `defender` / `role-a` / `opencode-judge`. Predictable role-ids = easier debug + cleanup.
2. **Pass `--state-dir` explicitly** if you have your own state root (e.g. debate passes `$DEBATE_DIR/sessions/`). Lets you cleanup everything by removing one directory.
3. **Don't read `meta.json` directly** — go through `describe`. The meta schema is internal.
4. **Don't shell out to backend CLIs yourself** — defeats the purpose. Add a backend driver instead.
5. **Always call `cleanup` on every role-id you spawned**, ideally in a trap so unexpected exits don't leak state.

## Adding a new backend

See `references/adding-a-backend.md` for the full driver protocol. TL;DR:

1. Add `drivers/<name>.py` implementing `Driver` (8 methods: detect, spawn, send, status, output, cleanup, describe, run)
2. Register in `drivers/__init__.py`
3. Add `references/backend-<name>.md` with install steps for users
4. Add tests in `tests/`

## Dependencies

| Component | Purpose |
|---|---|
| Python 3.10+ | Run `bin/agent-session` (single-file Python script) |
| At least one backend CLI | What a session actually runs against (claude / opencode / codex / ...) |

No third-party Python packages — stdlib only.

## Backend reference docs

- [`references/backend-claude.md`](./references/backend-claude.md)
- [`references/backend-opencode.md`](./references/backend-opencode.md)
- `references/backend-codex.md` (planned)
- [`references/adding-a-backend.md`](./references/adding-a-backend.md)
