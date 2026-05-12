---
name: debate
description: "Multi-model multi-role peer debate. Main agent moderates while ≥2 distinct model families argue for/against the original proposal. Detects false consensus via stance tags. Backends abstracted via agent-session."
user-invocable: true
---

# Debate

When the user challenges the current agent's proposal/opinion, organize a multi-model peer discussion to cross-validate the proposal.

## [MUST] Core rules

1. **Multi-model is recommended, not enforced.** The pool is whatever the user configures in `prefs.json`. The skill warns when the pool collapses to a single family but lets the user decide.
2. The main agent is the **moderator**, never a debater. It orchestrates, judges convergence, summarizes, and hands off to the user.
3. Roles are generated **dynamically** for each debate. Identity must be specific to the current proposal/challenge.
4. Sessions **persist across rounds** — each role keeps its own conversation history via [`agent-session`](../agent-session/) (read its SKILL.md for CLI semantics; this skill only references the verbs).
5. **Checkpoint trigger is preset-aware.** Persuasion checkpoints every 3 rounds; Deliberation checkpoints when all stakeholders have contributed and the trade-off is ready to inspect.
6. **Stance tags are mandatory in every output** — Persuasion uses `hold` / `concede` / `add`; Deliberation uses `prefer` / `accept` / `oppose` / `abstain`. They are used to detect false consensus.

> **About model families.** Each driver carries a static `family` hint (claude→anthropic, codex→openai, opencode→openai by default). It's a heuristic for picking the Defender (same family as the main agent) and spreading roles across families. Override per-role via env vars or prefs. opencode is multi-provider; treat its `(openai)` tag as a default, not a fact.

## Usage

```
/debate                                              # auto-analyze current context, infer challenge direction and roles
/debate "I think this proposal has scaling issues"   # specify the challenge
/debate --preset deliberation "Which launch plan should we choose?"  # force Deliberation preset
```

Interactive only. Not auto-invoked by other skills.

---

## Flow

### Step 1: Context Pack

Collect (1) the original proposal, (2) the challenge (user-stated or main-agent-inferred-then-confirmed), (3) project context. Show the user a 4-line confirmation block before proceeding:

```
This debate:
- Original proposal: {summary}
- Challenge: {content}
- Planned roles: Defender + Role A [+ Role B] + Wildcard
  (backends assigned in step 2)

Begin once confirmed.
```

### Step 1.5: Preflight + budget gate

After context confirmation, before any `agent-session spawn`, the moderator runs a short preflight that resolves independent axes and prints **one combined block** the user signs off on:

1. **Language** (for role prose only — section markers stay English):
   ```
   --lang flag → prefs.lang → ≥10 CJK chars in challenge text
   → ≥50% non-Latin script in challenge text → recent 3 user turns' locale
   → $LANG runtime locale → fallback "en"
   ```
   First non-empty match wins. **Always print the chosen value as a visible line** so autodetect doesn't become hidden state.

2. **Parallelism / visualization**:
   ```
   --no-parallel flag → DEBATE_NO_TMUX → has TTY? → tmux on PATH?
   ```
   The `& ... wait` loop in §2.5 / §Round N already runs roles concurrently regardless. Tmux split-pane is *visualization* on top. Print honestly:
   - TTY attached + tmux available → `Parallel: tmux (split panes)`
   - TTY attached, tmux not installed → `Parallel: background subprocess (tmux not found)`
   - **No TTY** (moderator running headless) → `Parallel: background subprocess (no TTY for tmux panes)` — don't promise split panes you won't deliver.

3. **Preset detection**:
   ```
   --preset flag → lib/detect-preset.sh on challenge text → fallback persuasion
   ```
   The auto-detect heuristic matches keywords in the challenge text. If a deliberation indicator is matched, recommend `deliberation`; otherwise default to `persuasion`. The preflight gate always displays which preset is active and why.

