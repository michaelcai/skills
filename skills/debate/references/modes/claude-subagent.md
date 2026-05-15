# claude-subagent mode — Agent tool dispatch with cumulative history

**Loaded by**: moderator (main agent) when claude backend mode = `subagent`.

**Why this mode exists**: From 2026-06-15 Anthropic split `claude -p` / Agent SDK calls into a separate "Agent SDK credit" pool that does NOT consume Pro/Max subscription quota. Subagents dispatched via the Agent tool inside a Claude Code session DO consume the parent session's subscription quota (per Anthropic costs doc: *"Claude Max and Pro subscribers have usage included in their subscription"*). This mode replaces `claude -p` subprocess calls with Agent tool dispatch for the claude backend only — opencode/codex/etc remain subprocess.

**Trade-off vs `teammates` mode**: Subagents are stateless per call; the moderator re-sends the full role history every round. Prompt cache (system prompt + shared-context) absorbs most repeats. Simpler than `teammates` (no experimental flag, no `/resume` limitations, no team lifecycle).

## Per-round dispatch protocol

The moderator partitions `ACTIVE_ROLES` into two arrays based on the role's resolved backend (from §2.3 Per-role assignment): `CLAUDE_ROLES` (those using the claude backend) and `AGENT_SESSION_ROLES` (everything else — opencode/codex/etc., routed through agent-session unchanged). This mode reference only describes the `CLAUDE_ROLES` path; agent-session handling for the others is unchanged from SKILL.md §Send.

For each role `r` in `CLAUDE_ROLES`, in **one Bash tool call that assembles all prompts (sequentially is fine — file assembly is fast), then one assistant message that fires N Agent tool calls in parallel**:

### Step 1 (Bash): Assemble dispatch prompt files

```bash
mkdir -p "$DEBATE_DIR/dispatch" "$DEBATE_DIR/outputs"
for r in "${CLAUDE_ROLES[@]}"; do
  # Round 1: shared-context + role identity + initial focus
  # Round N: shared-context + role identity + accumulated TL;DR history + this-round focus
  # nullglob: on round 1 there is no tldrs-history/<r>/r*.md — without nullglob the literal
  #          glob pattern survives, cat fails on a missing file, and `set -e` aborts the loop.
  shopt -s nullglob
  history_files=("$DEBATE_DIR/tldrs-history/${r}/"r*.md)
  shopt -u nullglob
  cat "$DEBATE_DIR/shared-context.md" \
      "$DEBATE_DIR/roles/${r}.md" \
      "${history_files[@]}" \
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

### Step 3 (Write): Write returned outputs to debate file layout

When each subagent returns, the moderator writes its text content (full TL;DR + Argument reply) to `$DEBATE_DIR/outputs/<role>-r<N>.md` using the **Write tool** (or a `cat > "$DEBATE_DIR/outputs/${r}-r${N}.md" <<'EOF' … EOF` heredoc in a Bash call). The After-round extraction below reads from these files.

Do **not** pre-truncate with a `: > "$DEBATE_DIR/outputs/..."` loop — that leaves zero-byte files if the moderator forgets the write step. The Write tool creates/overwrites in one step.

### Step 4 (Bash): After-round extraction (path-based)

Subagent mode cannot use `agent-session tldr` — that command reads from agent-session's state-dir, not arbitrary paths. Instead, the moderator extracts TL;DR body + stance/stage/source-kind tags directly from `outputs/<role>-r<N>.md` using `sed` + `grep`. The `role_stance_whitelist` function is owned by SKILL.md §After-round — this loop just calls it.

```bash
# After-round (subagent mode) — extract TL;DR + tags from outputs/, write to tldrs/ + stances/ + stages/ etc.
mkdir -p "$DEBATE_DIR/tldrs" "$DEBATE_DIR/stances" "$DEBATE_DIR/stages" "$DEBATE_DIR/source-kinds"
for r in "${CLAUDE_ROLES[@]}"; do
  out="$DEBATE_DIR/outputs/${r}-r${N}.md"
  [ -f "$out" ] || { failed+=("$r:no-output"); continue; }

  # TL;DR body: lines between '## TL;DR' and next '## ' header, exclusive
  sed -n '/^## TL;DR/,/^## /{/^## /!p;}' "$out" > "$DEBATE_DIR/tldrs/${r}.md"
  mkdir -p "$DEBATE_DIR/tldrs-history/${r}"
  cp "$DEBATE_DIR/tldrs/${r}.md" "$DEBATE_DIR/tldrs-history/${r}/r${N}.md"

  # Stance: grep '[stance: X]' from TL;DR section, validate against per-role narrowed whitelist
  # (role_stance_whitelist owned by SKILL.md §After-round — do not redefine here).
  # Invalid / out-of-mutex / missing stance → null, which trips §False-consensus guard.
  stance_raw=$(grep -oE '\[stance: *[a-z|/]+ *\]' "$DEBATE_DIR/tldrs/${r}.md" | head -1 | sed -E 's/.*: *//;s/ *\]//')
  narrowed=$(role_stance_whitelist "$PRESET" "$r")
  if [ -z "$stance_raw" ] || ! echo ",$narrowed," | grep -q ",$stance_raw,"; then
    echo "null" > "$DEBATE_DIR/stances/${r}.txt"
  else
    echo "$stance_raw" > "$DEBATE_DIR/stances/${r}.txt"
  fi

  # Discovery preset: also extract [stage: ...]
  stage=$(grep -oE '\[stage: *[a-z]+ *\]' "$out" | head -1 | sed -E 's/.*: *//;s/ *\]//')
  [ -n "$stage" ] && echo "$stage" > "$DEBATE_DIR/stages/${r}.txt"

  # Inquiry preset: also extract [source-kind: ...]
  # Single-file per role (matches subprocess mode; overwrites each round — used for Inquiry checkpoint logic).
  sk=$(grep -oE '\[source-kind: *[a-z\-]+ *\]' "$out" | head -1 | sed -E 's/.*: *//;s/ *\]//')
  [ -n "$sk" ] && echo "$sk" > "$DEBATE_DIR/source-kinds/${r}.txt"
