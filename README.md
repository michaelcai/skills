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

### Option 2 — Any SKILL.md-compatible agent (Codex / Cursor / Gemini CLI / OpenCode etc.)

```bash
git clone https://github.com/michaelcai/skills.git ~/.michaelcai-skills
ln -s ~/.michaelcai-skills/skills/debate         ~/.claude/skills/debate
ln -s ~/.michaelcai-skills/skills/agent-session  ~/.claude/skills/agent-session
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

## Examples

- [`examples/quickstart.md`](./examples/quickstart.md) — verify `agent-session` end-to-end after install (real captured outputs)
- [`examples/sample-debate.md`](./examples/sample-debate.md) — illustrative `/debate` transcript: proposal, challenge, 2 rounds, checkpoint, conclusion

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