4. **Budget estimate**:
   ```
   inter_round   ≈ M_roles × R_planned × 1.7k         (TL;DR piped to disk, moderator doesn't read full Argument)
   checkpoint    ≈ floor(R_planned / 3) × M_roles × 1.5k  (moderator reads full Argument bodies to synthesize)
   tokens_total  ≈ inter_round + checkpoint
   wall-clock    ≈ longest-role-latency × R_planned + 20s × floor(R_planned/3)   (parallel sends + checkpoint synthesis)
   ```
   For M=4, R=6: ~40k inter + ~12k checkpoint ≈ **~52k tokens**. Don't paper over the checkpoint cost — early test runs underestimated by ~30% by ignoring it.

Print one combined gate, wait for user:

```
Language: zh (autodetected from challenge text, override with /debate --lang xx)
Parallel: background subprocess (no TTY for tmux panes)
Preset: <preset-name> (auto, matched "<keyword>" in challenge / default)
        Override with --preset <other> to force.
Debate plan: 4 roles × ~6 rounds ≈ ~52k tokens, ~4 min wall-clock
Begin? (Y/n)  [or self-critique / cancel]
```

For **Deliberation** preset, include stakeholder confirmation in the same gate:

```
Stakeholders (for deliberation):
  A. <stakeholder slug + 1-line description>
  B. <stakeholder slug + 1-line description>
  C. <stakeholder slug + 1-line description>
Edit list? (Y/n)  Default: use as-is
```

The moderator extracts 2-4 stakeholders from the challenge text. If the user replies `edit`, they provide the replacement list before spawn.

The running token counter reappears at the checkpoint trigger:

```
Tokens: ~Xk used / ~52k planned (estimate)
```

(The 1.7k / 1.5k constants are rough — future telemetry will replace with per-driver real counts. See `agent-session doctor` for auth-identity collisions that make the cross-family premise notional.)

### Step 2: Plan & spawn

#### 2.1 Workspace

```bash
DEBATE_ID=$(date +%s%N | md5sum | head -c4)
DEBATE_DIR="/tmp/debate-${DEBATE_ID}"
SESSIONS_DIR="${DEBATE_DIR}/sessions"
mkdir -p "$SESSIONS_DIR"
```

`SESSIONS_DIR` is the shared state directory passed to every `spawn` / `send` / `output` / `cleanup` call. Cleanup is `rm -rf "$DEBATE_DIR"`.

The whole `$DEBATE_DIR` (workspace + sessions storage that lives under it) is debate's transient scratch — at debate end, removing it is part of cleanup (see §Step 5).

#### 2.2 Backend preflight

