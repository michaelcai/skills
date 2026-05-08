# Parallel role execution via tmux

**When to use**: when at least one backend (e.g. opencode + slow GPT model) takes minutes per turn. Sequential spawn means wall-clock = sum-of-all-roles. With tmux, all roles run concurrently and wall-clock = max-of-all-roles.

**Prerequisites**: `tmux` available on the host.

```bash
command -v tmux >/dev/null || { echo "tmux not installed; falling back to sequential spawn"; exit 1; }
```

## Setup

Create a hidden tmux session for this debate. The user does not need to attach to it — `agent-session` writes outputs to `$SESSIONS_DIR/<role-id>/output/` regardless.

```bash
DEBATE_TMUX="debate-${DEBATE_ID}"

# Create background session with one pane per role (3 here)
tmux new-session -d -s "$DEBATE_TMUX" -x 200 -y 50 -n agents
tmux split-window -v -t "$DEBATE_TMUX:agents"        # pane 1
tmux split-window -v -t "$DEBATE_TMUX:agents.0"      # pane 2
```

## Spawn (round 1) in parallel

Replace the sequential `agent-session spawn ...` block in step 2.6 with:

```bash
bash <<'BASH'
set -eu

FORMAT_RULE='Reply in English. Required output format: first "## TL;DR" (2-3 sentences with the core view), with a single line "[stance: hold/concede/add]" at the end of the TL;DR (always "add" in round 1), then "## Argument" (150-300 words, citing specific code/technical detail). No preamble.'

# Resolve backend & model per role from env vars (see SKILL.md §2.3.5).
DEFENDER_BACKEND="${DEBATE_DEFENDER_BACKEND:-claude}"
ROLE_A_BACKEND="${DEBATE_ROLE_A_BACKEND:-opencode}"
ROLE_B_BACKEND="${DEBATE_ROLE_B_BACKEND:-codex}"
DEFENDER_MODEL_FLAG=""; [ -n "${DEBATE_DEFENDER_MODEL:-}" ] && DEFENDER_MODEL_FLAG="--model ${DEBATE_DEFENDER_MODEL}"
ROLE_A_MODEL_FLAG="";   [ -n "${DEBATE_ROLE_A_MODEL:-}" ]   && ROLE_A_MODEL_FLAG="--model ${DEBATE_ROLE_A_MODEL}"
ROLE_B_MODEL_FLAG="";   [ -n "${DEBATE_ROLE_B_MODEL:-}" ]   && ROLE_B_MODEL_FLAG="--model ${DEBATE_ROLE_B_MODEL}"

# Defender → pane 0
tmux send-keys -t "$DEBATE_TMUX:agents.0" \
  "agent-session spawn \
    --backend $DEFENDER_BACKEND --role-id defender \
    --prompt-file $DEBATE_DIR/defender-r1-full.md \
    --state-dir $SESSIONS_DIR \
    --system-prompt 'You are the Defender in a technical debate. $FORMAT_RULE' \
    $DEFENDER_MODEL_FLAG \
   && tmux wait-for -S ${DEBATE_ID}-defender" Enter

# Role A → pane 1
tmux send-keys -t "$DEBATE_TMUX:agents.1" \
  "agent-session spawn \
    --backend $ROLE_A_BACKEND --role-id role-a \
    --prompt-file $DEBATE_DIR/role-a-r1-full.md \
    --state-dir $SESSIONS_DIR \
    --system-prompt 'You are {Role A identity}. $FORMAT_RULE' \
    $ROLE_A_MODEL_FLAG \
   && tmux wait-for -S ${DEBATE_ID}-role-a" Enter

# Role B → pane 2 (if used)
tmux send-keys -t "$DEBATE_TMUX:agents.2" \
  "agent-session spawn \
    --backend $ROLE_B_BACKEND --role-id role-b \
    --prompt-file $DEBATE_DIR/role-b-r1-full.md \
    --state-dir $SESSIONS_DIR \
    --system-prompt 'You are {Role B identity}. $FORMAT_RULE' \
    $ROLE_B_MODEL_FLAG \
   && tmux wait-for -S ${DEBATE_ID}-role-b" Enter
BASH
```

## Wait for all roles

```bash
bash -c '
tmux wait-for "${DEBATE_ID}-defender" \
  && tmux wait-for "${DEBATE_ID}-role-a" \
  && tmux wait-for "${DEBATE_ID}-role-b"
'
# Bash tool timeout: 600000ms (10 minutes)
```

## Subsequent rounds

For round N, the same pattern with `agent-session send` instead of `spawn`. You can continue to use the same panes (the prior `agent-session spawn` exits cleanly after writing output, so the pane is free for the next command).

```bash
bash <<'BASH'
set -eu

tmux send-keys -t "$DEBATE_TMUX:agents.0" \
  "agent-session send --role-id defender \
    --prompt-file $DEBATE_DIR/defender-rN.md \
    --state-dir $SESSIONS_DIR \
   && tmux wait-for -S ${DEBATE_ID}-defender-rN" Enter

# (same pattern for role-a, role-b)
BASH

bash -c 'tmux wait-for "${DEBATE_ID}-defender-rN" && tmux wait-for "${DEBATE_ID}-role-a-rN" && tmux wait-for "${DEBATE_ID}-role-b-rN"'
```

## Cleanup additions

In step 5, after the per-role `agent-session cleanup`, also kill the tmux session:

```bash
tmux kill-session -t "$DEBATE_TMUX" 2>/dev/null || true
```

## Caveats

- All shell snippets must run via `bash -c` or `bash <<'BASH'` heredoc — never directly in fish (variable expansion differs and breaks tmux targets).
- Always double-quote `"$DEBATE_TMUX:agents.N"` — an empty `$DEBATE_TMUX` makes tmux silently fall back to the current session name (a path), giving "can't find pane" errors.
- Roles still run synchronously **inside** their pane; this only parallelizes across roles, not within one role's session.
