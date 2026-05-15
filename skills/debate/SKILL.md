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

2. **Live progress visibility**: roles run concurrently via the `& ... wait` loop in §2.5 / §Round N. To watch per-role output in real time, the user can run `tail -F $DEBATE_DIR/logs/send-*.log` in a separate shell. The preflight gate just prints the path so they know where.

3. **Claude backend mode autodetect** (only applies when at least one role would use the `claude` backend; opencode/codex are not affected):
   ```
   --claude-backend flag → DEBATE_CLAUDE_BACKEND env → claude.ai auth + CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 → claude.ai auth → fallback subprocess
   ```
   Three modes:
   - `subprocess` — existing agent-session path. **6/15 warning**: post-2026-06-15 this consumes the user's Agent SDK credit pool (Max 5x = $100/mo) rather than subscription quota.
   - `subagent` — Agent tool dispatch with cumulative-history files. Consumes main session subscription quota. See [`references/modes/claude-subagent.md`](./references/modes/claude-subagent.md).
   - `teammates` — Anthropic Agent Teams (experimental, requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and Claude Code v2.1.32+). Persistent teammate sessions, SendMessage communication. Compiler is lead-internal. See [`references/modes/claude-teammates.md`](./references/modes/claude-teammates.md).

   Run [`lib/detect-claude-backend.sh`](./lib/detect-claude-backend.sh) to compute the recommendation. The script reads auth via `claude auth status` (or a fixture path for tests) and the env vars above. Print the chosen mode + reason in the gate so the user can override.

   **[MUST] Export the detected mode** as `CLAUDE_BACKEND_MODE` so it is visible to later sections (§2.5 Spawn, §Round N Send, §Reconcile, §Compiler, §Cleanup all branch on it):
   ```bash
   CLAUDE_BACKEND_MODE=$(bash skills/debate/lib/detect-claude-backend.sh)
   export CLAUDE_BACKEND_MODE
   ```

4. **Preset detection**:
   ```
   --preset flag → lib/detect-preset.sh on challenge text → fallback persuasion
   ```
   The auto-detect heuristic matches keywords in the challenge text. If a deliberation indicator matches, recommend `deliberation`; if a discovery indicator matches, recommend `discovery`; if an inquiry indicator matches, recommend `inquiry`; otherwise default to `persuasion`. The preflight gate always displays which preset is active and why.

5. **Budget estimate**:
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
Live progress: tail -F $DEBATE_DIR/logs/send-*.log (run in another shell to watch per-role output)
Claude backend mode: <mode> (<reason>)
        Override with --claude-backend [subprocess|subagent|teammates].
        6/15 note: 'subprocess' burns Agent SDK credit (~$100/mo Max 5x); 'subagent' and 'teammates' consume subscription quota.
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

For **Discovery** preset, include framing-axes confirmation in the same gate:

```
Framing axes (for discovery):
  A. <axis slug + 1-line description, extracted from challenge text>
  B. <axis slug + 1-line description>
  C. <axis slug + 1-line description>
  [D. (optional fourth axis)]
Edit list? (Y/n)  Default: use as-is
```

The moderator extracts 3-4 framing axes from the challenge text. If the user replies `edit`, they provide the replacement list before spawn. Each axis becomes one Explorer's framing.

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
TLDRS_HISTORY="${DEBATE_DIR}/tldrs-history"  # per-role accumulated TL;DRs for reconcile
mkdir -p "$SESSIONS_DIR" "$TLDRS_HISTORY" "$DEBATE_DIR/roles"
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

##### 2.3-c Inquiry preset

Roles are 4 fixed investigative roles: verifier, falsifier, triangulator, wildcard. No "defender" — Inquiry has no proposal to defend, only a hypothesis to investigate from three complementary angles plus a divergent angle.

```
Verifier     → pool entry whose family matches the main agent's family (anchor).
               If none match, first entry.
Falsifier    → cross-family entry (different epistemics catch different counter-evidence).
Triangulator → next pool entry, prefer cross-family from Verifier.
Wildcard     → cross-family for perspective drift; fall back to any.
```

Model resolution follows the same priority chain (env → pool → default).

Inquiry roles are fixed (4 total). The hypothesis itself, extracted from challenge text in §1.5, is prepended to every role's first-turn prompt as `Hypothesis under examination: <text>`.

##### 2.3-d Discovery preset

Roles are 3-4 Explorers + 1 Compiler + 1 Wildcard. Each Explorer represents one **framing axis** — extracted from challenge text in §1.5 preflight, confirmed by user.

```
For each framing axis F in confirmed-axes-list (3-4 of them):
  Explorer-F → next-pool-entry, rotating to maximize family diversity
Compiler  → cross-family from majority of Explorers
              (Compiler structurally must NOT share the family of >50%
               of Explorers — diversity is a hedge against bias propagation
               in the synthesis step)
Wildcard  → cross-family from majority for premise-challenging perspective drift
```

Model resolution follows the same priority chain.

