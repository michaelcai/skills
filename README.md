# michaelcai/skills

Agent skills collection.

## Skills

| Skill | Description |
|---|---|
| [debate](./skills/debate/) | Multi-model multi-role peer debate. Main agent moderates while ≥2 distinct model families argue. Detects false consensus via stance tags. |
| [agent-session](./skills/agent-session/) | Persistent multi-turn LLM session abstraction over heterogeneous backend CLIs (`claude`, `opencode`, `codex`...). Used by `debate`; reusable by other skills. |

## Install

### Option 1 — Claude Code (recommended)

```
/plugin marketplace add michaelcai/skills
/plugin install michaelcai-skills@michaelcai-skills
```

Skills are then invoked with the namespace prefix: `/michaelcai-skills:debate`.

**Post-install (one-time, required).** `debate` shells out to the `agent-session` binary, which the Claude Code marketplace doesn't auto-expose on `PATH`. Symlink it:

```bash
ln -sf "$HOME/.claude/plugins/marketplaces/michaelcai-skills/plugins/michaelcai-skills/skills/agent-session/bin/agent-session" \
  /usr/local/bin/agent-session
```

(Adjust the source path if your Claude Code stores plugins elsewhere — `find ~/.claude -name 'agent-session' -path '*/bin/*' 2>/dev/null` finds it.)

`/usr/local/bin` is preferred over `~/.local/bin` because **macOS GUI Claude Code launches via launchd, which does NOT inherit your shell's `PATH`** — `~/.local/bin` may resolve in your terminal but not from Claude Code's `Bash` tool. `/usr/local/bin` is on the launchd default path. Verify:

```bash
agent-session doctor
```

### Option 2 — Any SKILL.md-compatible agent (Codex / Cursor / Gemini CLI / OpenCode etc.)

```bash
git clone https://github.com/michaelcai/skills.git ~/.michaelcai-skills
ln -s ~/.michaelcai-skills/skills/debate         ~/.claude/skills/debate
ln -s ~/.michaelcai-skills/skills/agent-session  ~/.claude/skills/agent-session
sudo ln -s ~/.michaelcai-skills/skills/agent-session/bin/agent-session /usr/local/bin/agent-session
```

The third symlink puts the binary on `PATH` for both your terminal and (on macOS) the GUI Claude Code app. If you can't `sudo`, use `~/.local/bin` instead and add `export PATH="$HOME/.local/bin:$PATH"` to your shell rc — but be aware that **macOS GUI apps launched via launchd ignore your shell rc**; the symlink will resolve in your terminal but not from Claude Code's Bash tool. Alternative: `launchctl setenv PATH "$HOME/.local/bin:$PATH"` once.

Verify:

```bash
agent-session doctor
```

To update:

```bash
cd ~/.michaelcai-skills && git pull
```

### Option 3 — Single skill, no update tracking

```bash
curl -L https://github.com/michaelcai/skills/archive/main.tar.gz \
  | tar xz --strip-components=2 skills-main/skills/debate
mv debate ~/.claude/skills/
# (and similarly for agent-session — debate depends on it)
```

## Backend prerequisites for `debate`

`debate` requires ≥2 distinct model families. Install at least one of each:

- **Anthropic family**: [`claude` CLI](https://claude.com/install)
- **OpenAI family**: [`opencode`](https://opencode.ai) (multi-provider — recommended) or [`codex`](https://platform.openai.com/docs/codex)

Verify:

```bash
agent-session doctor
```

Expected:

```
Multi-model capability: ✓
```

## `agent-session` CLI verbs

- `tldr` — extract TL;DR + stance from the latest round as JSON

## Examples & tests

- [`examples/quickstart.md`](./examples/quickstart.md) — verify `agent-session` end-to-end after install (real captured outputs)
- [`examples/sample-debate.md`](./examples/sample-debate.md) — illustrative `/debate` transcript: proposal, challenge, 2 rounds, checkpoint, conclusion
- [`examples/test-cases.md`](./examples/test-cases.md) — complete acceptance test suite (install init, single-backend smoke, debate end-to-end). Run after install.

### Test-time dependencies

- `pyyaml` (only used by `skills/debate/tests/manifest-invariants.sh`). The smoke test SKIPs cleanly without it; CI should install it for strict invariant verification:
  ```bash
  pip install pyyaml
  # or with uv:
  uv pip install pyyaml
  ```

## Maintenance (for the author)

Edit `skills/<name>/SKILL.md` directly, then commit + push to publish.

To add a new skill:

1. `mkdir skills/<name>`
2. Write `skills/<name>/SKILL.md`
3. Add relevant keywords to `.claude-plugin/marketplace.json`
4. Add a row to the table in this README
5. Commit + push

## License

MIT — see [LICENSE](./LICENSE).
