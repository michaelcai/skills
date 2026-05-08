# michaelcai/skills — agent guide

This repo is a collection of Agent Skills (the `SKILL.md` format used by Claude Code, Codex, Cursor, Gemini CLI, OpenCode, and other compatible tools).

It is consumed in two ways:

1. **As a skill source** — end users install a skill by symlinking or copying `skills/<name>/` into their agent's skill directory (e.g. `~/.claude/skills/`).
2. **As a development workspace** — maintainers edit `skills/<name>/SKILL.md` here, run tests, then commit and push.

## When working *in* this repo

- The actual content shipped to users lives at `skills/<name>/SKILL.md` and `skills/<name>/references/`. Edit there.
- Each skill has its own `tests/` (bash + Python). Verify with `bash skills/<name>/tests/run-unit.sh`.
- `skills/agent-session/bin/agent-session` is a Python CLI (no third-party deps; Python 3.10+). It is the runtime backbone for `debate`.
- Do **not** introduce hardcoded model names. Model selection is delegated to backend CLIs and overridable via env vars (see `skills/debate/SKILL.md` §2.3.5).
- All shipped content is in English.

## Repo layout

```
.claude-plugin/marketplace.json     plugin marketplace manifest (Claude Code)
README.md                           install + skill index
LICENSE
skills/
├── agent-session/                  backend abstraction (claude / opencode / codex / ...)
│   ├── SKILL.md
│   ├── bin/agent-session           CLI implementation + drivers (executable)
│   ├── references/                 per-backend docs + how to add a backend
│   └── tests/run-unit.sh
└── debate/                         multi-model peer debate (depends on agent-session)
    ├── SKILL.md
    ├── references/                 optional enhancements (parallel-tmux, cmux viewer)
    └── tests/run-unit.sh
```

## Adding a skill

See `README.md` § Maintenance.

## Adding a backend (for `agent-session`)

See `skills/agent-session/references/adding-a-backend.md`.