Framing axis extraction (§1.5):
- main agent reads challenge text and proposes 3-4 distinct framing axes
- preflight gate displays them; user can edit before spawn (default: accept)
- each axis becomes a `<slug>: <1-line description>` prepended to that Explorer's first-turn prompt

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

For Persuasion: `output-format-persuasion.md`. For Deliberation: `output-format-deliberation.md`. For Inquiry: `output-format-inquiry.md`. For Discovery: `output-format-discovery.md`.

The system prompt at spawn for each role MUST include the preset's stance whitelist, which the role uses internally to constrain its `[stance: ...]` line.

The shared context is `$DEBATE_DIR/shared-context.md` (the original proposal + challenge + project context the moderator writes). Role identity modules live under `references/roles/`; Persuasion uses `defender.md`, `role-a.md`, `role-b.md`, and `wildcard.md`; Deliberation uses `stakeholder.md` for each confirmed stakeholder and `synthesizer.md` for the integrator.

The complete registry of prompt modules — paths, load points, and per-module invariants — lives in [`references/_manifest.yaml`](./references/_manifest.yaml). Smoke tests in `tests/manifest-invariants.sh` verify the registry.

When you modify a module: also update its invariants in the manifest if behavior changes, then re-run `tests/manifest-invariants.sh` before committing.


#### 2.5 Spawn roles

Debate needs a **persistent multi-turn session per role**, with shared lifetime so cleanup is collective. Use [agent-session](../agent-session/SKILL.md)'s `spawn` verb to create each role's session — debate supplies role identity (Persuasion: defender / role-a / role-b / wildcard; Deliberation: stakeholder roles / synthesizer), model preference (resolved in §2.3), the role's first-turn input (§2.4), and a system prompt that requires debate's preset-specific output schema. Run all spawns in parallel — round-1 prompts are independent, so wall-clock equals the slowest role's latency. Skip `role-b` when §2.3 made it topic-conditional.

**[MUST] Before each spawn, save the assembled per-role identity prompt** (shared context + role template from §2.4) to `$DEBATE_DIR/roles/${r}.md`. This file is the reconcile anchor — if the role's session is lost mid-debate, §Reconcile re-uses it to rebuild context without re-reading the original source files.

**[MUST] Pass `--timeout 900` at spawn time.** agent-session's default ceiling (1800s) is generous, but `spawn` persists `meta.timeout` for the entire session lifetime — if you don't set it explicitly, sends inherit whatever the env was when spawn ran. Empirically, gpt-5.5-class reasoning models on round-3+ resumes can take 200-400s per turn; 900s gives ~3x headroom. If a specific round still trips it, `send --force --timeout 1500` bumps and retries (see §Round N).

**[MUST] Pass `--yolo` on every `agent-session spawn` / `send` / `run` call.** Without it, opencode backend blocks on its interactive permission prompt (no stdin to approve), and the role's child process sits at 0% CPU forever — manifests as 0-byte log files, role stuck at the prior round_count, and the entire debate stalls until manually killed. claude backend inherits permission context from the Claude Code parent and so does not exhibit the symptom — the failure is opencode-specific but unpredictable per round. Debate is a trusted analysis context (CLAUDE.md guidance), so `--yolo` is correct here; the agent-session binary translates it to `--dangerously-skip-permissions` for opencode and the equivalent for other backends. **Confirmed 2026-05-14**: a 5-role discovery debate stalled three rounds in a row at exactly the 3 opencode roles before the missing flag was identified.

```bash
# Derive whitelist from preset
case "$PRESET" in
  persuasion)   STANCE_WHITELIST="hold,concede,add" ;;
  deliberation) STANCE_WHITELIST="prefer,accept,oppose,abstain" ;;
  inquiry)      STANCE_WHITELIST="supports,refutes,lateral,inconclusive" ;;
  discovery)    STANCE_WHITELIST="expand,challenge,connect,converge" ;;
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
  inquiry)
    ACTIVE_ROLES=(verifier falsifier triangulator wildcard)
    # All 4 fixed; no conditional roles.
    ;;
  discovery)
    # EXPLORER_SLUGS is the confirmed framing-axis list from preflight §1.5
    # Compiler runs only at checkpoint (not per-round); not in ACTIVE_ROLES
    ACTIVE_ROLES=("${EXPLORER_SLUGS[@]}" wildcard)
    ;;
esac

# When extracting TL;DRs after each round, pass the whitelist:
# agent-session tldr --role-id "$r" --state-dir "$SESSIONS_DIR" \
#   --stance-whitelist "$STANCE_WHITELIST"
```

The `agent-session spawn` and `send` calls themselves don't change — the stance whitelist only affects post-hoc tldr extraction.

After this step, each role's first-turn reply is observable via agent-session's `output` and `tldr` verbs; the role's full conversation history is owned by agent-session and never re-supplied by debate.

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
  inquiry)      STANCE_WHITELIST="supports,refutes,lateral,inconclusive" ;;
  discovery)    STANCE_WHITELIST="expand,challenge,connect,converge" ;;
esac

