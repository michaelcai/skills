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
- `oc-task spawn` / `send` / `status` (opencode, multi-provider)
- `codex exec` (OpenAI)
- ...

A skill that wants multi-model multi-turn dialogue should not hard-code any of these. `agent-session` provides a 6-verb CLI that hides backend differences:

```
agent-session doctor                                                # health check
agent-session list-backends                                         # programmatic: which backends are available
agent-session describe   --role-id R                                # what backend/model is this role using
agent-session spawn      --backend X --role-id R --prompt-file P [--model M] [--state-dir D] [--system-prompt S]
agent-session send       --role-id R --prompt-file P [--state-dir D]
agent-session status     --role-id R [--state-dir D]
agent-session output     --role-id R [--round N] [--state-dir D]
agent-session cleanup    --role-id R [--state-dir D]
```

## Backend installation is NOT this skill's job

Users install `claude` / `oc-task` / `codex` / etc. independently. `agent-session` only **detects** what's already installed and dispatches calls to whatever's there.

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
    │       detect()  spawn()  send()  status()  output()  cleanup()
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
  ✓ opencode  ~/.pai/.../oc-task
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

stdout: nothing significant on success (caller reads via `output --round 0`). Non-zero exit on failure; stderr explains.

### `send`

Sends a follow-up turn on an existing session.

```
agent-session send --role-id role-a --prompt-file r3.md
```

stdout: nothing on success; caller reads via `output --round N`.

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

## Caller conventions (for skills using agent-session)

When integrating, follow these:

1. **Generate role-id by purpose, not by random**: `defender` / `role-a` / `opencode-judge`. Predictable role-ids = easier debug + cleanup.
2. **Pass `--state-dir` explicitly** if you have your own state root (e.g. debate passes `$DEBATE_DIR/sessions/`). Lets you cleanup everything by removing one directory.
3. **Don't read `meta.json` directly** — go through `describe`. The meta schema is internal.
4. **Don't shell out to backend CLIs yourself** — defeats the purpose. Add a backend driver instead.
5. **Always call `cleanup` on every role-id you spawned**, ideally in a trap so unexpected exits don't leak state.

## Adding a new backend

See `references/adding-a-backend.md` for the full driver protocol. TL;DR:

1. Add `drivers/<name>.py` implementing `Driver` (7 methods)
2. Register in `drivers/__init__.py`
3. Add `references/backend-<name>.md` with install steps for users
4. Add tests in `tests/`

## Dependencies

| Component | Purpose |
|---|---|
| Python 3.10+ | Run `bin/agent-session` (single-file Python script) |
| At least one backend CLI | What a session actually runs against (claude / oc-task / ...) |

No third-party Python packages — stdlib only.

## Backend reference docs

- [`references/backend-claude.md`](./references/backend-claude.md)
- [`references/backend-opencode.md`](./references/backend-opencode.md)
- `references/backend-codex.md` (planned)
- [`references/adding-a-backend.md`](./references/adding-a-backend.md)
