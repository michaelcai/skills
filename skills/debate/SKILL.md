---
name: debate
description: "Multi-model multi-role peer debate. Main agent moderates while ≥2 distinct model families argue for/against the original proposal. Detects false consensus via stance tags. Backends abstracted via agent-session."
user-invocable: true
---

# Debate

When the user challenges the current agent's proposal/opinion, organize a multi-model peer discussion to cross-validate the proposal.

## [MUST] Core rules

1. **Multi-model is recommended, not enforced.** The pool is whatever the user configures in `prefs.json`. The skill warns when the pool collapses to a single family (debate degenerates to "talking to yourself"), but the user decides whether to proceed.
2. The main agent is the **moderator**, never a debater. It orchestrates, judges convergence, summarizes, and hands off to the user.
3. Roles are generated **dynamically** for each debate (no preset role pool). Identity must be specific to the current proposal/challenge.
4. Sessions **persist across rounds** — each role keeps its own conversation history via [`agent-session`](../agent-session/).
5. **Every 3 rounds is a checkpoint** — present consensus / divergence / convergence / decision points to the user.
6. **Stance tags** (`hold` / `concede` / `add`) are mandatory in every output — used to detect false consensus.

> **About model families.** Each driver carries a static `family` hint (claude→anthropic, codex→openai, opencode→openai by default). This is purely a *heuristic* used to pick the Defender (same family as the main agent) and to spread roles across families when possible. The user is free to ignore the heuristic, override per-role with env vars, or run debate with a single-family pool — none of these are blocked. opencode in particular is multi-provider; treat its `(openai)` tag as a default, not a fact.

## Usage

```
/debate                                              # auto-analyze current context, infer challenge direction and roles
/debate "I think this proposal has scaling issues"   # specify the challenge
```

Interactive only. Not auto-invoked by other skills.

## Architecture

```
debate skill (protocol layer)
  ├── role planning (Defender + dynamic roles, backend assignment)
  ├── round orchestration (round 1 parallel, round N+1 incremental TL;DR)
  ├── stance distribution → false-consensus guard
  ├── every-3-round checkpoint
  └── conclusion
       │
       ▼ shell calls
  agent-session (backend abstraction)
       │
       ▼ subprocess
  claude / opencode / codex / ... (user-installed)
```

debate **does not** know which backend CLI is invoked. It only:
- declares "I need a role on backend X"
- spawns / sends / reads via `agent-session` verbs
- enforces multi-family at the protocol level

## State machine

```
[preparing]   → context pack + backend preflight + spawn all roles (round 1)
   │
   ▼
[discussing] → main agent orchestrates rounds (max 3 per checkpoint)
   │ every 3 rounds
   ▼
[checkpoint] → main agent summarizes → wait for user
   │ "continue"             │ "enough"
   ▼                        ▼
[discussing]            [concluding] → output conclusion + cleanup all role sessions

Any state → user Ctrl+C → cleanup; existing checkpoint content preserved.
```

---

## Flow

### Step 1: Context Pack (main agent)

1. Collect the original proposal (the proposal/opinion the agent gave in the current conversation)
2. Collect the challenge:
   - User specified → use directly
   - User did not specify → main agent analyzes weak points and presents to the user for confirmation
3. Collect project context (tech stack, related code)
4. Present and confirm with the user:

```
This debate:
- Original proposal: {proposal summary}
- Challenge: {challenge content}
- Planned participants: Defender + {role description(s)}
  (backends will be assigned in step 2 after preflight)

Begin once confirmed.
```

### Step 2: Plan & Spawn

#### 2.1 Generate instance ID + state dir

```bash
DEBATE_ID=$(date +%s%N | md5sum | head -c4)
DEBATE_DIR="/tmp/debate-${DEBATE_ID}"
SESSIONS_DIR="${DEBATE_DIR}/sessions"
mkdir -p "$SESSIONS_DIR"
export DEBATE_ID DEBATE_DIR SESSIONS_DIR
```

`SESSIONS_DIR` is passed to every `agent-session` call as `--state-dir`. All role sessions live under it; cleanup is by `rm -rf`.

#### 2.2 Backend preflight (REQUIRED before role planning)

```bash
agent-session doctor   # show user what's available + multi-model verdict
```

If `doctor` reports `Multi-model capability: ✗`, **warn** the user but do not abort — the user may genuinely want a single-family debate (e.g. only `claude` available, but they want sonnet vs. opus). Example warning:

