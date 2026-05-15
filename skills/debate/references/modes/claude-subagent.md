# claude-subagent mode — Agent tool dispatch with cumulative history

**Loaded by**: moderator (main agent) when claude backend mode = `subagent`.

**Why this mode exists**: From 2026-06-15 Anthropic split `claude -p` / Agent SDK calls into a separate "Agent SDK credit" pool that does NOT consume Pro/Max subscription quota. Subagents dispatched via the Agent tool inside a Claude Code session DO consume the parent session's subscription quota (per Anthropic costs doc: *"Claude Max and Pro subscribers have usage included in their subscription"*). This mode replaces `claude -p` subprocess calls with Agent tool dispatch for the claude backend only — opencode/codex/etc remain subprocess.

**Trade-off vs `teammates` mode**: Subagents are stateless per call; the moderator re-sends the full role history every round. Prompt cache (system prompt + shared-context) absorbs most repeats. Simpler than `teammates` (no experimental flag, no `/resume` limitations, no team lifecycle).

## Per-round dispatch protocol

For each role `r` in `ACTIVE_ROLES`, in **one Bash tool message that assembles all prompts in parallel followed by one assistant message that fires N Agent tool calls in parallel**:

### Step 1 (Bash): Assemble dispatch prompt files

```bash
mkdir -p "$DEBATE_DIR/dispatch" "$DEBATE_DIR/outputs"
for r in "${ACTIVE_ROLES[@]}"; do
  # Round 1: shared-context + role identity + initial focus
  # Round N: shared-context + role identity + accumulated TL;DR history + this-round focus
  cat "$DEBATE_DIR/shared-context.md" \
      "$DEBATE_DIR/roles/${r}.md" \
      "$DEBATE_DIR/tldrs-history/${r}/"r*.md 2>/dev/null \
      "$DEBATE_DIR/rN-focus-${r}.md" \
      > "$DEBATE_DIR/dispatch/${r}-r${N}.md"
done
```

### Step 2 (Agent tools, parallel): Dispatch N subagents in one assistant message

[MUST] Issue all N Agent tool calls in **one assistant message** (multiple tool_use blocks). Sequential dispatch would serialize round wall-clock.

Per-call parameters:
- `subagent_type`: `claude` (general purpose; debate is generative not pure-read)
- `description`: `debate <preset> r<N> <role>` (under 8 words)
- `prompt`: contents of `$DEBATE_DIR/dispatch/<role>-r<N>.md` — must be self-contained, subagent does not inherit moderator context

### Step 3 (Bash): Write returned outputs to debate file layout

When all subagents return, write their full text to:
- `$DEBATE_DIR/outputs/<role>-r<N>.md` — full reply (TL;DR + Argument)
- (The After-round step §SKILL handles stance/stage extraction from these files — unchanged.)

```bash
# moderator writes each agent return value into outputs/
for r in "${ACTIVE_ROLES[@]}"; do
  : > "$DEBATE_DIR/outputs/${r}-r${N}.md"  # truncate; moderator writes content next
done
```

The moderator writes each subagent's returned text content to its `outputs/` file. The After-round step then runs the same `tldr` / stance / stage extraction shell loops as in subprocess mode, reading from `outputs/` instead of agent-session's state-dir.

## Reconcile

**Not applicable** in this mode — every round is fresh dispatch, there is no persistent session to lose. If a subagent fails (Agent tool returns error), the moderator re-dispatches that role only with the same dispatch prompt. No `--initial-round` accounting needed.

## Format correction

Same flow as subprocess mode but the correction send is another Agent tool dispatch:
1. After-round detects null stance / out-of-mutex stance / bad stage
2. Moderator builds `format-correction-<role>.md` (preset-aware, per SKILL §Format-correction template)
3. **Dispatch a fresh Agent** with `prompt` = original dispatch + correction appended
4. Write returned text back to `outputs/<role>-r<N>.md`, re-run extraction

## Cleanup

No-op. No persistent sessions to terminate. `rm -rf $DEBATE_DIR` removes all state.

## Token cost note

Per-round per-role prompt = shared-context + role identity + N prior TL;DRs + this-round focus ≈ 1.5k + 0.5k + N*1.5k + 0.3k tokens. For 4 roles × 6 rounds, peak round input ≈ 10k tokens × 4 roles = 40k. With Claude prompt cache, the shared-context and role identity are cached, so effective input ≈ N*1.5k + 0.3k ≈ 9k per role per round. Total debate input ≈ ~150k tokens, output ~30k tokens.

## What this mode does NOT do

- Does not invoke agent-session at all for the claude backend
- Does not maintain `state-dir` / `meta.json` (Agent tool has no analog)
- Does not pass `--yolo` (the Agent tool's subagent inherits permission context from the parent session, which is interactive Claude Code — permission prompts surface to the user, not block the subagent at 0% CPU)
