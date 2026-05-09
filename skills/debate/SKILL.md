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
5. **Every 3 rounds is a checkpoint** — present consensus / divergence / decision points to the user.
6. **Stance tags** (`hold` / `concede` / `add`) are mandatory in every output — used to detect false consensus.

> **About model families.** Each driver carries a static `family` hint (claude→anthropic, codex→openai, opencode→openai by default). It's a heuristic for picking the Defender (same family as the main agent) and spreading roles across families. Override per-role via env vars or prefs. opencode is multi-provider; treat its `(openai)` tag as a default, not a fact.

## Usage

```
/debate                                              # auto-analyze current context, infer challenge direction and roles
/debate "I think this proposal has scaling issues"   # specify the challenge
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

After context confirmation, before any `agent-session spawn`, the moderator runs a short preflight that resolves two independent axes and prints **one combined block** the user signs off on:

1. **Language** (for role prose only — section markers stay English):
   ```
   --lang flag → prefs.lang → ≥10 CJK chars in challenge text
   → ≥50% non-Latin script in challenge text → recent 3 user turns' locale
   → $LANG runtime locale → fallback "en"
   ```
   First non-empty match wins. **Always print the chosen value as a visible line** so autodetect doesn't become hidden state.

2. **Parallelism** (tmux):
   ```
   --no-parallel flag → DEBATE_NO_TMUX → no TTY → tmux on PATH? → use it
   ```
   Tmux split-pane is *visualization*, not parallelism — the loop in §2.5 / §3 already runs `agent-session` calls concurrently in subprocesses. Tmux just makes the live output legible. Missing tmux → silently degrade to single-pane background output.

3. **Budget estimate** (rough):
   ```
   tokens   ≈ M_roles × R_planned × 1.7k       (R_planned default = 6, two checkpoints)
   wall-clock ≈ longest-role-latency × R_planned   (parallel sends; default 30s/turn)
   ```

Print one combined gate, wait for user:

```
Language: zh (autodetected from challenge text, override with /debate --lang xx)
Parallel: tmux (split panes)
Debate plan: 4 roles × ~6 rounds ≈ ~40k tokens, ~3 min wall-clock
Begin? (Y/n)  [or self-critique / cancel]
```

If a flag/file/tool was missing and we degraded, the corresponding line says so (`Parallel: sequential (tmux not found)`).

The running token counter reappears at the every-3-round checkpoint:

```
Tokens: ~Xk used / ~40k planned (estimate)
```

(The 1.7k constant is a rough estimate; future telemetry will replace it with per-driver real counts. See `agent-session doctor` for auth-identity collisions that make the cross-family premise notional.)

### Step 2: Plan & spawn

#### 2.1 Workspace

```bash
DEBATE_ID=$(date +%s%N | md5sum | head -c4)
DEBATE_DIR="/tmp/debate-${DEBATE_ID}"
SESSIONS_DIR="${DEBATE_DIR}/sessions"
mkdir -p "$SESSIONS_DIR"
```

`SESSIONS_DIR` is the shared state directory passed to every `spawn` / `send` / `output` / `cleanup` call. Cleanup is `rm -rf "$DEBATE_DIR"`.

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

#### 2.4 Prompt files

Write a **shared context** once at `$DEBATE_DIR/shared-context.md` — Original proposal / Challenge / Project context — and a per-role **first-turn instructions** file. The full first-turn prompt = shared-context + role file (concatenate or pass both).

The Wildcard role file should resemble:

```markdown
## Your role
Divergent thinker. You are NOT scoped to a specific examination angle.