Run `agent-session doctor`. If it reports `Multi-model capability: ✗`, **warn** the user (don't abort):

```
Heads up: only one model family detected (anthropic). Debate will run
single-family — the false-consensus guard via stance tags still works,
but cross-family disagreement won't surface. Continue? (Y/n)
```

#### 2.2.5 Load / bootstrap user prefs

Path: `~/.config/agents/debate/prefs.json` (XDG, vendor-neutral). Schema:

```json
{
  "version": 1,
  "lang": null,
  "agents": [
    { "backend": "claude",   "model": null },
    { "backend": "opencode", "model": null }
  ]
}
```

- `agents` is the **pool** — backends to draw from, not a fixed role assignment. `model: null` means "let the backend pick its own default".
- `lang` (optional, flat): `null` = autodetect (see §2.5.1); explicit ISO-639-1 (`"en"`, `"zh"`, …) pins the language for **role prose**. Section markers (`## TL;DR`, `[stance: …]`, `## Argument`) stay English regardless.

The `lang` field is additive — older `prefs.json` files (no `lang`) keep working.

**First-run bootstrap (file missing).** Show the doctor output and ask the user *which backends to include* — don't default to "all" silently.

| Runtime | Mechanism |
|---|---|
| Claude Code (`AskUserQuestion` available) | `AskUserQuestion` with `multiSelect: true`, one option per detected backend (label = name, description = path). |
| Codex CLI / opencode / other | Plain text prompt with numbered list; user replies with comma-separated subset (e.g. `1,2`) or `all`. |

Don't tag backends with a family in the picker — opencode is multi-provider and `(openai)` is misleading.

After the user picks, write the file with the chosen subset, each `model: null`.

**Empty-selection guard.** If the user submits zero backends (`AskUserQuestion` with nothing checked, or empty/`0`/whitespace reply in plain-text mode), do **not** write `prefs.json`. Re-prompt once, prefixed with: *"Debate needs at least one backend in the pool. Pick one or more, or reply `cancel` to abort."* If the second attempt is also empty (or the user replies `cancel`), abort `/debate` with one line — *"`/debate` aborted — no backends selected. Run again any time."* — and exit before any `agent-session spawn`. The file must never exist with `agents: []`; downstream §2.3 P3 assumes ≥1 entry.

**Incremental update (file exists, pool drifted).** Compare prefs.agents vs `agent-session list-backends`:

- New backend detected, not in prefs → ask "add `<name>` to your debate pool?"
- Backend in prefs no longer detected → ask "remove `<name>` from pool?"

Same hybrid prompt rule. The user can also instruct in conversation (*"add codex to my debate pool"*); the agent rewrites the file.

The pool must have ≥1 backend. Single-family pools surface the §2.2 warning.

#### 2.3 Per-role assignment algorithm

The algorithm depends on the active preset. Both presets share the priority chain (inline override > env var > pool entry > pool default), but the role set differs.

##### 2.3-a Persuasion preset (existing)

Each role resolves to one `(backend, model)` via priority chain (high → low):

```
P1. Inline override ("this debate, let codex be defender") — highest
P2. $DEBATE_<ROLE>_BACKEND / $DEBATE_<ROLE>_MODEL  (env, this shell)
P3. Main-agent assignment from the prefs pool:
    Defender → pool entry whose family matches the main agent's family
               (Claude Code→anthropic, Codex CLI→openai, etc.)
               If none match, pick the first entry.
    Role A   → first cross-family pool entry, OR next pool entry if
               no cross-family option exists.
    Role B   → optional, decided by **topic need** — include only if
               the challenge has a clearly distinct second examination
               angle from Role A. Same model with a different angle
               is fine; do NOT skip just because pool is small.
    Wildcard → always present. Free-form divergent thinker, NOT scoped
               to a specific examination angle. Prefer cross-family
               for perspective drift; fall back to any pool entry.
```

**Model resolution** (after agent fixed): env var → `prefs[*].model` → `null` (let the backend pick its default).

Env vars: `DEBATE_<ROLE>_BACKEND` / `DEBATE_<ROLE>_MODEL`, where `<ROLE>` ∈ `DEFENDER` / `ROLE_A` / `ROLE_B` / `WILDCARD`.

##### 2.3-b Deliberation preset

Roles are N stakeholders (2-4, from preflight §1.5 stakeholder list) + 1 synthesizer.

```
For each stakeholder S in confirmed-list:
  S → next-pool-entry, rotating through pool to maximize family diversity
Synthesizer → cross-family from majority of stakeholders
              (the synthesizer must NOT share the family of >50% of stakeholders;
               diversity is its structural function)
```

**Example**: 3 stakeholders, 2 are claude-family → synthesizer must be a non-claude family (e.g. openai). 2 stakeholders, both claude-family → synthesizer must NOT be claude-family. 2 stakeholders of different families → synthesizer can be either family.

Model resolution follows the same priority chain as Persuasion (env → pool → default).

Stakeholder identity at spawn = `<slug>: <1-line description>` from preflight, prepended to the role's first-turn prompt.

#### 2.3.1 Print decision and confirm

```
Debate assignment:
  Defender = claude   (default model)        — defends the proposal
  Role A   = opencode (default model)        — examines: <angle>
  [Role B  = codex    (gpt-5.4-mini)]        — examines: <second angle>
  Wildcard = opencode (anthropic/claude-opus) — free-form divergent
Pool source: ~/.config/agents/debate/prefs.json
Begin? (Y/n)
```

If single-family, prepend: `Note: all roles share family "X" — debate may converge fast.`

#### 2.3.2 Role identities

A debate has 3 or 4 roles. The main agent constructs identities — keep them specific to *this* discussion (generic identities like "security expert" are forbidden for the focused critics).

| Role | Mandatory? | Identity rule |
|---|---|---|
| Defender | yes | Defends the original proposal; concedes if it genuinely has flaws. |
| Role A | yes | Specific examination angle (e.g. "audits the token-refresh replay-attack surface in this JWT proposal"). |
| Role B | topic-conditional | A *clearly distinct* second angle. Skip if it would just paraphrase Role A. |
| Wildcard | yes | **Not** scoped to an angle. May raise issues outside the user's stated challenge — that is the value. |

#### 2.4 Prompt files (uses references/)

For each role's first-turn input, concatenate:
- The shared context (§2.1)
- The role's identity template from `references/roles/<role-name>.md`
- The preset's output-format spec from `references/output-format-<preset>.md`

For Persuasion: `output-format-persuasion.md`. For Deliberation: `output-format-deliberation.md`.

The system prompt at spawn for each role MUST include the preset's stance whitelist, which the role uses internally to constrain its `[stance: ...]` line.

The shared context is `$DEBATE_DIR/shared-context.md` (the original proposal + challenge + project context the moderator writes). Role identity modules live under `references/roles/`; Persuasion uses `defender.md`, `role-a.md`, `role-b.md`, and `wildcard.md`; Deliberation uses `stakeholder.md` for each confirmed stakeholder and `synthesizer.md` for the integrator.

The complete registry of prompt modules — paths, load points, and per-module invariants — lives in [`references/_manifest.yaml`](./references/_manifest.yaml). Smoke tests in `tests/manifest-invariants.sh` verify the registry.

When you modify a module: also update its invariants in the manifest if behavior changes, then re-run `tests/manifest-invariants.sh` before committing.


#### 2.5 Spawn roles

Debate needs a **persistent multi-turn session per role**, with shared lifetime so cleanup is collective. Use [agent-session](../agent-session/SKILL.md)'s `spawn` verb to create each role's session — debate supplies role identity (Persuasion: defender / role-a / role-b / wildcard; Deliberation: stakeholder roles / synthesizer), model preference (resolved in §2.3), the role's first-turn input (§2.4), and a system prompt that requires debate's preset-specific output schema. Run all spawns in parallel — round-1 prompts are independent, so wall-clock equals the slowest role's latency. Skip `role-b` when §2.3 made it topic-conditional.

**[MUST] Pass `--timeout 900` at spawn time.** agent-session's default ceiling (1800s) is generous, but `spawn` persists `meta.timeout` for the entire session lifetime — if you don't set it explicitly, sends inherit whatever the env was when spawn ran. Empirically, gpt-5.5-class reasoning models on round-3+ resumes can take 200-400s per turn; 900s gives ~3x headroom. If a specific round still trips it, `send --force --timeout 1500` bumps and retries (see §Round N).

```bash
# Derive whitelist from preset
case "$PRESET" in
  persuasion)   STANCE_WHITELIST="hold,concede,add" ;;
  deliberation) STANCE_WHITELIST="prefer,accept,oppose,abstain" ;;
esac

# Used in Round N send (parallel pids[]), output verification, and After-round tldr extraction loops
# Per-preset role list — used in Round N send/verify loops and After-round tldr extraction
case "$PRESET" in
  persuasion)
    ACTIVE_ROLES=(defender role-a role-b wildcard)
    # role-b conditional per §2.3-a; remove from array if topic doesn't justify a second focused angle
    ;;
  deliberation)
    ACTIVE_ROLES=("${STAKEHOLDER_SLUGS[@]}" synthesizer)
    # STAKEHOLDER_SLUGS is the confirmed stakeholder list from preflight §1.5
    ;;
esac

# When extracting TL;DRs after each round, pass the whitelist:
# agent-session tldr --role-id "$r" --state-dir "$SESSIONS_DIR" \
#   --stance-whitelist "$STANCE_WHITELIST"
```

The `agent-session spawn` and `send` calls themselves don't change — the stance whitelist only affects post-hoc tldr extraction.

After this step, each role's first-turn reply is observable via agent-session's `output` and `tldr` verbs; the role's full conversation history is owned by agent-session and never re-supplied by debate.

For tmux *split-pane visualization* (not parallelism — concurrency comes from `& ... wait`): see [`references/parallel-tmux.md`](./references/parallel-tmux.md).

### Step 3: Discuss

#### Round 1

For each role, retrieve its first-turn reply via agent-session's `output` verb. Record divergence and consensus. Treat the Wildcard's contribution as a *second-axis* signal — it may surface concerns orthogonal to the focused critics; don't force-merge.

#### Round N (subsequent)

Build an incremental prompt: only other roles' previous-round TL;DRs + this round's focus. The session already holds prior context; do not repeat the proposal/challenge.

**[MUST] One shared prompt file per round, assembled by shell — not by quoting role outputs into the moderator's assistant message.** This is the single biggest source of context bloat: dumping every role's TL;DR into the moderator's message stream every round adds ~100 tokens × M_roles × N_rounds. The moderator should never need to read or re-quote a TL;DR to assemble the next round.

##### After-round step (runs immediately after every round finishes)

For each active role, retrieve the latest-round TL;DR + stance via agent-session's `tldr` verb (returns JSON `{role_id, round_count, tldr_text, stance}`). Cache `tldr_text` to `$DEBATE_DIR/tldrs/<role-id>.md` and `stance` to `$DEBATE_DIR/stances/<role-id>.txt` so the next-round assembly and the false-consensus guard can read them without invoking the verb again. **The moderator never reads these JSON values into its own assistant message** — the verb output goes through `jq` straight to disk:

```bash
case "$PRESET" in
  persuasion)   STANCE_WHITELIST="hold,concede,add" ;;
  deliberation) STANCE_WHITELIST="prefer,accept,oppose,abstain" ;;
esac

mkdir -p "$DEBATE_DIR/tldrs" "$DEBATE_DIR/stances"
for r in "${ACTIVE_ROLES[@]}"; do
  agent-session describe --role-id "$r" --state-dir "$SESSIONS_DIR" >/dev/null 2>&1 || continue
  json=$(agent-session tldr \
    --role-id "$r" --state-dir "$SESSIONS_DIR" \
    --stance-whitelist "$STANCE_WHITELIST")
  echo "$json" | jq -r '.tldr_text // ""' > "$DEBATE_DIR/tldrs/$r.md"
  echo "$json" | jq -r '.stance    // "null"' > "$DEBATE_DIR/stances/$r.txt"
done
```

`ACTIVE_ROLES` is the per-preset role list set up at spawn, e.g. `(defender role-a role-b wildcard)` for Persuasion or `(stakeholder-A stakeholder-B stakeholder-C synthesizer)` for Deliberation.

The output extraction format (i.e. how `## TL;DR` and `[stance: ...]` get parsed) is owned by agent-session — debate only consumes the structured fields. A role with `stance: null` cached here is the canonical signal handled in §False-consensus guard.

##### Pre-round step (assembling rN.md without reading TL;DRs)

Concatenate `tldrs/*.md` into a single shared `$DEBATE_DIR/rN.md` under a `## Last round, other participants (TL;DR)` header (one `### <role-id>` subsection each). Pure shell — `cat`, no Read tool. Then append a `## Focus this round` block with one bullet per role (1-2 lines each).

The focus bullets are the **only** content from this round that the moderator types into its own assistant message — typically ~4 lines.

##### Send (parallel)

Pass the SAME `rN.md` to every role via agent-session's `send` verb, dispatched **in parallel**. Sequential within-round dispatch is not required — the prompt only references round N-1, so there's no in-round dialogue — and roughly doubles wall-clock.

**[MUST] Collect per-role exit codes AND verify output.** A bare `wait` without arguments only waits, it doesn't surface individual failures. A round where `agent-session send` rejected a flag (e.g. `unrecognized arguments`) silently and `tldr` later returns the *previous round's* cached output is the classic false-success trap. Use this hardened pattern:

```bash
pids=()
for r in "${ACTIVE_ROLES[@]}"; do
  agent-session send --role-id "$r" \
    --prompt-file "$DEBATE_DIR/rN.md" \
    --state-dir "$SESSIONS_DIR" &
  pids+=("$!:$r")
done

failed=()
for entry in "${pids[@]}"; do
  pid="${entry%%:*}"; role="${entry##*:}"
  wait "$pid" || failed+=("$role:rc=$?")
done

# Belt + suspenders: even a 0-exit send is suspect if output is empty or missing the format marker.
for r in "${ACTIVE_ROLES[@]}"; do
  out=$(agent-session output --role-id "$r" --state-dir "$SESSIONS_DIR" 2>/dev/null)
  echo "$out" | grep -q '^## TL;DR' || failed+=("$r:no-tldr")
done

[ ${#failed[@]} -gt 0 ] && echo "round N failed for: ${failed[*]}" >&2
```

If failures came from timeout (`meta.error` contains `timed out`), retry that role only with `send --force --timeout 1500` before moving on:

```bash
for entry in "${failed[@]}"; do
  role="${entry%%:*}"
  err=$(agent-session describe --role-id "$role" --state-dir "$SESSIONS_DIR" | jq -r '.error // ""')
  if echo "$err" | grep -q "timed out"; then
    agent-session send --role-id "$role" --force --timeout 1500 \
      --prompt-file "$DEBATE_DIR/rN.md" --state-dir "$SESSIONS_DIR"
  fi
done
```

If you want Defender to rebut this-round critic arguments, do it as an **optional follow-up half-round** (one extra `send` to Defender after collecting the others' r_N), not by ordering the main round. Reserve for the round just before a checkpoint.

For tmux split panes (visualization, not parallelism — sends already run concurrently): see [`references/parallel-tmux.md`](./references/parallel-tmux.md).

##### Partial-success rounds

Real debates produce ragged matrices — a role times out at round N while others reach N+1. Don't block the whole debate on alignment. Policy:

- Each role's contribution to any aggregate (checkpoint, false-consensus distribution, conclusion) = **that role's latest successful round's TL;DR**.
- Checkpoint headers must report the per-role round explicitly:

  ```
  ## Discussion progress @ Round 3 checkpoint
  (Defender @ R2, Role A @ R3, Role B @ R2, Wildcard @ R3)
  ```

- A role that's behind is itself a false-consensus signal — note it in the Divergence section ("Role B has not yet responded to round-3 focus; convergence claim is premature without that perspective").
- `round_count` is per-role, owned by agent-session's meta. Don't try to fake-align by sending an empty turn to the lagging role — the gap is *information*, not noise.
- Optional: at the checkpoint, the moderator can decide to revive a stuck role (`send --force --timeout 1800`) one more time before declaring the gap structural.

#### [MUST] Read strategy (token saving)

The main agent has a context window. Each round's full Argument bodies × N rounds × M roles will exhaust it. Three rules:

**(a) Inter-round TL;DRs never enter the moderator's message.** The After-round step calls agent-session's `tldr` verb and pipes the JSON through `jq` straight to `tldrs/<role>.md` and `stances/<role>.txt`; the Pre-round step `cat`s `tldrs/*.md` into `rN.md`. The moderator's only inter-round contribution to its own context is the 4-line focus block.

**(b) Read TL;DRs only at the checkpoint trigger.** When you reach a checkpoint, *then* the moderator may `cat $DEBATE_DIR/tldrs/*.md` once to synthesize the preset-specific checkpoint block. Read the full Argument only when the user asks or when the stance distribution warrants verification.

**(c) Never re-quote role outputs into the assistant message.** When a tool result surfaced a 200-line role output, do NOT re-include it verbatim "to show the user what each said" — the user can `cat` the file themselves. Each role's session already holds its full history (agent-session owns that) — the moderator never needs to repeat anything.

#### [MUST] False-consensus guard

After the After-round step has cached each role's stance, inspect the distribution. **Roles with `stance: null` are a separate signal** — they indicate output-format drift (the role's reply did not match `references/output-format-<preset>.md`), not a stance position. Investigate before trusting the round's data.

##### Distribution interpretation by preset

For **persuasion**:

| Distribution | Convergence | Action |
|---|---|---|
| All `hold` | Low | Switch focus or continue |
| Mostly `concede` | High | Local convergence; advance or end |
| All `add` | — | **Parallel without dialogue — beware false consensus**; read full arguments |
| Mixed | Medium | Decide via TL;DR content |
| **≥1 `null` stance** | **Format drift** | **Apply the format-correction escalation below before deciding to re-spawn or read past the round.** |

For **deliberation**:

| Distribution | Convergence | Action |
|---|---|---|
| All `prefer` or `accept`, none `oppose` | Trade-off resolved | Can checkpoint early; produce trade-off matrix conclusion. |
| Any `oppose` | Irreducible conflict | Continue to surface trade-off; user must decide. |
| Majority `abstain` | Stakeholder list wrong | Re-extract stakeholders; restart preflight. |
| Mixed `prefer` and `oppose` | Core tension | Continue rounds; test if positions are flexible under refinement. |
| ≥1 `null` stance | Format drift | Apply Format-correction escalation (see §False-consensus guard, Persuasion section). Same procedure regardless of preset. |

Text similarity is unreliable. Same TL;DR + different stance tags = strongest false-consensus warning. A `null` stance amid otherwise-valid stances does **not** count as "Mostly X" — it must be resolved first.

##### Format-correction escalation (for `null` stance)

Re-spawning is expensive (loses the role's full conversation history) and reading past the issue is dishonest. Add a cheap intermediate step:

1. **Single-turn format-correction send** to the affected role (~1 small send per role):

   ```
   Your previous reply did not match the required output format.
   Send a corrected reply using EXACTLY this format:

     ## TL;DR
     <2-3 sentences>
     [stance: <one value from the active preset whitelist>]   ← pick ONE from the closed set, no compound stances

     ## Argument
     <body>

   Do not explain the issue. Send only the corrected reply.
   ```

   ```bash
   agent-session send --role-id "<role>" \
     --prompt-file "$DEBATE_DIR/format-correction.md" \
     --state-dir "$SESSIONS_DIR"
   ```

2. Re-run the `tldr` extraction for that role with the active preset's `--stance-whitelist`. If stance is now in the active whitelist, the corrected reply **replaces** the prior round's cached TL;DR — continue with the round's stance distribution as if nothing went wrong.

3. If stance is still `null` after one correction attempt, treat the distribution as unresolved and choose:
   - **Re-spawn** the role (last resort — loses prior context) — useful if the role's reasoning is also drifting.
   - **Edit `references/output-format-<preset>.md`** if the format itself is the root cause (run `tests/manifest-invariants.sh` after).
   - **Continue with the role excluded from this round's distribution** — note it explicitly in the checkpoint Divergence section ("Role X had unresolved format drift in round N; their stance is unknown").

[MUST] If you take option (a) or (c), say so in your reply to the user — silent skill deviation is worse than the format drift itself.

#### Checkpoint trigger (preset-aware)

For **persuasion**: every 3 rounds (unchanged).

For **deliberation**: all stakeholders have contributed ≥1 round AND (round_count ≥ 3 OR all stances ∈ {prefer, accept}).

**Example**: 3 stakeholders, round 2, stances `{prefer, accept, prefer}` → fires (all contributed AND all-prefer-accept; trade-off resolved). Same setup at round 2 with stances `{prefer, oppose, accept}` → does NOT fire (need round ≥ 3 because the `oppose` indicates unresolved tension worth more rounds).

The checkpoint display also differs:
- Persuasion: Consensus / Divergence / Moderator judgment / You decide (unchanged).
- Deliberation: Trade-off matrix (option × stakeholder cells) / Synthesizer recommendation / You decide.

For **persuasion**:

[MUST] Pause and present:

```markdown
## Discussion progress (rounds N–N+2)

### Consensus
- {points all parties agreed on}

### Divergence
- {view A} vs {view B} — core reason: {...}

### Moderator judgment
- Convergence level: {High/Medium/Low}
- Suggestion: {continue along X / sufficient to decide}

### You decide
- {specific decision points}
```

For **deliberation**:

```markdown
## Discussion progress @ Round N checkpoint
(Stakeholder A @ R2, Stakeholder B @ R3, Synthesizer @ R3)  // ragged matrix per Partial-success policy

### Trade-off matrix
| Option | <stakeholder-A> | <stakeholder-B> | ... |
|--------|-----------------|-----------------|-----|
| Plan X | prefer          | oppose          | ... |

### Synthesizer recommendation
(content)

### You decide
- {decision points}
```

User responses: "continue" → 3 more rounds; "switch direction" → adjust focus; "enough" → Step 4.

##### [MUST] Running summary (so later checkpoints don't re-read early rounds)

After printing each checkpoint to the user, append the same block to `$DEBATE_DIR/running-summary.md`:

```bash
{
  echo
  echo "---"
  echo "## Checkpoint after rounds $((N-2))-$N"
  cat <<'EOF'
{paste the same Consensus / Divergence / Judgment block you just showed the user}
EOF
} >> "$DEBATE_DIR/running-summary.md"
```

At the **second** checkpoint (rounds 4–6) and beyond, the moderator reads `running-summary.md` (compact, accumulating) instead of re-reading every round's TL;DRs. The current round's `tldrs/*.md` is still read for fresh synthesis, but the moderator does not re-read tldrs from rounds you've already summarized.

This means the moderator's context grows by one ~15-line summary per checkpoint, not by 4 × 5-line TL;DRs × every round.

### Step 4: Conclude

For **persuasion**:

```markdown
## Conclusion

### Original proposal
{brief}

### Final recommendation
{improved proposal after discussion, or keep original}

### Key arguments
- Defender's view: {...}
- {Role A}'s view: {...}
- [{Role B}'s view: {...}]
- Wildcard's divergent take: {...}

### Unresolved divergence (if any)
- {...}
```

For **deliberation**:

```markdown
## Conclusion

### Original challenge
{brief}

### Stakeholders (confirmed)
{list}

### Trade-off matrix
{full table}

### Dominant option (if any)
{option that's prefer/accept by all, none oppose; or "no dominant option"}

### Irreducible trade-offs
{what needs explicit user decision because no dominant option}

### Decision recommendation
{synthesizer's one-line take}
```

### Step 5: Cleanup

[MUST] Runs automatically — don't wait for the user.

Debate ends by terminating every role session it created (use agent-session's `cleanup` verb per role) and removing its own scratch workspace (`$DEBATE_DIR` from §2.1). Cleanup must be idempotent — repeating it is a no-op; ignore "session not found" errors.

For tmux split mode see [`references/parallel-tmux.md`](./references/parallel-tmux.md) for its analogous cleanup.

---

## Dependencies

- **`agent-session` skill** (hard) — backend abstraction; same repo
- **≥1 backend CLI** — claude / opencode / codex / gemini / etc; ≥2 distinct families recommended
- **tmux** (optional) — parallel spawn, see [`references/parallel-tmux.md`](./references/parallel-tmux.md)

## Exception handling

| Situation | Handling |
|---|---|
| `agent-session spawn` fails | Read stderr; the role is `failed` in `meta.json`. Retry on a different backend, or proceed without (mark `[failed]` in checkpoint). |
| `agent-session send` fails mid-round | Skip that role this round; log; continue with the others. |
| Role output empty | Likely a backend hiccup; retry once via `send`; if still empty, skip this round. |
