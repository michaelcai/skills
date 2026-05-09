# Test cases: install validation + skill verification

Acceptance tests for this repo. Run each suite after a fresh install (or after pulling updates) to confirm everything is wired up.

## Test conventions

- Each case: **Goal**, **Steps** (verbatim runnable), **Pass criteria**, **Troubleshooting**.
- Suites are ordered: A (install) → B (single backend) → C (debate). Run in order.
- All commands assume `agent-session` is on `PATH`. If not, replace with the full Python invocation.

---

## Suite A — Install initialization

### A1. Skill files discoverable

**Goal**: Claude Code (or your agent CLI) sees the two skills.

```bash
ls -la ~/.claude/skills/debate ~/.claude/skills/agent-session
```

**Pass**: Both paths resolve (symlink or directory). For Plugin Marketplace installs, also accepted: `ls ~/.claude/plugins/...michaelcai-skills*/skills/`.

**Troubleshooting**:
- Missing → re-run install (README §Install Option 2 gives the symlink commands).
- Stale symlink (`ls` shows `→ /no/such/path`) → remove and re-create.

### A2. agent-session CLI on PATH

```bash
which agent-session && agent-session --help | head -3
```

**Pass**: prints `/usr/local/bin/agent-session` (or `~/.local/bin/agent-session`) and the usage line.

**Troubleshooting**:
- `command not found` → either install via plugin (the plugin adds `bin/` to PATH automatically) or `ln -s ~/.michaelcai-skills/skills/agent-session/bin/agent-session ~/.local/bin/agent-session` (and ensure `~/.local/bin` is in your PATH).

### A3. Backend CLIs detected

```bash
agent-session doctor
```

**Pass**: Output contains:
- At least 2 lines starting with `✓ ` (e.g. `✓ claude` and `✓ opencode` or `✓ codex`)
- `Multi-model capability: ✓`
- `Distinct model families: 2` (or more)

**Troubleshooting**:
- `✗ claude` → install Claude CLI: `curl -fsSL https://claude.ai/install.sh | bash`, then `claude` once to log in.
- `✗ opencode` → either install opencode and `oc-task` (see `skills/agent-session/references/backend-opencode.md`), or accept it and ensure `codex` is installed.
- `✗ codex` → `npm install -g @openai/codex && codex login`.
- `Multi-model capability: ✗` → at least one non-Claude backend is required for `debate`. Install one of the above.

### A4. Unit test suites pass (offline, no API calls)

```bash
bash ~/.michaelcai-skills/skills/agent-session/tests/run-unit.sh
bash ~/.michaelcai-skills/skills/debate/tests/run-unit.sh
```

(Adjust path to where you cloned the repo.)

**Pass**:
- `agent-session`: `Result: 20 passed, 0 failed`
- `debate`: `Result: 24 passed, 0 failed`

**Troubleshooting**:
- Any failure → file a bug at https://github.com/michaelcai/skills/issues with the failing assertion's name. Tests are pure-bash + python3-stdlib, so failures usually mean a structural / refactor regression, not an environment issue.

---

## Suite B — Single-backend invocation (via `agent-session` directly)

These tests exercise `agent-session` against real backends. **Each test makes a real API call (small; ~100 tokens).**

Setup once for the suite:

```bash
mkdir -p /tmp/agent-session-tests && cd /tmp/agent-session-tests
echo "Reply with exactly the word READY and nothing else." > p_ready.md
echo "My name is Alice. Reply with: NICE TO MEET YOU ALICE" > p_intro.md
echo "What is my name? Reply with just the name, one word." > p_query.md
```

### B1. claude — basic spawn + output

```bash
agent-session spawn --backend claude --role-id b1 --prompt-file ./p_ready.md --state-dir ./state --model haiku
agent-session output --role-id b1 --state-dir ./state
agent-session cleanup --role-id b1 --state-dir ./state
```

**Pass**: `output` prints `READY` (case-insensitive, may have trailing whitespace).

**Troubleshooting**:
- "Login required" → run `claude` interactively once.
- Empty output → check `./state/b1/log` for stderr.

### B2. opencode — basic spawn + output

```bash
agent-session spawn --backend opencode --role-id b2 --prompt-file ./p_ready.md --state-dir ./state --model openai/gpt-5.4-mini
agent-session output --role-id b2 --state-dir ./state
agent-session cleanup --role-id b2 --state-dir ./state
```