## Your job
Bring perspectives the focused critics will miss. Examples (pick what fits — don't do all):
- Question premises (is this even the right problem?)
- Second-order or systemic effects
- Contrarian framings
- Analogies from adjacent domains
- Failure modes nobody asked about (silent / 2-year / 10× scale)

You may raise issues OUTSIDE the user's stated challenge — that is this role's value. Don't try to be balanced.

## Focus this round
Pick whichever divergent angle gives the most leverage on this proposal.
```

Defender / Role A / Role B files follow the obvious shape: `## Your role`, `## Your examination focus`, `## Focus this round`. Compose them yourself.

**Output format (mandatory, passed to every role as their system prompt at spawn)**:

```
## TL;DR
(2-3 sentences with the core view)
[stance: hold/concede/add]

## Argument
(150-300 words, supported by specific code/technical detail)
```

**Stance tag semantics**:

| Tag | Meaning | Moderator interpretation |
|---|---|---|
| `hold` | Maintains stance after counter-argument | Disagreement remains |
| `concede` | Adjusts own stance | Local convergence |
| `add` | Parallel expansion (no direct response) | Beware false consensus |

(Round 1: every role tags `add`; the tag matters from round 2.)

#### 2.5 Spawn roles

For each role decided in §2.3, open a persistent session via the [agent-session](../agent-session/SKILL.md) skill's **`spawn`** verb. The verb's call shape is owned by agent-session; what debate provides:

- the role's `(backend, model)` from §2.3
- the role's first-turn prompt from §2.4
- a system prompt of form `"You are the <role> in a technical debate. $FORMAT_RULE"`
- a single shared state directory for the whole debate (so cleanup is one `rm -rf`)

**Run all spawns in parallel** — round-1 prompts are independent, so wall-clock equals the slowest role's latency. Skip `role-b` when §2.3 made it topic-conditional. After spawn, each role's first-turn reply is retrievable via the `output` verb.

For tmux *split-pane visualization* (not for parallelism — concurrency comes from `& ... wait`): see [`references/parallel-tmux.md`](./references/parallel-tmux.md).

### Step 3: Discuss

#### Round 1

For each role, retrieve its first-turn reply via agent-session's `output` verb. Record divergence and consensus. Treat the Wildcard's contribution as a *second-axis* signal — it may surface concerns orthogonal to the focused critics; don't force-merge.

#### Round N (subsequent)

Build an incremental prompt: only other roles' previous-round TL;DRs + this round's focus. The session already holds prior context; do not repeat the proposal/challenge.

**[MUST] One shared prompt file per round, assembled by shell — not by quoting role outputs into the moderator's assistant message.** This is the single biggest source of context bloat: dumping every role's TL;DR into the moderator's message stream every round adds ~100 tokens × M_roles × N_rounds. The moderator should never need to read or re-quote a TL;DR to assemble the next round.

##### After-round step (runs immediately after every round finishes)

For each active role, fetch its latest reply via agent-session's `output` verb, pipe it through `sed` to keep only the `## TL;DR ... [stance: ...]` block, and redirect to `$DEBATE_DIR/tldrs/<role-id>.md`. **The moderator never reads the output into its own message** — the pipe goes verb → `sed` → disk.

The extractor is debate-specific (it depends on the §2.4 mandatory output format):

```
sed -n '/^## TL;DR/,/^## /{/^## [^T]/q;p}'
```

Each `tldrs/<role>.md` is overwritten each round with the latest TL;DR. These files are inputs to the next round's prompt assembly — not for the moderator to read.

##### Pre-round step (assembling rN.md without reading TL;DRs)

Concatenate `tldrs/*.md` into a single shared `$DEBATE_DIR/rN.md` under a `## Last round, other participants (TL;DR)` header (one `### <role-id>` subsection each). Pure shell — `cat`, no Read tool. Then append a `## Focus this round` block with one bullet per role (1-2 lines each).

The focus bullets are the **only** content from this round that the moderator types into its own assistant message — typically ~4 lines.

##### Send (parallel)

Pass the SAME `rN.md` to every role via agent-session's `send` verb, dispatched **in parallel**. Sequential within-round dispatch is not required — the prompt only references round N-1, so there's no in-round dialogue — and roughly doubles wall-clock.

If you want Defender to rebut this-round critic arguments, do it as an **optional follow-up half-round** (one extra `send` to Defender after collecting the others' r_N), not by ordering the main round. Reserve for the round just before a checkpoint.

For tmux split panes (visualization, not parallelism — sends already run concurrently): see [`references/parallel-tmux.md`](./references/parallel-tmux.md).

#### [MUST] Read strategy (token saving)

The main agent has a context window. Each round's full Argument bodies × N rounds × M roles will exhaust it. Three rules:

**(a) Inter-round TL;DRs never enter the moderator's message.** The After-round step pipes the `output` verb's result through `sed` straight to `tldrs/<role>.md`; the Pre-round step `cat`s those files into `rN.md`. The moderator's only inter-round contribution to its own context is the 4-line focus block.

**(b) Read TL;DRs only at the every-3-round checkpoint.** When you reach a checkpoint, *then* the moderator may `cat $DEBATE_DIR/tldrs/*.md` once to synthesize the consensus/divergence block. Read the full Argument only when the user asks or when the stance distribution warrants verification.

**(c) Never re-quote role outputs into the assistant message.** When a tool result surfaced a 200-line role output, do NOT re-include it verbatim "to show the user what each said" — the user can `cat` the file themselves. Each role's session already holds its full history (agent-session owns that) — the moderator never needs to repeat anything.

#### [MUST] False-consensus guard

Inspect the stance-tag distribution across roles:

| Distribution | Convergence | Action |
|---|---|---|
| All `hold` | Low | Switch focus or continue |
| Mostly `concede` | High | Local convergence; advance or end |
| All `add` | — | **Parallel without dialogue — beware false consensus**; read full arguments |
| Mixed | Medium | Decide via TL;DR content |

Text similarity is unreliable. Same TL;DR + different stance tags = strongest false-consensus warning.

#### Every-3-round checkpoint

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

### Step 5: Cleanup

[MUST] Runs automatically — don't wait for the user.

For every role spawned in §2.5, terminate its session via agent-session's `cleanup` verb. Then `rm -rf "$DEBATE_DIR"`. Cleanup must be idempotent (calling it twice is a no-op) — ignore "session not found" errors.

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