```
Heads up: only one model family detected (anthropic). Debate will run
single-family — the false-consensus guard via stance tags still works,
but cross-family disagreement won't surface. Continue? (Y/n)
```

Capture the available backend list:

```bash
mapfile -t AVAILABLE_BACKENDS < <(agent-session list-backends)
```

#### 2.2.5 Load / bootstrap user prefs (`~/.config/agents/debate/prefs.json`)

The skill stores per-user backend defaults at:

```
~/.config/agents/debate/prefs.json
```

(XDG-style, vendor-neutral — not tied to Claude.) Schema:

```json
{
  "version": 1,
  "agents": [
    { "backend": "claude",   "model": null },
    { "backend": "opencode", "model": null }
  ]
}
```

`agents` is the **pool** of backends this user wants to draw from. `model: null` means "let the backend pick its own default" (driver doesn't pass `--model`).

`agents` is a pool, **not** a fixed role assignment — the main agent decides per-debate which agent plays which role (algorithm in §2.3).

##### First-run bootstrap (file does not exist)

If `prefs.json` is missing, the main agent shows the doctor output and asks the user **which backends to include**. Don't default to "all" silently — make the choice explicit (the pool drives every future debate, so the user should opt-in).

**Hybrid prompt**:

| Runtime | Mechanism |
|---|---|
| Claude Code (`AskUserQuestion` available) | `AskUserQuestion` with `multiSelect: true`, one option per detected backend (label: `<name>`, description: install path). User picks the subset they want. |
| Codex CLI / opencode / other | Plain text prompt — list backends with numbers, ask the user to reply with a comma-separated subset (e.g. `1,3`) or `all`. |

**Self-detection rule**: if `AskUserQuestion` is in your tool list, take the first row; otherwise fall back to plain text.

Don't tag backends with a family in the picker UI — opencode in particular is multi-provider and labeling it `(openai)` is misleading. Family is an internal heuristic only (see §2.3).

Example plain-text fallback:

```
prefs.json not found — let's set it up.

Detected backends:
  1. claude     /Users/.../bin/claude
  2. opencode   /Users/.../bin/opencode
  3. codex      /opt/.../bin/codex

Which to include in your debate pool?
Reply with a comma-separated subset (e.g. "1,2") or "all".
```

After the user picks, write `prefs.json` with the chosen subset, each `model: null`. (User can pin a model later by editing the file or by saying *"set claude's default to sonnet"*.)

##### Incremental update (file exists, pool drifted)

On every `/debate`, after `list-backends`, compare prefs.agents vs detected:

- **Detected has new backend not in prefs** → ask: "`<name>` is now installed; add it to your debate pool?"
- **Prefs has backend that no longer detects** → ask: "`<name>` is no longer detected; remove from pool? (or keep and abort if you ever try to use it)"

Same hybrid rule (`AskUserQuestion` if available — single Y/n per drift item — else plain text). The user can also tell the main agent in-conversation: *"add codex to my debate pool"* / *"set claude's default to sonnet"* — the agent rewrites the file.

After load + sync, the pool must have **≥1 backend**. If the pool has only one family, surface the same soft warning from §2.2 — let the user decide.

#### 2.3 Per-role assignment algorithm

Each debate has up to three roles: **Defender**, **Role A**, optionally **Role B**. Each role resolves to one `(backend, model)` pair using this priority chain (highest → lowest):

```
P1. Inline override (this debate only)
    The user said "this time let codex be defender" in conversation.
    Main agent honors and skips P2/P3 for that role.

P2. Env var override (this shell session)
    $DEBATE_<ROLE>_BACKEND  / $DEBATE_<ROLE>_MODEL
    Useful for one-off experiments without editing prefs.

P3. Main-agent assignment (from the prefs pool)
    Defender → an agent in the pool whose family matches the
               main agent's own family (heuristic: the Defender
               argues on behalf of the original proposal, so
               same-family is a good first guess). If no same-family
               agent is in the pool, pick the first entry.
               (Claude Code  → anthropic; Codex CLI → openai; etc.)
    Role A   → first agent in the pool whose family ≠ Defender's family,
               OR if no different-family entry exists, the next pool
               entry (same family, different agent or model).
    Role B   → main agent's call: typically the next pool entry not
               already assigned. May be skipped if pool has only 2 entries
               and a 2-role debate suffices.
```

**Model resolution** (after the agent is fixed):

```
1. $DEBATE_<ROLE>_MODEL (env var override)
2. The model field for this agent in prefs (may be null)
3. null → spawn omits --model; backend picks
```

Env var reference (used in P2 / model resolution):

| Var | Effect |
|---|---|
| `DEBATE_DEFENDER_BACKEND` / `DEBATE_DEFENDER_MODEL` | Override the Defender |
| `DEBATE_ROLE_A_BACKEND`   / `DEBATE_ROLE_A_MODEL`   | Override Role A |
| `DEBATE_ROLE_B_BACKEND`   / `DEBATE_ROLE_B_MODEL`   | Override Role B (if used) |

##### Self-family detection (for P3 Defender pick)

The main agent must know its own family. Use this lookup:

| Runtime | Family |
|---|---|
| Claude Code | anthropic |
| Codex CLI | openai |
| opencode | openai (default; depends on configured provider) |
| Gemini CLI | google |
| other | unknown — fallback to first pool entry |

#### 2.3.1 Print decision and confirm

Before spawning, the main agent **must** print its decision and wait for the user's go-ahead:

```
Debate assignment:
  Defender = claude   (default model)
  Role A   = opencode (default model)
  [Role B  = codex    (gpt-5.4-mini)]
Pool source: ~/.config/agents/debate/prefs.json
Begin? (Y/n)
```

If the assignment ended up single-family, append a one-liner above `Begin?`:

```
Note: all roles share family "anthropic" — debate may converge fast.
```

#### 2.3.2 Dynamic role generation

Independent of backend assignment, the main agent constructs role identities:

**Defender** — defends the original proposal.

**Dynamic role(s) (1-2)** — each must have:
- Identity description specific to this discussion (e.g. "focus on token refresh logic security in this JWT proposal")
- Examination focus
- Stance leaning (optional)

**[MUST]** Role descriptions must be specific to this discussion. Generic descriptions like "security expert" or "performance engineer" are forbidden.

If P1 / P2 / P3 produced a single-family assignment (e.g. user pinned all roles to claude), warn the user once at decision-print time but proceed if they confirm. The stance-tag false-consensus guard still works in single-family setups; the user trades cross-family disagreement for whatever motivated their pinning.

#### 2.4 Prepare prompt files

Write a shared context once + a per-role "special instructions" file. Concatenate at spawn time so context is not duplicated in `agent-session`'s state.

**Shared context** (`$DEBATE_DIR/shared-context.md`, written once):

```markdown
## Original proposal
{full content of the original proposal}

## Challenge
{user's challenge content}

## Project context
{tech stack, summary of relevant code}
```

**Defender special instructions** (`$DEBATE_DIR/defender-r1.md`):

```markdown
## Your role
Defender of the original proposal: justify the proposal, respond to challenges, point out blind spots in the challenge.
If the original proposal genuinely has flaws, acknowledge them and propose improvements (do not stick stubbornly).

## Focus this round
(Round 1 = comprehensive response to the challenge; subsequent rounds set by the moderator)
```

**Dynamic role special instructions** (`$DEBATE_DIR/role-a-r1.md`):

```markdown
## Your role
{role identity, specific to this discussion}

## Your examination focus
{examination focus}

## Your stance leaning
{stance leaning, optional}

## Focus this round
(Round 1 = full evaluation from your examination focus)
```

**Output format (mandatory, shared by all roles, passed via `--system-prompt`)**:

```
## TL;DR
(2-3 sentences with the core view; the moderator only reads this section when summarizing)
[stance: hold/concede/add]

## Argument
(150-300 words, supported by specific code/technical detail)
```

**Stance tag semantics** (key signal against false convergence):

| Tag | Meaning | Moderator interpretation |
|------|------|----------|
| `hold` | Responded to counter-argument but maintains original stance | Disagreement remains; continue or switch focus |
| `concede` | Accepts part of the other side's view, adjusts own stance | Local convergence; can advance |
| `add` | Brings a new perspective/argument, doesn't directly respond to prior round | Parallel expansion, not a direct dialogue — beware "false consensus" |

[Round 1: every role tags `add` by default; the tag is meaningful only from round 2 onward]

#### 2.5 Concatenate per-role first-turn prompt

For each role, build the full first-turn prompt by concatenating shared context + role instructions:

```bash
cat "$DEBATE_DIR/shared-context.md" "$DEBATE_DIR/defender-r1.md" > "$DEBATE_DIR/defender-r1-full.md"
cat "$DEBATE_DIR/shared-context.md" "$DEBATE_DIR/role-a-r1.md"   > "$DEBATE_DIR/role-a-r1-full.md"
# (and similarly for role-b if used)
```

#### 2.6 Spawn all roles

The minimum form is **sequential** (no extra dependencies). For parallel execution see [`references/parallel-tmux.md`](./references/parallel-tmux.md).

The main agent has already resolved the (backend, model) for each role in §2.3 and exports them as `<ROLE>_BACKEND` / `<ROLE>_MODEL` (model may be empty → omit `--model`).

```bash
FORMAT_RULE='Reply in English. Required output format: first "## TL;DR" (2-3 sentences with the core view), with a single line "[stance: hold/concede/add]" at the end of the TL;DR (always "add" in round 1), then "## Argument" (150-300 words, citing specific code/technical detail). No preamble.'

# DEFENDER_BACKEND / DEFENDER_MODEL / ROLE_A_BACKEND / ... already resolved in §2.3.
defender_model_flag=()
[ -n "${DEFENDER_MODEL:-}" ] && defender_model_flag=(--model "$DEFENDER_MODEL")
role_a_model_flag=()
[ -n "${ROLE_A_MODEL:-}" ] && role_a_model_flag=(--model "$ROLE_A_MODEL")

agent-session spawn \
  --backend "$DEFENDER_BACKEND" --role-id defender \
  --prompt-file "$DEBATE_DIR/defender-r1-full.md" \
  --state-dir "$SESSIONS_DIR" \
  --system-prompt "You are the Defender in a technical debate. $FORMAT_RULE" \
  "${defender_model_flag[@]}"

agent-session spawn \
  --backend "$ROLE_A_BACKEND" --role-id role-a \
  --prompt-file "$DEBATE_DIR/role-a-r1-full.md" \
  --state-dir "$SESSIONS_DIR" \
  --system-prompt "You are {Role A identity}. $FORMAT_RULE" \
  "${role_a_model_flag[@]}"

# (and role-b similarly with ROLE_B_BACKEND / ROLE_B_MODEL)
```

After every `spawn` succeeds, the first-round assistant message is at `$SESSIONS_DIR/<role-id>/output/r0.txt`.

### Step 3: Discuss (main agent orchestrates)

#### Round 1 — already complete after step 2.6

Main agent reads each role's first-round output:

```bash
agent-session output --role-id defender --state-dir "$SESSIONS_DIR"
agent-session output --role-id role-a   --state-dir "$SESSIONS_DIR"
```

Record divergence and consensus points.

#### Round N (subsequent rounds)

Build a small incremental prompt for each role — **only** other roles' TL;DR for the previous round + this round's focus. The session already holds prior context, so don't repeat the proposal/challenge.

**Subsequent-round prompt** (`{role}-rN.md`):

```markdown
## Last round, other participants (TL;DR)
### {role name}
{2-3 sentence TL;DR}

### {another role name}
{2-3 sentence TL;DR}

## Focus this round
{focus chosen by the moderator}
```

Send sequentially: Role A → Role B → Defender (Defender speaks last so it can respond to all).

```bash
agent-session send \
  --role-id role-a \
  --prompt-file "$DEBATE_DIR/role-a-rN.md" \
  --state-dir "$SESSIONS_DIR"

agent-session send \
  --role-id defender \
  --prompt-file "$DEBATE_DIR/defender-rN.md" \
  --state-dir "$SESSIONS_DIR"
```

Read each role's new output:

```bash
agent-session output --role-id role-a --state-dir "$SESSIONS_DIR"     # latest round
# or specifically:
agent-session output --role-id role-a --round 2 --state-dir "$SESSIONS_DIR"
```

#### Summary & read strategy (token saving)

**[MUST]** When orchestrating, the main agent prefers reading the TL;DR section and **does not actively read full arguments**:

```bash
# Extract TL;DR — content between "## TL;DR" and the next "## "
agent-session output --role-id role-a --state-dir "$SESSIONS_DIR" \
  | sed -n '/^## TL;DR/,/^## /p' | sed '$d'
```

| Scenario | Read what |
|------|-------|
| Orchestrate next round (build incremental prompt) | TL;DR section only |
| Decide focus switch / convergence judgment | TL;DR + stance-tag distribution |
| Every-3-round checkpoint display | TL;DR + selectively read full argument |
| User asks "expand X's argument" | Read that role's full argument on demand |

Each role's session holds the full history in agent-session — the moderator never needs to "compress" turns; the role's TL;DR is already the compression.

**[MUST] False-consensus guard**: text-similarity alone misjudges "semantically similar but substantively different" stances as consensus. Inspect the stance-tag distribution:

```bash
# Extract stance tags from this round across all roles
for r in defender role-a role-b; do
  agent-session output --role-id "$r" --state-dir "$SESSIONS_DIR" 2>/dev/null
done | grep -hoE '\[stance: (hold|concede|add)\]'
```

| Stance distribution | Convergence | Action |
|---------|-------|------|
| All `hold` | Low | Disagreement remains; switch focus or continue |
| Mostly `concede` | High | Local convergence; advance or end |
| All `add` | — | Parallel expansion without dialogue — **beware false consensus**; at checkpoint, must read full arguments to verify |
| Mixed | Medium | Decide via TL;DR content |

The stance distribution is a structured signal that doesn't depend on text parsing; TL;DR text similar but stance tags different (e.g. both `hold`) is the strongest false-consensus warning.

#### Every-3-round checkpoint

**[MUST]** Pause every 3 rounds and present this to the user:

```markdown
## Discussion progress (rounds N–N+2)

### Consensus
- {points all parties agreed on}

### Divergence
- {view A} vs {view B} — core reason for disagreement: {...}

### Moderator judgment
- Convergence level: {High/Medium/Low}
- Suggestion: {continue along direction X / sufficient to decide}

### You decide
- {specific decision points}
```

Wait for the user's response:
- "continue" → 3 more rounds; the moderator sets the next focus based on current divergence
- "switch direction" → adjust the discussion focus
- "enough" / a decision is made → proceed to Step 4

### Step 4: Conclude (main agent)

```markdown
## Conclusion

### Original proposal
{brief}

### Final recommendation
{improved proposal after discussion, or keep original}

### Key arguments
- Defender's view: {...}
- {Role A}'s view: {...}
- {Role B}'s view: {...}

### Unresolved divergence (if any)
- {...}
```

### Step 5: Cleanup

```bash
# Close every spawned role's session and delete its state
for role in defender role-a role-b; do
  agent-session cleanup --role-id "$role" --state-dir "$SESSIONS_DIR" 2>/dev/null || true
done

# Remove the debate workspace (keeps disk clean; output is already in the conclusion)
rm -rf "$DEBATE_DIR"
```

**[MUST]** Cleanup runs automatically after the debate concludes. Don't wait for the user to ask.

If you used the parallel tmux mode (see `references/parallel-tmux.md`) or the live viewer (`references/visual-cmux-viewer.md`), each has its own additional cleanup step described in those references.

---

## Dependencies

| Component | Required | Purpose |
|---|---|---|
| `agent-session` skill | YES | Backend abstraction; install from this same repo |
| ≥2 backend CLIs from distinct families | YES | E.g. `claude` + `opencode`, or `claude` + `codex`. The protocol enforces ≥2 distinct families |
| tmux | optional (L2) | Parallel role execution; see [`references/parallel-tmux.md`](./references/parallel-tmux.md) |
| cmux + uv + Python ≥3.10 | optional (L3) | Live debate viewer (Textual TUI); see [`references/visual-cmux-viewer.md`](./references/visual-cmux-viewer.md) |

## Optional enhancements

The default flow above (sequential spawn + main-agent-prints-checkpoint) is fully functional with just `agent-session` installed.

- **Parallel role execution** — use tmux to run all roles concurrently (saves wall-clock time when calling slow backends): [`references/parallel-tmux.md`](./references/parallel-tmux.md)
- **Live TUI viewer** — show debate live in a cmux split pane with markdown rendering: [`references/visual-cmux-viewer.md`](./references/visual-cmux-viewer.md)

## Exception handling

| Situation | Handling |
|------|------|
| <2 distinct model families | Abort with install instructions (see step 2.2) |
| `agent-session spawn` fails | Read stderr; the role is marked `failed` in its `meta.json`. Either retry the role with a different backend, or proceed without it (mark `[failed]` in checkpoint summary) |
| `agent-session send` fails mid-round | Skip the failed role this round; log; continue with others |
| Role output is empty | Likely a backend hiccup; retry once via `agent-session send`; if still empty, skip the role this round |
| User Ctrl+C mid-flow | Run cleanup loop (step 5) in your trap so sessions don't leak |
| Defender persuaded to abandon original | Normal; record this shift at the next checkpoint |

## Integration

| Skill | Relationship |
|-------|------|
| `agent-session` | Hard dependency — backend abstraction. debate is the protocol caller |
| `cmux` (optional) | Used only by `references/visual-cmux-viewer.md` |
| upstream | None — `/debate` is user-triggered |
| downstream | None — conclusion is advisory; user decides next actions |
