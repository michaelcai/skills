# Adding a new backend

To plug a new LLM CLI into agent-session, implement a `Driver` subclass.

## Steps

1. Add a class to `scripts/agent_session.py` (or, for big drivers, split into `drivers/<name>.py`)
2. Register it in the `DRIVERS` list
3. Add `references/backend-<name>.md` with install steps for users
4. Add tests in `tests/`

## Driver contract

```python
class MyBackendDriver(Driver):
    name = "mybackend"           # CLI keyword: agent-session spawn --backend mybackend
    family = "openai"            # one of: anthropic, openai, google, local, unknown
                                 # used by callers to judge "≥2 distinct families"

    @classmethod
    def detect(cls) -> Optional[str]:
        """Return path to the backend CLI if available, else None."""

    @classmethod
    def models(cls) -> list[str]:
        """List of model aliases this backend can drive (best-effort)."""

    def spawn(self, role_id, prompt_file, model, state_dir, system_prompt) -> None:
        """Create a session and run the first turn.
        Must write meta.json with at least: backend, family, model, sid, round_count, state.
        Must write output/r0.txt with the assistant message text.
        Raise RuntimeError on failure (caller catches and reports)."""

    def send(self, role_id, prompt_file, state_dir) -> None:
        """Continue the session with a follow-up turn.
        Increments meta.round_count, writes output/r<n>.txt.
        Raises if session not active."""

    def status(self, role_id, state_dir, wait, timeout) -> str:
        """Return one of: running, done, error. Read meta + check process state."""

    def cleanup(self, role_id, state_dir) -> None:
        """Close backend session resources and rmtree(state_dir/<role_id>).
        Idempotent — never raises on missing session."""
```

## Conventions

- **Synchronous spawn / send**: agent-session's caller protocol assumes spawn and send block until the assistant has spoken. Async backends should still wait inside the driver.
- **State exclusively via `meta.json`**: any backend-specific session id (`sid`), daemon port, etc. lives in meta — never expose to the caller.
- **No prompts in stdout**: the driver writes output to `output/r<n>.txt`. The caller reads via `agent-session output`.
- **Append-only log**: write debug info to `state_dir/<role_id>/log` for post-mortem.
- **Idempotent cleanup**: must succeed on missing or corrupt sessions (return without error).

## Family taxonomy

For multi-model judgement, use one of these `family` values:

| Family | Examples |
|---|---|
| `anthropic` | claude, kimi-claude (a Claude wrapper) |
| `openai` | codex, opencode-default-gpt, raw GPT API |
| `google` | gemini |
| `local` | ollama, llama.cpp, mlx |
| `unknown` | hybrid / unclear |

When in doubt, use `unknown` — callers will treat it as its own family for distinctness counting.

## Testing

Add at least:

- `tests/test_<name>_detect.sh` — verifies `agent-session list-backends` shows your backend when CLI is on PATH
- `tests/test_<name>_smoke.sh` — end-to-end spawn → send → output → cleanup, gated on the actual CLI being installed (skip if `command -v <cli>` fails)

## Check list before submitting

- [ ] Driver class registered in `DRIVERS`
- [ ] `detect()` returns path string or None — never raises
- [ ] `cleanup()` is idempotent
- [ ] `meta.json` has all 6 required fields
- [ ] `references/backend-<name>.md` written
- [ ] Smoke test passes when backend installed