**Pass**: `output` prints `READY` (or close — opencode's model may add slight variance).

**Troubleshooting**:
- "Model not supported" / "ProviderModelNotFoundError" → the configured opencode default model is unavailable for your auth. Pick a model from `opencode models` and pass it via `--model`.
- "opencode run produced no sessionID" → the NDJSON shape may have changed in a newer opencode. Run `opencode run "test" --format json | head` and confirm events still carry `sessionID`.

### B3. codex — basic spawn + output

```bash
agent-session spawn --backend codex --role-id b3 --prompt-file ./p_ready.md --state-dir ./state
agent-session output --role-id b3 --state-dir ./state
agent-session cleanup --role-id b3 --state-dir ./state
```

**Pass**: `output` prints `READY`.

**Troubleshooting**:
- "No such file or directory" → known absolute-path bug, fixed in commit `dc863a5` or later. `git pull`.
- Codex prompts for approval → ensure `--full-auto` is in the driver's `_common_flags`.

### B4. Cross-round memory (the critical foundation for `debate`)

Pick any backend (`claude` is fastest):

```bash
agent-session spawn --backend claude --role-id b4 \
  --prompt-file ./p_intro.md --state-dir ./state --model haiku
agent-session output --role-id b4 --state-dir ./state
# expected: NICE TO MEET YOU ALICE

agent-session send --role-id b4 \
  --prompt-file ./p_query.md --state-dir ./state
agent-session output --role-id b4 --state-dir ./state
# expected: Alice  (proves the session remembers round 0)

agent-session describe --role-id b4 --state-dir ./state
# expected JSON: round_count == 2, state == "active"

agent-session cleanup --role-id b4 --state-dir ./state
```

**Pass**: All three expectations hold.

**Troubleshooting**:
- r1 returns the same text as r0 → session is being created fresh on `send` instead of resuming. Check the driver's `send()`: it should pass `--resume <sid>` (claude) or use `cwd=` (codex) or `oc-task send` (opencode).
- r1 returns "What is my name?" verbatim → backend echoed the prompt; check `--system-prompt` constraints.

### B5. Practical: code-review with a single backend

Real use case: spawn an agent to review a snippet.

```bash
cat > /tmp/agent-session-tests/p_review.md <<'PROMPT'
Review this Python function and list any bugs in 3 bullet points or fewer.
Output format: TL;DR, then bullets. Be concise.

```python
def divide(a, b):
    return a / b
```
PROMPT

agent-session spawn --backend claude --role-id reviewer \
  --prompt-file ./p_review.md --state-dir ./state \
  --system-prompt "You are a senior Python reviewer."
agent-session output --role-id reviewer --state-dir ./state

# follow-up question
echo "If a and b are integers, what does Python 3 return for divide(7, 2)?" > ./p_followup.md
agent-session send --role-id reviewer --prompt-file ./p_followup.md --state-dir ./state
agent-session output --role-id reviewer --state-dir ./state

agent-session cleanup --role-id reviewer --state-dir ./state
```

**Pass**:
- Round 0 output identifies "no zero check" / "no type validation" / similar.
- Round 1 says `3.5` (Python 3's true division). Proves session retained context that we're talking about the `divide` function.

**Troubleshooting**:
- Round 1 answer doesn't reference round 0's function → session memory broken (see B4 troubleshooting).

### B6. Cleanup is idempotent

```bash
# clean a non-existent role
agent-session cleanup --role-id never-existed --state-dir ./state
echo "exit code: $?"   # expected: 0
```

**Pass**: exit code is 0; no error printed.

---

## Suite C — Debate end-to-end (interactive)

`debate` is a user-invocable skill. The main agent (your Claude Code session) reads `skills/debate/SKILL.md` and orchestrates. These tests verify the full skill flow rather than the CLI plumbing.

### C1. Backend preflight rejects single-family setups

**Setup** (simulate "only claude installed"):

```bash
# Temporarily hide the non-claude backends
sudo mv $(which opencode) /tmp/opencode.hidden 2>/dev/null
sudo mv $(which codex)    /tmp/codex.hidden    2>/dev/null
agent-session doctor
```

**Pass**: `Multi-model capability: ✗`.

Now from a Claude Code session, ask: `/debate "test"`.

**Pass**: The main agent (following SKILL.md §2.2) refuses to start, reports something like:
> Cannot start debate: fewer than 2 distinct model families detected. Install at least one non-Claude backend (opencode, codex, gemini).

**Cleanup**:

```bash
sudo mv /tmp/opencode.hidden $(dirname $(which agent-session))/opencode 2>/dev/null
sudo mv /tmp/codex.hidden /opt/homebrew/bin/codex 2>/dev/null
agent-session doctor   # confirm Multi-model: ✓ again
```

### C2. Debate happy path (small)

In a Claude Code session, ensure a recent agent message contains a proposal/opinion. Then run:

```
/debate "I'm not sure this scales to 10x users"
```

**Pass criteria** (end-to-end):
1. Main agent presents context confirmation (Original proposal, Challenge, Planned participants). Confirm.
2. Main agent runs `agent-session doctor` and verifies multi-model.
3. Main agent spawns at least 2 roles using **2 distinct backend families** (e.g. claude + opencode/codex).
4. Round-1 outputs are visible (or polled via `agent-session output --role-id <name>`).
5. Each role's output has the structure: `## TL;DR ... [stance: <hold|concede|add>] ... ## Argument ...`. Round-1 stances are all `add`.
6. After 3 rounds, main agent presents a **checkpoint** (Consensus / Divergence / Moderator judgment / You decide).
7. Say "enough"; main agent produces a **conclusion** with key arguments.
8. Main agent runs `agent-session cleanup` for every role; `/tmp/debate-*` is removed.

**Troubleshooting**:
- Step 3 fails with "≥2 distinct families" rule even though `doctor` shows ✓ → an env var (`DEBATE_*_BACKEND`) may be forcing all roles to one family. Check `env | grep DEBATE_`.
- Step 5 stance tag missing → the `--system-prompt` (FORMAT_RULE) is not being passed; check the spawn command in step 2.6 of SKILL.md.

### C3. User preference via env vars

```bash
export DEBATE_DEFENDER_BACKEND=codex
export DEBATE_DEFENDER_MODEL=gpt-5
export DEBATE_ROLE_A_BACKEND=claude
export DEBATE_ROLE_A_MODEL=opus
```

In Claude Code: `/debate "your test challenge"`.

**Pass**: Main agent's spawn commands honor these env vars: Defender uses codex, Role A uses claude. Verify mid-debate by asking the main agent: "What backend is each role using?" or by inspecting `agent-session describe --role-id defender --state-dir <dir>`.

**Cleanup**: `unset DEBATE_DEFENDER_BACKEND DEBATE_DEFENDER_MODEL DEBATE_ROLE_A_BACKEND DEBATE_ROLE_A_MODEL`.

### C4. Stance tag → false-consensus detection

Set up a debate where parties might appear to agree on the surface but actually have different stances.

**Pass**: At a checkpoint, the main agent surfaces "stance distribution: e.g. all `add` → beware false consensus" and flags it explicitly rather than silently declaring convergence.

(This is a qualitative check — the main agent's behavior under the §3 "False-consensus guard" rule.)

---

## Suite D — prefs.json bootstrap & assignment (interactive)

These tests verify SKILL.md §2.2.5 (prefs.json) and §2.3 (assignment algorithm). Each is a behavioral check on the main agent's flow, not a CLI test.

### D1. First-run bootstrap

**Setup**:

```bash
mv ~/.config/agents/debate/prefs.json /tmp/prefs.bak 2>/dev/null
```

In a Claude Code session: `/debate "test"`.

**Pass**:
1. Main agent prints `prefs.json not found — let's set it up.`
2. Lists detected backends + families (matches `agent-session doctor`).
3. Asks for confirmation in **plain text** (not via `AskUserQuestion`).
4. After "Y", file `~/.config/agents/debate/prefs.json` exists with `version: 1`, `agents` array containing all detected backends, each with `model: null`.
5. Debate proceeds.

**Verify**:

```bash
cat ~/.config/agents/debate/prefs.json | python3 -m json.tool
```

**Cleanup** (if you want to repeat): remove the file again.

### D2. Idempotent read on subsequent runs

With prefs.json in place from D1, run `/debate "test"` again.

**Pass**:
- No "prefs.json not found" message.
- No re-prompt for backend selection.
- Main agent goes straight to the §2.3.1 "Debate assignment: …" block.

### D3. Incremental backend change prompts

**Setup** (simulate an installed-but-not-in-prefs backend by hand-editing):

```bash
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.config/agents/debate/prefs.json")
data = json.load(open(p))
data["agents"] = [a for a in data["agents"] if a["backend"] != "codex"]
json.dump(data, open(p, "w"), indent=2)
PY
agent-session list-backends    # ensure codex is still detected
```

In Claude Code: `/debate "test"`.

**Pass**: Main agent notices `codex` is detected but not in the pool and asks (plain text):
> codex is now installed; add it to your debate pool? (Y/n)

After "Y", the file is rewritten and the debate proceeds with codex available for assignment.

### D4. Decision print + user confirmation

For any debate run (D1, D2, or any /debate call), before any `agent-session spawn`:

**Pass**: Main agent prints a block like:

```
Debate assignment:
  Defender = claude   (default model)
  Role A   = opencode (default model)
Pool source: ~/.config/agents/debate/prefs.json
Begin? (Y/n)
```

and waits for the user before spawning. If user says "n" or proposes a swap, the assignment is recomputed (or P1 inline override is honored).

**Restore prefs after Suite D**:

```bash
mv /tmp/prefs.bak ~/.config/agents/debate/prefs.json 2>/dev/null
```

---

## Final teardown

```bash
rm -rf /tmp/agent-session-tests
```

---

## Suite results template

When running all suites, summarize:

```
Suite A (install):           [_/4]   notes:
Suite B (single backend):    [_/6]   notes:
Suite C (debate):            [_/4]   notes (qualitative):
Suite D (prefs.json):        [_/4]   notes (qualitative):
```

`A` and `B` should be mechanically green. `C` is necessarily interactive — record the LLM's behavior and flag any deviations from SKILL.md.