# Per-role narrowed whitelist (see "Per-role stance whitelist" subsection below).
# For Persuasion / Deliberation the role-narrowed whitelist == preset-wide whitelist.
role_stance_whitelist() {
  local preset="$1" role="$2"
  case "$preset" in
    inquiry)
      case "$role" in
        verifier)     echo "supports,inconclusive" ;;
        falsifier)    echo "refutes,inconclusive" ;;
        triangulator) echo "lateral,inconclusive" ;;
        *)            echo "$STANCE_WHITELIST" ;;   # wildcard: full preset whitelist
      esac
      ;;
    discovery)
      case "$role" in
        wildcard)     echo "$STANCE_WHITELIST" ;;   # wildcard: full preset whitelist
        *)            echo "expand,connect,converge" ;;  # Explorers: no `challenge`
      esac
      ;;
    *)
      echo "$STANCE_WHITELIST"
      ;;
  esac
}

mkdir -p "$DEBATE_DIR/tldrs" "$DEBATE_DIR/stances"
for r in "${ACTIVE_ROLES[@]}"; do
  agent-session describe --role-id "$r" --state-dir "$SESSIONS_DIR" >/dev/null 2>&1 || continue
  rwl=$(role_stance_whitelist "$PRESET" "$r")
  json=$(agent-session tldr \
    --role-id "$r" --state-dir "$SESSIONS_DIR" \
    --stance-whitelist "$rwl")
  echo "$json" | jq -r '.tldr_text // ""' > "$DEBATE_DIR/tldrs/$r.md"
  echo "$json" | jq -r '.stance    // "null"' > "$DEBATE_DIR/stances/$r.txt"
  # Also append to per-role accumulated history (for reconcile re-spawn context)
  mkdir -p "$TLDRS_HISTORY/$r"
  echo "$json" | jq -r '.tldr_text // ""' > "$TLDRS_HISTORY/$r/r${N}.md"
done
```

`ACTIVE_ROLES` is the per-preset role list set up at spawn, e.g. `(defender role-a role-b wildcard)` for Persuasion or `(stakeholder-A stakeholder-B stakeholder-C synthesizer)` for Deliberation.

The output extraction format (i.e. how `## TL;DR` and `[stance: ...]` get parsed) is owned by agent-session — debate only consumes the structured fields. A role with `stance: null` cached here is the canonical signal handled in §False-consensus guard.

###### Per-role stance whitelist (Inquiry / Discovery)

`role_stance_whitelist` narrows the preset-wide whitelist to the closed set each role
is allowed to emit, then feeds that narrowed set into `agent-session tldr
--stance-whitelist`. **This is THE runtime enforcement mechanism for per-role mutex.**
Without it, agent-session would accept any preset-level stance — e.g. Verifier
outputting `refutes` would slip through silently because `refutes` is in the
preset's `supports,refutes,lateral,inconclusive` set. With it, an out-of-mutex stance
becomes `stance: null` (format drift), which trips the existing format-correction
escalation in §False-consensus guard. Persuasion and Deliberation roles have no
per-role mutex so their narrowed whitelist equals the preset whitelist (no behavior
change). Inquiry: V→{supports,inconclusive}, F→{refutes,inconclusive},
T→{lateral,inconclusive}, W→full preset set. Discovery: Explorers→{expand,connect,converge}
(no `challenge` — only Wildcard may challenge framings); Wildcard→full preset set;
Compiler is not in `ACTIVE_ROLES` (no tldr extraction — see §Checkpoint trigger).

Discovery introduces a second tag `[stage:]` alongside `[stance:]`. agent-session's `tldr` verb extracts only stance; debate extracts stage debate-side via `agent-session output` + grep, writes to `$DEBATE_DIR/stages/<role>.txt`. This keeps agent-session preset-agnostic.

```bash
# Discovery preset: also extract [stage:] for round-protocol enforcement
if [ "$PRESET" = "discovery" ]; then
  mkdir -p "$DEBATE_DIR/stages"
  for r in "${ACTIVE_ROLES[@]}"; do
    out=$(agent-session output --role-id "$r" --state-dir "$SESSIONS_DIR" 2>/dev/null)
    stage=$(echo "$out" | grep -oE '\[stage:[[:space:]]*[a-z]+\]' | head -1 | grep -oE '[a-z]+' | tail -1)
    echo "${stage:-null}" > "$DEBATE_DIR/stages/$r.txt"
  done
fi
```

###### Discovery stage round-number validation

The stage closed set is `{propose, refine, settle}` (§stage-tags-discovery). The
round protocol from brainstorm D-D3 maps stages to round numbers — R1 MUST be
`propose`, R2+ MUST be `refine` or `settle`. The check below surfaces violations
into the same `failed` array used by the post-round output verification in §Send,
so the moderator handles them through the existing format-correction escalation.

```bash
# Discovery: stage round-number validation
if [ "$PRESET" = "discovery" ]; then
  for r in "${ACTIVE_ROLES[@]}"; do
    stage=$(cat "$DEBATE_DIR/stages/$r.txt" 2>/dev/null)
    case "$N" in
      1)
        if [ "$stage" != "propose" ]; then
          failed+=("$r:bad-stage-r1:$stage")
        fi
        ;;
      *)
        if [ "$stage" != "refine" ] && [ "$stage" != "settle" ]; then
          failed+=("$r:bad-stage-r${N}:$stage")
        fi
        ;;
    esac
  done
fi
```

