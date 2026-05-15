# claude-teammates mode — Anthropic Agent Teams

**Loaded by**: moderator (main agent acting as team lead) when claude backend mode = `teammates`.

**Why this mode exists**: Anthropic Agent Teams (experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) lets the moderator spawn N teammate Claude Code sessions, each persistent across rounds. Teammates communicate via SendMessage. This is the official `/en/agent-teams` mechanism — Anthropic documents *"Spawn 5 agent teammates to investigate different hypotheses... like a scientific debate"* as a canonical use case. Teammate token usage is included in subscription quota (per costs doc).

**Trade-off vs `subagent` mode**: Teammates persist across rounds → round N only sends focus + peer TL;DRs (not full history). 7x token cost vs single session because each teammate is a full Claude instance with its own context window. Requires Claude Code v2.1.32+ and the experimental flag.

## Prerequisites

```bash
# Moderator MUST verify before proceeding
[ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" = "1" ] || {
  echo "teammates mode requires CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1" >&2
  exit 1
}
claude_version=$(claude --version 2>/dev/null | awk '{print $1}')
# 2.1.32+ required — moderator parses major.minor.patch and aborts if lower
```

## Round 1: Team creation

The moderator outputs **one natural-language instruction** to spawn the team. The moderator does NOT use Agent tool here — Anthropic runtime parses the prompt and creates the team.

Template (moderator emits this text to the conversation):

```
Create an agent team for a {PRESET} debate on the following challenge:

{CHALLENGE TEXT}

Lead: me (debate moderator, this session).

Spawn {N} teammates, all using `teammateMode: in-process`:

  - {role-slug-1}: {role-identity-and-axis-1}
  - {role-slug-2}: {role-identity-and-axis-2}
  - ...
  - wildcard: divergent thinker, not scoped to any specific angle

Each teammate plays its role per the debate skill output format
({preset-specific format file}). Use Sonnet for teammates. Do not ask
for confirmation; proceed.
```

Substitutions:
- `{PRESET}` = persuasion | deliberation | inquiry | discovery
- `{N}` = number of active roles (excluding compiler for discovery)
- `{role-slug-i}` = role slug (e.g., `defender`, `stakeholder-a`, `verifier`, `explorer-a`)
- `{role-identity-and-axis-i}` = identity + axis from `$DEBATE_DIR/roles/<slug>.md` first 3 lines
- `{preset-specific format file}` = `output-format-{preset}.md`

Anthropic runtime auto-assigns names to teammates; the moderator MUST capture them from runtime feedback into `$DEBATE_DIR/teammates.json`:
```json
{"role-slug-1": "<name1>", "role-slug-2": "<name2>", ...}
```

## Round N (N >= 1, including round 1 if team is already up): Send

For each role's teammate, send via SendMessage:

```
SendMessage(to: "<teammate-name>", message: <round-N focus prompt>)
```

Round-N focus prompt content:
- Peer TL;DRs from previous round (from `$DEBATE_DIR/tldrs/*.md`)
- This-round focus bullets for this role

Anthropic delivers messages automatically; moderator waits for each teammate's reply (each is a Claude response to the SendMessage). When all replies are in, moderator extracts the reply text and writes:
- `$DEBATE_DIR/outputs/<role>-r<N>.md`

The After-round step then runs the same path-based extraction shell loops as in `subagent` mode (see [`claude-subagent.md`](./claude-subagent.md) §"After-round (path-based extraction)"), reading from `outputs/`.

[MUST] Issue all N SendMessage calls in **one assistant message**. Sequential sends would serialize round wall-clock.

## Checkpoint — Compiler (Discovery only) is lead-internal

When Discovery preset reaches a checkpoint (every 3 rounds or all stages = `settle`), the moderator does NOT spawn a Compiler teammate. Instead:

1. Moderator reads `$DEBATE_DIR/tldrs/*.md` + `$DEBATE_DIR/stages/*.txt`
2. Moderator synthesizes Framing Matrix / Missing Axes / Irreducible Divergences / Open Questions itself (in the main session context)
3. Moderator writes result to `$DEBATE_DIR/compiler-output-${N}.md`
4. Same grep guards apply (no "## Recommendation" / "## Best Option" / "## Ranking" allowed)

**Why**: Anthropic's "no nested teams" limitation — teammates can't spawn their own teammates. The moderator (lead) is the only place a Compiler-equivalent can run. Trade-off: loses cross-family Compiler model diversity, but simplifies and avoids "one team at a time per lead" lockout.

## Format correction

When After-round detects null stance / out-of-mutex / bad stage on teammate `T`:

```
SendMessage(to: "<T>", message: <format-correction template content>)
```

Template content is identical to subprocess mode (preset-aware per SKILL §Format-correction). Teammate replies with corrected output → moderator overwrites `outputs/<role>-r<N>.md`.

## Reconcile: replace, don't resume

Anthropic doc: *"No session resumption with in-process teammates: `/resume` and `/rewind` do not restore in-process teammates."*

If a teammate becomes unresponsive (idle hook doesn't fire / SendMessage times out):

1. Moderator emits: `Ask <teammate-name> to shut down`
2. Wait for shutdown confirmation (or treat 30s timeout as gone)
3. Spawn a replacement teammate with the role's accumulated history as the spawn prompt:
   ```
   Spawn a teammate <new-name> using subagent type debate-explorer (or matching role's type).
   Identity and history (catch up from here):
   <contents of $DEBATE_DIR/roles/<role>.md>
   <contents of $DEBATE_DIR/tldrs-history/<role>/r*.md, in round order>
   This-round focus: <current rN-focus-<role>.md>
   ```
4. Update `$DEBATE_DIR/teammates.json` with the new name

This is more expensive than subprocess mode's `--initial-round` reconcile (whole history re-sent), but works within Anthropic team limitations.

## Cleanup

End of debate:
```
Clean up the team
```
Anthropic doc: *"Always use the lead to clean up. Teammates should not run cleanup."*

The moderator emits the cleanup phrase. Anthropic runtime tears down teammates and removes team config / task list. Moderator then `rm -rf $DEBATE_DIR` for debate-side scratch.

## What this mode does NOT do

- Does not invoke agent-session for claude backend (same as subagent mode)
- Does not use `/resume` (broken for in-process teammates)
- Does not spawn Compiler as teammate (lead-internal per user decision)
- Does not support per-role permission modes (Anthropic limitation: teammates inherit lead's permission mode)
- Does not run other agent teams concurrently (Anthropic limitation: one team at a time per lead)
