# Quickstart: verify `agent-session` end-to-end

After installing this repo, run these commands to confirm `agent-session` works against a real backend. The transcripts below are real outputs (Claude Haiku, captured 2026-05-08).

## 1. Health check

```bash
agent-session doctor
```

Expected:

```
Detected backends:
  ✓ claude     /usr/local/bin/claude            family=anthropic  auth=anthropic-api
  ✓ opencode   ~/.opencode/bin/opencode         family=openai     auth=openai-chatgpt
  ✓ codex      /opt/homebrew/bin/codex          family=openai     auth=openai-chatgpt

Available backends: 3
Distinct binary families: 2 (anthropic, openai)
Distinct auth identities: 2 (anthropic-api, openai-chatgpt)
Multi-model capability: ✓
```

If `Multi-model capability: ✓`, you can run `/debate`. If not, install at least one non-Claude backend (`opencode` or `codex`) — see `skills/agent-session/references/backend-*.md`.

The `auth=` column flags supply-chain identity collisions: two backends sharing the same auth (e.g. both `openai-chatgpt`) means the cross-family debate premise is notional — they hit the same vendor. `doctor` warns when collisions reduce the *real* family count below the *binary* family count.

## 2. Single-turn spawn

Confirm a session can be created and the assistant message is captured.

```bash
mkdir -p /tmp/quickstart && cd /tmp/quickstart
echo "Reply with exactly the word HELLO and nothing else." > prompt.md

agent-session spawn \
  --backend claude --role-id smoke \
  --prompt-file ./prompt.md \
  --state-dir ./state \
  --model haiku
```

Read what the assistant said:

```bash
agent-session output --role-id smoke --state-dir ./state
```

Real captured output:

```
HELLO
```

Inspect the session state:

```bash
agent-session describe --role-id smoke --state-dir ./state
```

```json
{
  "role_id": "smoke",
  "backend": "claude",
  "binary_family": "anthropic",
  "model_family": "anthropic",
  "model": "haiku",
  "round_count": 1,
  "state": "active"
}
```

(`binary_family` is the CLI's static identity — `claude` always reports `anthropic`. `model_family` is per-model: opencode + an `anthropic/*` model would report `binary_family: openai`, `model_family: anthropic`. See `agent-session doctor` for the auth-identity column.)

Cleanup:

```bash
agent-session cleanup --role-id smoke --state-dir ./state
```

## 3. Cross-round memory (the real test)

This proves a session persists conversation history across `send` calls — the foundation `debate` relies on for multi-round dialogue.

```bash
echo "My name is Alice. Reply with: NICE TO MEET YOU ALICE" > p1.md
echo "What is my name? Reply with just the name, one word."  > p2.md

agent-session spawn --backend claude --role-id memtest \
  --prompt-file ./p1.md --state-dir ./state --model haiku
agent-session output --role-id memtest --state-dir ./state
# → NICE TO MEET YOU ALICE

agent-session send --role-id memtest \
  --prompt-file ./p2.md --state-dir ./state
agent-session output --role-id memtest --state-dir ./state
# → Alice           ← the session remembers round 0

agent-session describe --role-id memtest --state-dir ./state
# → round_count: 2

agent-session cleanup --role-id memtest --state-dir ./state
```

If round 1 returns `Alice`, your `agent-session` install is fully working — sessions persist across rounds, and `debate` will work.

## 4. Try other backends

Replace `--backend claude` with `--backend opencode` or `--backend codex`. The protocol is identical; output format depends on the backend's own behavior.

```bash
agent-session spawn --backend codex --role-id smoke-codex \
  --prompt-file ./prompt.md --state-dir ./state
agent-session output --role-id smoke-codex --state-dir ./state
agent-session cleanup --role-id smoke-codex --state-dir ./state
```

## What "ready" looks like

If all three sections above pass:

- ✓ `doctor` reports Multi-model: ✓
- ✓ `spawn` + `output` round-trip works for at least 2 distinct backends
- ✓ `send` + `output` proves cross-round memory

You can now run `/debate` (see [`skills/debate/SKILL.md`](../skills/debate/SKILL.md)).