###### Inquiry source-kind extraction + closed-set check

`[source-kind:]` is the second tag added in brainstorm I-D3 to catch evidence-type
drift (Verifier citing a counter-example to claim `supports`, etc.). The tag's
closed set is `{empirical, mechanism, analogy, theoretical, counter-example}`. Like
Discovery's stage tag, debate extracts source-kind debate-side (agent-session stays
preset-agnostic), caches it per role, and surfaces any out-of-set value through the
same `failed` array.

```bash
if [ "$PRESET" = "inquiry" ]; then
  mkdir -p "$DEBATE_DIR/source-kinds"
  for r in "${ACTIVE_ROLES[@]}"; do
    out=$(agent-session output --role-id "$r" --state-dir "$SESSIONS_DIR" 2>/dev/null)
    sk=$(echo "$out" | grep -oE '\[source-kind:[[:space:]]*[a-z-]+\]' | head -1 \
         | sed -nE 's/.*\[source-kind:[[:space:]]*([a-z-]+)\].*/\1/p')
    echo "${sk:-null}" > "$DEBATE_DIR/source-kinds/$r.txt"
    case "${sk:-null}" in
      empirical|mechanism|analogy|theoretical|counter-example) ;;
      *) failed+=("$r:bad-source-kind:${sk:-null}") ;;
    esac
  done
fi
```

##### Pre-round step (assembling rN.md without reading TL;DRs)

Concatenate `tldrs/*.md` into a single shared `$DEBATE_DIR/rN.md` under a `## Last round, other participants (TL;DR)` header (one `### <role-id>` subsection each). Pure shell — `cat`, no Read tool. Then append a `## Focus this round` block with one bullet per role (1-2 lines each).

The focus bullets are the **only** content from this round that the moderator types into its own assistant message — typically ~4 lines.

##### Send (parallel)

Pass the same `rN.md` to every role via agent-session's `send` verb,
dispatched in parallel.

**[MUST] Dispatch pattern is foreground `& wait`. Never wrap in Bash
`run_in_background`.**

```bash
# correct — foreground parallel, --yolo on every send (see §2.5 MUST)
for r in "${ACTIVE_ROLES[@]}"; do
  agent-session send --role-id "$r" \
    --state-dir "$SESSIONS_DIR" \
    --prompt-file "$DEBATE_DIR/r${N}.md" \
    --yolo \
    --timeout 1800 > "$DEBATE_DIR/logs/send-${r}-r${N}.log" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"   # NB: each pid independently quoted — never wait "${pid}${suffix}"
done
```

Why foreground: keeps the orchestrator's control flow synchronous — the
moderator sees per-role exit codes immediately and can react in the same
turn. Acceptable wall-clock: 4 parallel 30-60s sends fit comfortably within
Bash tool's 600s timeout (see [MUST] below).

**Historical note.** A 2026-05-12 debate run hung 13 min with sends that
never launched and was originally attributed to "double-bg severs
stdio/job control" if `run_in_background` were used. That attribution was
wrong — 2026-05-14 reproduction with sleep / Python+stdin children under
`run_in_background` did **not** hang, and the real 2026-05-12 / 2026-05-14
failures were both caused by missing `--yolo` (opencode blocking on
permission prompt). Keep foreground anyway for the control-flow reason
above; don't expect background to cause stdio severance.

**[MUST] Bash tool `timeout: 600000`.** `agent-session --timeout` only
bounds the agent-session subprocess; the outer Bash tool has a 120s
default that will SIGKILL the whole wait block at 2 min. Set 600000
(10 min) on the Bash call wrapping spawn/send fan-out. **Do NOT** reach
for `run_in_background: true` as an escape hatch — that breaks the
foreground synchronous flow above; the right fix is a larger Bash
timeout.

**[MUST] Single Bash call for fan-out.** All roles must be backgrounded
(`&`) and waited within **one** Bash tool invocation. Spawning N roles
across N separate Bash calls serializes them — wall-clock = sum-of-roles
instead of max-of-roles — silently negating the parallelism the [MUST]
above is trying to preserve. If a model is tempted to "send each role in
its own Bash call to keep the logs clean", redirect each send's output to
a separate log file inside the single Bash call instead.

**[MUST] Collect per-role exit codes AND verify output.** A bare `wait` without arguments only waits, it doesn't surface individual failures. A round where `agent-session send` rejected a flag (e.g. `unrecognized arguments`) silently and `tldr` later returns the *previous round's* cached output is the classic false-success trap. Use this hardened pattern:

```bash
pids=()
for r in "${ACTIVE_ROLES[@]}"; do
  agent-session send --role-id "$r" \
    --prompt-file "$DEBATE_DIR/rN.md" \
    --state-dir "$SESSIONS_DIR" \
    --yolo \
    --timeout 1800 > "$DEBATE_DIR/logs/send-${r}-rN.log" 2>&1 &
  pids+=("$!")
  role_for_pid["$!"]="$r"
done

failed=()
for pid in "${pids[@]}"; do
  r="${role_for_pid[$pid]}"
  wait "$pid" || failed+=("$r:rc=$?")
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
    agent-session send --role-id "$role" --force --yolo --timeout 1500 \
      --prompt-file "$DEBATE_DIR/rN.md" --state-dir "$SESSIONS_DIR"
  fi
done
```

If you want Defender to rebut this-round critic arguments, do it as an **optional follow-up half-round** (one extra `send` to Defender after collecting the others' r_N), not by ordering the main round. Reserve for the round just before a checkpoint.

#### [MUST] Reconcile on session-not-found

If any `agent-session send` returns **exit 3** during round N, the backend
reports the role's session has been GC'd (most commonly: claude CLI's
session TTL, observed to expire by ~22min idle in 2026-05-12 testing).

The send's stdout is JSON:

```json
{"error": "session-not-found", "role_id": "role-a", "backend": "claude", "raw_error": "..."}
```

Recovery is moderator-driven (agent-session is a thin wrapper — it doesn't
know the role's context). Per affected role:

```bash
# 1. cleanup the dead session (idempotent)
agent-session cleanup --role-id "$r" --state-dir "$SESSIONS_DIR"

# 2. recompose first-turn prompt: shared-context + role identity + all prior
#    round TL;DRs of THIS role (in $DEBATE_DIR/tldrs-history/${r}/*.md)
cat "$DEBATE_DIR/shared-context.md" \
    "$DEBATE_DIR/roles/${r}.md" \
    "$DEBATE_DIR/tldrs-history/${r}/"*.md \
    > "$DEBATE_DIR/recover-${r}.md"

# 3. re-spawn with --initial-round set to this role's expected current round.
#    This sets round_count = N so the next send is indexed r${N}.
agent-session spawn \
  --backend "$backend" --model "$model" \
  --role-id "$r" --state-dir "$SESSIONS_DIR" \
  --system-prompt "$SYS" --prompt-file "$DEBATE_DIR/recover-${r}.md" \
  --initial-round "$N" \
  --yolo \
  --timeout 1800

# 4. Now send round N's actual discussion prompt.
#    spawn's first turn (recover-${r}.md) restores context, not round N content.
#    round_count is now N; this send writes r${N}.txt and advances to N+1.
agent-session send \
  --role-id "$r" --state-dir "$SESSIONS_DIR" \
  --prompt-file "$DEBATE_DIR/r${N}.md" \
  --yolo \
  --timeout 1800
```

The recovery adds one extra turn of overhead per affected role. After step 4
the role is fully aligned: `tldr` reads `r${N}.txt` and `round_count = N+1`,
matching any peer roles that completed round N directly.

**Why this design**:
- agent-session stays thin: it doesn't persist the original spawn prompt or
  know how to "replay" — debate owns the round-history bookkeeping
- `--initial-round` sets round_count so the explicit send lands at the right
  index; without it the send would be indexed r1 regardless of how many
  rounds peers have done
- No keepalive needed: session-lost is detected on next send and recovered
  in one round of overhead (vs. periodic ping wasting tokens forever)

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

For **inquiry**:

| Distribution | Convergence | Action |
|---|---|---|
| Verifier `supports` + others `lateral`/`inconclusive`, no `refutes` | Hypothesis tentatively supported | Checkpoint with Evidence Ledger; flag if `source-kind` is dominated by `analogy`/`theoretical` (weak signal) |
| Falsifier `refutes` (especially `source-kind: counter-example`) | Hypothesis falsified | Present Falsifier's counter-evidence prominently in checkpoint |
| Verifier `supports` AND Falsifier `refutes` | Irreducible dispute | Surface both; do NOT synthesize a verdict — user decides |
| All `inconclusive` | Insufficient evidence | Suggest gathering more data; do not advance to conclusion |
| ≥1 stance violates per-role mutex (e.g., Verifier outputs `refutes`) | Format drift via mutex violation | Apply format-correction; if Verifier's evidence is genuinely counter, that signal belongs to Falsifier — moderator may relay |
| stance/source-kind incoherent (e.g., `supports` + `counter-example`) | Heuristic warning | Read full Argument to verify; do not block round |

For **discovery**:

| Distribution | Reading | Action |
|---|---|---|
| All R2+ stages = `refine` | Healthy cross-pollination | Continue rounds |
| ≥1 stage = `settle` at R2 | Early lock-in | Read that role's Argument; revive if disengagement, accept if real wall |
| All R3 stages = `settle` | Discovery complete | Activate Compiler for final synthesis; checkpoint immediately |
| Many `expand`, few `connect` | Explorers deepening but not learning across axes | Next-round focus block must explicitly probe "what did you take from peer X?" |
| Wildcard `challenge` raised | Framing-axes set is being questioned | Moderator decides: add/remove/keep axes; communicate decision in next round's focus |
| Compiler emits any `[stage:]` or `[stance:]` | Format violation (Compiler must not participate as a debater) | Apply format-correction; re-run Compiler at next checkpoint |
| ≥1 stance/stage violates per-role mutex | Format drift | Apply format-correction (standard mechanism) |

Text similarity is unreliable. Same TL;DR + different stance tags = strongest false-consensus warning. A `null` stance amid otherwise-valid stances does **not** count as "Mostly X" — it must be resolved first.

##### Format-correction escalation (for `null` stance)

Re-spawning is expensive (loses the role's full conversation history) and reading past the issue is dishonest. Add a cheap intermediate step:

1. **Single-turn format-correction send** to the affected role (~1 small send per role). The correction prompt body is **preset-aware** — Inquiry adds `[source-kind:]`, Discovery adds `[stage:]`, and the role's narrowed whitelist (from §After-round `role_stance_whitelist`) is substituted into the closed-set list so the role can't re-violate the per-role mutex on the corrected turn. Compiler (Discovery) has a different correction template since it emits no tags.

   Assemble the body via case block before writing `$DEBATE_DIR/format-correction-${r}.md`:

   ```bash
   ROLE_WL=$(role_stance_whitelist "$PRESET" "$r")   # narrowed per-role set
   case "$PRESET" in
     persuasion|deliberation)
       cat > "$DEBATE_DIR/format-correction-${r}.md" <<EOF
   Your previous reply did not match the required output format.
   Send a corrected reply using EXACTLY this format:

     ## TL;DR
     <2-3 sentences>
     [stance: <ONE of: ${ROLE_WL}>]

     ## Argument
     <body>

   Do not explain the issue. Send only the corrected reply.
   EOF
       ;;
     inquiry)
       cat > "$DEBATE_DIR/format-correction-${r}.md" <<EOF
   Your previous reply did not match the required output format.
   Send a corrected reply using EXACTLY this format:

     ## TL;DR
     <2-3 sentences>
     [stance: <ONE of: ${ROLE_WL}>]
     [source-kind: <ONE of: empirical|mechanism|analogy|theoretical|counter-example>]

     ## Argument
     <body>

   Do not explain the issue. Send only the corrected reply.
   EOF
       ;;
     discovery)
       # For Explorers / Wildcard. Compiler correction is separate (see §Checkpoint).
       # ROUND_ALLOWED_STAGES per round-number protocol: R1=propose, R2+=refine|settle
       if [ "$N" = "1" ]; then ROUND_ALLOWED_STAGES="propose"
       else                    ROUND_ALLOWED_STAGES="refine|settle"
       fi
       cat > "$DEBATE_DIR/format-correction-${r}.md" <<EOF
   Your previous reply did not match the required output format.
   Send a corrected reply using EXACTLY this format:

     ## TL;DR
     <2-3 sentences>
     [stage: <ONE of: ${ROUND_ALLOWED_STAGES}>]
     [stance: <ONE of: ${ROLE_WL}>]

     ## Argument
     <body>

   Do not explain the issue. Send only the corrected reply.
   EOF
       ;;
   esac

   agent-session send --role-id "$r" \
     --prompt-file "$DEBATE_DIR/format-correction-${r}.md" \
     --state-dir "$SESSIONS_DIR" \
     --yolo
   ```

   `{ROLE_NARROWED_WHITELIST}` / `{ROUND_ALLOWED_STAGES}` are runtime substitutions the
   moderator computes before sending the correction — they ensure the corrected reply
   can't re-violate the mutex by picking a stance outside the role's allowed set.

   Compiler (Discovery) format-correction is different — Compiler emits no `[stage:]`
   or `[stance:]` tags, only the 4 section headers (Framing Matrix / Missing Axes /
   Irreducible Divergences / Open Questions). See §Compiler output validation
   (under §Checkpoint trigger) for Compiler's correction template.

2. Re-run the `tldr` extraction for that role with the active preset's `--stance-whitelist`. If stance is now in the active whitelist, the corrected reply **replaces** the prior round's cached TL;DR — continue with the round's stance distribution as if nothing went wrong.

3. If stance is still `null` after one correction attempt, treat the distribution as unresolved and choose:
   - **Re-spawn** the role (last resort — loses prior context) — useful if the role's reasoning is also drifting.
   - **Edit `references/output-format-<preset>.md`** if the format itself is the root cause (run `tests/manifest-invariants.sh` after).
   - **Continue with the role excluded from this round's distribution** — note it explicitly in the checkpoint Divergence section ("Role X had unresolved format drift in round N; their stance is unknown").

[MUST] If you take option (a) or (c), say so in your reply to the user — silent skill deviation is worse than the format drift itself.

#### Checkpoint trigger (preset-aware)

For **persuasion**: every 3 rounds (unchanged).

For **deliberation**: all stakeholders have contributed ≥1 round AND (round_count ≥ 3 OR all stances ∈ {prefer, accept}).

For **inquiry**: every 3 rounds (same as Persuasion).

For **discovery**: two-level trigger.
- **Periodic Compiler checkpoint** every 3 rounds (regardless of stage state) — gives the user a synthesis cadence even mid-exploration.
- **Final Compiler synthesis** fires the moment all Explorer stages reach `settle` (discovery is complete; producing the final framing matrix immediately is more useful than waiting for the next round-3 boundary).

Both trigger paths run the same Compiler activation flow (see "Compiler activation" below).

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

For **inquiry**:

```markdown
## Investigation progress @ Round N checkpoint
(Verifier @ R3, Falsifier @ R2, Triangulator @ R3, Wildcard @ R3)

### Evidence Ledger
| Claim | source-kind | Cited by | Stance |
|-------|-------------|----------|--------|
| (auto-extracted from each role's TL;DR + Argument first paragraph) |

### Convergence reading
- Verifier signal strength: <high/medium/low/null>
- Falsifier signal strength: <high/medium/low/null>
- Triangulator orthogonal flags: <list>

### Missing evidence
- (gaps the moderator notices: V/F/T didn't reach this angle yet)

### You decide
- Hypothesis verdict: {tentatively supported / falsified / disputed / insufficient}
- Next: {more rounds along axis X / sufficient to decide}
```

##### Compiler activation (Discovery only)

Compiler does not participate per-round (it is not in `ACTIVE_ROLES`). At each
checkpoint trigger — periodic (every 3 rounds) or final (all stages `settle`) —
the moderator brings Compiler online:

1. **Spawn Compiler on demand** (first checkpoint only; subsequent checkpoints
   reuse the same session so context accumulates):

   ```bash
   if ! agent-session describe --role-id compiler --state-dir "$SESSIONS_DIR" >/dev/null 2>&1; then
     # Save the assembled identity per §2.5 reconcile anchor convention
     cp references/roles/compiler.md "$DEBATE_DIR/roles/compiler.md"
     agent-session spawn --backend "$compiler_backend" --model "$compiler_model" \
       --role-id compiler --state-dir "$SESSIONS_DIR" \
       --system-prompt "$COMPILER_SYS" \
       --prompt-file "$DEBATE_DIR/roles/compiler.md" \
       --yolo \
       --timeout 900
   fi
   ```

2. **Send checkpoint input**: assemble `$DEBATE_DIR/checkpoint-${N}-input.md` by
   concatenating `$DEBATE_DIR/tldrs/*.md`, `$DEBATE_DIR/stages/*.txt`, and
   `$DEBATE_DIR/running-summary.md` (if exists). Then:

   ```bash
   agent-session send --role-id compiler --state-dir "$SESSIONS_DIR" \
     --prompt-file "$DEBATE_DIR/checkpoint-${N}-input.md" --yolo --timeout 900
   ```

   On second+ checkpoint Compiler's session retains earlier checkpoints, so the
   input file can include only the new round's TL;DRs delta — round_count
   semantically tracks how many checkpoints Compiler has done.

3. **Validate Compiler output** — Compiler MUST NOT emit recommendations,
   rankings, or "best option" framings (per brainstorm D-D2 + role-compiler
   manifest invariants). The runtime grep below catches a drifted Compiler
   reply; if any forbidden pattern hits, treat as format violation and send
   the Compiler-specific correction template:

   ```bash
   c_out=$(agent-session output --role-id compiler --state-dir "$SESSIONS_DIR")
   if echo "$c_out" | grep -qE '^## Recommendation|^## Best Option|^## Ranking|we recommend|best option|ranking from best'; then
     cat > "$DEBATE_DIR/compiler-correction.md" <<'EOF'
   Your previous reply contained forbidden sections (Recommendation / Best Option /
   Ranking) or phrasing (we recommend / best option / ranking from best). Compiler's
   role is to compile, not to recommend.

   Send a corrected reply using EXACTLY these 4 section headers and nothing else:

     ## Framing Matrix
     ## Missing Axes
     ## Irreducible Divergences
     ## Open Questions

   Do NOT include: [stage:], [stance:], Recommendation, Best Option, Ranking,
   "we recommend", "best option". Send only the corrected reply.
   EOF
     agent-session send --role-id compiler --state-dir "$SESSIONS_DIR" \
       --prompt-file "$DEBATE_DIR/compiler-correction.md" --yolo --timeout 900
     c_out=$(agent-session output --role-id compiler --state-dir "$SESSIONS_DIR")
   fi
   ```

   (The forbidden patterns mirror the manifest invariants on `role-compiler` —
   if Compiler's `compiler.md` ever drifts to allow these, both the manifest
   check and the runtime grep would catch it.)

4. **Render checkpoint** using Compiler's validated output verbatim (the 4
   sections become the body of the Discovery checkpoint template below).

For **discovery**:

```markdown
## Discovery progress @ Round N checkpoint
(Explorer A @ R3:settle, Explorer B @ R3:refine, Explorer C @ R3:settle, Wildcard @ R3:converge)

(Compiler's output begins here — Compiler is the synthesizer, not a debater)

## Framing Matrix
| Axis | Proposal | Confidence | Notes |
|------|----------|------------|-------|
| Axis A | (Explorer A's settled proposal) | high | ... |
| Axis B | (Explorer B's refined proposal) | medium | still evolving |
| Axis C | (Explorer C's settled proposal) | high | ... |

## Missing Axes
- (Wildcard's `challenge` suggestions or Compiler-inferred gaps; explicit "none" if none)

## Irreducible Divergences
- Axis A vs Axis C on dimension X: Axis A says ..., Axis C says ..., both `settle`d at `converge` — user decision

## Open Questions
- (Compiler-extracted questions; possibly added by Compiler itself but framed as "User: do you weigh ... above ...?", never as recommendations)

### You decide
- Accept matrix as-is and move on
- Refine framing-axes set (add/remove an axis) and re-run a round
- Specific question Compiler raised that you want to address
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

For **inquiry**:

```markdown
## Conclusion

### Hypothesis examined
{verbatim}

### Verdict
{tentatively supported / falsified / disputed / insufficient evidence}

### Strongest supporting evidence
- {from Verifier: claim + source-kind}

### Strongest counter-evidence
- {from Falsifier: claim + source-kind: counter-example if available}

### Orthogonal considerations
- {from Triangulator: what changes how the hypothesis should be evaluated}

### Wildcard's divergent angle
- {what fell outside V/F/T scope}

### Open questions / Missing evidence
- {explicit gaps; what would change the verdict}
```

For **discovery**:

```markdown
## Conclusion

### Open question examined
{verbatim from §1.5}

### Framing axes (confirmed)
{list of 3-4 axes}

### Framing matrix
{full Compiler matrix from checkpoint, optionally updated by final round}

### Irreducible divergences
{points where axes cannot reconcile; user must resolve}

### Open questions surfaced
{Compiler's questions still unanswered by debate; explicit user prompts}

### What this Discovery did NOT settle
- We did not recommend a single best framing — user picks
- We did not pre-enumerate options — options *emerged* from Explorers' proposals
```

### Step 5: Cleanup

[MUST] Runs automatically — don't wait for the user.

Debate ends by terminating every role session it created (use agent-session's `cleanup` verb per role) and removing its own scratch workspace (`$DEBATE_DIR` from §2.1). Cleanup must be idempotent — repeating it is a no-op; ignore "session not found" errors.

---

## Red Flags

**绝对不要**：

1. **`agent-session spawn/send/run` 不带 `--yolo`**：opencode backend 会阻塞
   在交互式权限确认（没有 stdin 来 approve），child 进程在 0% CPU 永久等待，
   表现为 0 字节 log + role 卡在前一 round_count + debate 整个 stall。
   claude backend 因为继承 Claude Code 父进程的权限上下文不出问题，所以症状
   是 opencode-specific 但随机。**正确做法**：所有 spawn/send/run 一律带
   `--yolo`（debate 是受信任的分析场景，符合 CLAUDE.md 指引）。2026-05-12 和
   2026-05-14 各有一次 5-role discovery debate 因为这条卡住三轮，前者被错误
   归因为 "double-bg job control 切断"，2026-05-14 reproduction 证伪了归因。

2. **用 ScheduleWakeup 等 debate 多 role send**：盲等卡死的进程会浪费完整
   wakeup 周期才发现问题。**正确做法**：foreground `wait` PID（见 §Round N
   pattern），send 失败/超时立刻可见。

3. **`wait` 拼接变量不加分隔**：`wait "$pid$role"` 被 shell 解析为单变量名
   `$pidrole`，找不到对应 PID 报 `job not found: 65081ole-a`（拼接 PID + role
   name 后丢前导字符）。**正确做法**：`wait "$pid"` —— 每个变量独立 quote，
   永远不在 wait 参数里串变量。如需打日志拼字符串，用其他变量分开处理。

4. **fan-out 跨多个 Bash 调用**：每个 role 单独一个 Bash tool call 调
   `agent-session send` 会把并发退化成串行，wall-clock 从 max-of-roles 变成
   sum-of-roles。**正确做法**：单一 Bash call 内部 `& wait`，每个 send
   重定向到独立 log 文件。

5. **Bash tool 用默认 timeout 跑 send fan-out**：默认 120s 会在 2 分钟时把
   整个 wait 块 SIGKILL，掩盖真正的进度。**正确做法**：调用 Bash 时显式传
   `timeout: 600000`。不要用 `run_in_background: true` 来"绕开" timeout —
   那会破坏 §Round N Send 块要求的前台同步控制流。

---

## Dependencies

- **`agent-session` skill** (hard) — backend abstraction; same repo
- **≥1 backend CLI** — claude / opencode / codex / gemini / etc; ≥2 distinct families recommended

## Exception handling

| Situation | Handling |
|---|---|
| `agent-session spawn` fails | Read stderr; the role is `failed` in `meta.json`. Retry on a different backend, or proceed without (mark `[failed]` in checkpoint). |
| `agent-session send` fails mid-round | Skip that role this round; log; continue with the others. |
| Role output empty | Likely a backend hiccup; retry once via `send`; if still empty, skip this round. |
