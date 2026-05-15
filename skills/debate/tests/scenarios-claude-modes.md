# Manual smoke scenarios — claude backend modes

These scenarios verify the three modes end-to-end. Each consumes real tokens / subscription quota / credit. Run from a live Claude Code session.

## Scenario 1: subprocess mode (regression check)

**Setup**:
```bash
unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
unset DEBATE_CLAUDE_BACKEND
```

**Run**:
```
/debate "我打算把内部服务间通信从 JSON 换成 protobuf" --claude-backend subprocess
```

**Expected**:
- Preflight gate shows `Claude backend mode: subprocess (--claude-backend override)`
- Debate runs via `agent-session spawn` / `send` for all claude roles (verify with `tail -F $DEBATE_DIR/logs/send-*.log`)
- 6/15 warning visible in gate
- Completes with TL;DRs + Argument files in `$DEBATE_DIR/`
- No regression vs pre-jam behavior

## Scenario 2: subagent mode (订阅友好默认)

**Setup**:
```bash
unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
unset DEBATE_CLAUDE_BACKEND
# (auth status should report Pro or Max subscriptionType)
```

**Run**:
```
/debate "我想给 agent-session 加 observability，不知道该用什么结构、关注哪些维度好"
```

**Expected**:
- Preflight gate shows `Claude backend mode: subagent (auto-detected: <plan> subscription, agent teams not enabled)`
- Round 1 spawn: moderator's assistant message contains N Agent tool_use blocks (one per role) in parallel — no `agent-session spawn` invocations for claude roles
- Each subagent returns TL;DR + Argument; moderator writes to `$DEBATE_DIR/outputs/<role>-r1.md`
- Subsequent rounds: prompt files in `$DEBATE_DIR/dispatch/<role>-rN.md` contain shared-context + role identity + accumulated history + this-round focus
- After-round step (stance/stage extraction) succeeds (reads from `outputs/`)
- Checkpoint Compiler runs as a dedicated Agent tool dispatch (Discovery preset)
- `/usage` shows plan usage bar going up; dollar API cost does NOT increase
- Cleanup: just `rm -rf $DEBATE_DIR`, no agent-session calls

## Scenario 3: teammates mode (experimental)

**Setup**:
```bash
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
unset DEBATE_CLAUDE_BACKEND
# Restart Claude Code if it was running before setting the env var
```

**Run**:
```
/debate "新设计的 rate limiter 用 token bucket + sliding window 组合，在 1000 req/s 突发 burst 下真的能维持 P99 < 50ms 吗？"
```

**Expected**:
- Preflight gate shows `Claude backend mode: teammates (auto-detected: <plan> subscription + CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1)`
- Moderator emits the team-creation natural-language instruction (per [`references/modes/claude-teammates.md`](../references/modes/claude-teammates.md) §Round 1)
- Anthropic runtime spawns 4 teammates (verifier / falsifier / triangulator / wildcard for Inquiry preset)
- Each subsequent round: moderator's assistant message contains N SendMessage calls in parallel
- Teammates persist; round-N prompts only contain peer TL;DRs + focus (not full history)
- Checkpoint Compiler is **lead-internal** — moderator writes Framing-Matrix-equivalent (Investigation progress for Inquiry preset) without spawning a Compiler teammate
- `/usage` shows plan usage bar going up faster than scenario 2 (7x token cost per Anthropic docs)
- Cleanup: moderator emits `Clean up the team`, then `rm -rf $DEBATE_DIR`
- After cleanup: `claude agents` (if available) shows no orphan teammates

## Failure scenarios to manually verify

- **A1**: `--claude-backend teammates` without `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` → preflight should fail with clear message
- **A2**: `--claude-backend teammates` on Claude Code <v2.1.32 → preflight should fail (version check in mode-claude-teammates.md prereqs)
- **A3**: subprocess mode hits a format violation → format-correction does an agent-session send (existing behavior)
- **A4**: subagent mode hits a format violation → format-correction does another Agent tool dispatch
- **A5**: teammates mode loses a teammate (simulate by manually `Ask <name> to shut down`) → moderator spawns a replacement with accumulated history

## Token cost ballpark (for ~52k subprocess baseline)