done
```

The subprocess mode's `agent-session tldr` calls are replaced by these direct `grep`/`sed` extractions. Downstream files are the same (`tldrs/`, `tldrs-history/`, `stances/`, `stages/`, `source-kinds/`), so the rest of the After-round logic (whitelist validation, false-consensus guard, checkpoint synthesis per SKILL §After-round) is **unchanged**.

## Reconcile

**Not applicable** in this mode — every round is fresh dispatch, there is no persistent session to lose. If a subagent fails (Agent tool returns error), the moderator re-dispatches that role only with the same dispatch prompt. No `--initial-round` accounting needed.

## Format correction

Same flow as subprocess mode but the correction send is another Agent tool dispatch:
1. After-round detects null stance / out-of-mutex stance / bad stage
2. Moderator builds `format-correction-<role>.md` (preset-aware, per SKILL §Format-correction template)
3. **Dispatch a fresh Agent** with `prompt` = original dispatch + the previous (invalid) `outputs/<role>-r<N>.md` content + correction template. The subagent has no session memory; the previous bad output and the correction template are both required for the model to know what to fix. Example assembly:
   ```bash
   cat "$DEBATE_DIR/dispatch/${r}-r${N}.md" \
       <(echo) <(echo "## Your previous reply (must be corrected):") \
       "$DEBATE_DIR/outputs/${r}-r${N}.md" \
       <(echo) <(echo "## Correction") \
       "$DEBATE_DIR/format-correction-${r}.md" \
       > "$DEBATE_DIR/dispatch/${r}-r${N}-correction.md"
   ```
4. Dispatch Agent tool with this assembled prompt, write returned text back to `outputs/<role>-r<N>.md`, re-run extraction.

## Cleanup

No-op. No persistent sessions to terminate. `rm -rf $DEBATE_DIR` removes all state.

## Token cost note

Per-round per-role prompt = shared-context + role identity + N prior TL;DRs + this-round focus ≈ 1.5k + 0.5k + N*1.5k + 0.3k tokens. For 4 roles × 6 rounds, peak round input ≈ 10k tokens × 4 roles = 40k. With Claude prompt cache, the shared-context and role identity are cached, so effective input ≈ N*1.5k + 0.3k ≈ 9k per role per round. Total debate input ≈ ~150k tokens, output ~30k tokens.

## What this mode does NOT do

- Does not invoke agent-session at all for the claude backend
- Does not maintain `state-dir` / `meta.json` (Agent tool has no analog)
- Does not pass `--yolo` (the Agent tool's subagent inherits permission context from the parent session, which is interactive Claude Code — permission prompts surface to the user, not block the subagent at 0% CPU)