| Mode | Input tokens | Output tokens | Quota source |
|------|-------------|---------------|--------------|
| subprocess (pre-6/15) | ~40k | ~12k | subscription |
| subprocess (post-6/15) | ~40k | ~12k | **Agent SDK credit** ($) |
| subagent | ~150k (with cache: ~50k effective) | ~30k | subscription |
| teammates | ~280k | ~70k | subscription |

Cache hit rates and actual quota consumption to be measured during real runs.


---

# Persistence flow scenarios (added 2026-05-15)

These scenarios verify the prefs-first behavior introduced by the
`debate-claude-mode-persistence` jam.

## Scenario P1: First-run bootstrap dialog

**Setup**:
```bash
# Ensure prefs.json doesn't have the field (or doesn't exist at all)
jq 'del(.claude_backend_mode)' ~/.config/agents/debate/prefs.json > /tmp/p.json
mv /tmp/p.json ~/.config/agents/debate/prefs.json
```

**Run**:
```
/debate "我打算把内部服务间通信从 JSON 换成 protobuf"
```

**Expected**:
- §1.5 step 3 reads prefs.json, finds claude_backend_mode missing
- Moderator runs detect-claude-backend.sh to get a recommendation (likely `subagent` for Max subscription)
- AskUserQuestion shows 3 modes with `subagent (Recommended)` first
- User picks one, e.g., `subagent`
- `bootstrap-claude-backend.sh write ~/.config/agents/debate/prefs.json subagent` writes the field
- Preflight gate shows `Claude backend mode: subagent (just bootstrapped)`
- Debate proceeds normally
- After the run, `cat ~/.config/agents/debate/prefs.json | jq .claude_backend_mode` → `"subagent"`

## Scenario P2: Subsequent run reads prefs, no dialog

**Setup**: Scenario P1 already completed (prefs.json has `claude_backend_mode: "subagent"`).

**Run**:
```
/debate "新设计的 rate limiter 用 token bucket + sliding window 组合，真的能维持 P99 < 50ms 吗？"
```

**Expected**:
- §1.5 step 3 reads prefs.json, finds `claude_backend_mode: "subagent"`
- NO AskUserQuestion fired
- NO call to detect-claude-backend.sh
- Preflight gate shows `Claude backend mode: subagent (from prefs)`
- Debate proceeds

## Scenario P3: Per-invocation flag override (no write-back)

**Setup**: prefs.json has `claude_backend_mode: "subagent"`.

**Run**:
```
/debate "..." --claude-backend subprocess
```

**Expected**:
- Preflight gate shows `Claude backend mode: subprocess (--claude-backend override)`
- Debate runs in subprocess mode
- After the run, `cat ~/.config/agents/debate/prefs.json | jq .claude_backend_mode` → `"subagent"` (UNCHANGED)

## Scenario P4: Reconfigure flag clears + re-bootstraps

**Setup**: prefs.json has `claude_backend_mode: "subagent"`.

**Run**:
```
/debate "..." --reconfigure-claude-backend
```

**Expected**:
- §1.5 step 3 detects the flag, calls `bootstrap-claude-backend.sh clear`
- prefs.json field is now removed
- §2.2.5 bootstrap flow fires (AskUserQuestion or plain text)
- User can pick a different mode, e.g., `teammates` (assuming the env is set; otherwise the validation will fail downstream at first SendMessage call)
- After the run, `cat ~/.config/agents/debate/prefs.json | jq .claude_backend_mode` → the newly chosen mode

## Scenario P5: Manual edit (legacy / power user)

**Setup**:
```bash
jq '.claude_backend_mode = "teammates"' ~/.config/agents/debate/prefs.json > /tmp/p.json
mv /tmp/p.json ~/.config/agents/debate/prefs.json
```

**Run**:
```
/debate "..."
```

**Expected**: Preflight gate shows `Claude backend mode: teammates (from prefs)`. No dialog. (Note: if `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is not set, downstream SendMessage will fail per scenario A1 in the earlier section — that's expected.)

## Scenario P6: Bogus value in prefs.json aborts cleanly

**Setup**:
```bash
jq '.claude_backend_mode = "bogus"' ~/.config/agents/debate/prefs.json > /tmp/p.json
mv /tmp/p.json ~/.config/agents/debate/prefs.json
```

**Run**:
```
/debate "..."
```

**Expected**: §1.5 step 3 validation catches the bogus value and aborts with `Invalid claude_backend_mode: 'bogus' (expected subprocess|subagent|teammates)`. User must manually fix prefs.json or run `--reconfigure-claude-backend`.
