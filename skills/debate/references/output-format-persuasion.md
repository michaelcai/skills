# Output format (mandatory for every debate role)

Every role's output — first turn and every subsequent round — MUST follow this exact structure. The moderator depends on the section markers (`## TL;DR`, `## Argument`) and the stance tag pattern (`[stance: hold|concede|add]`) to extract structured signals via agent-session's `tldr` verb.

```
## TL;DR
(2-3 sentences with the core view)
[stance: hold|concede|add]

## Argument
(150-300 words, supported by specific code/technical detail)
```

## Why this format

- `## TL;DR` and `## Argument` are H2 headings: they delimit the cheap-to-read summary from the full evidence.
- `[stance: ...]` is a literal bracketed tag: machine-extractable independent of TL;DR text.
- The three stance values (`hold`, `concede`, `add`) are a closed set: see [`stance-tags-persuasion.md`](./stance-tags-persuasion.md) for semantics.

## Drift = silent failure

If a role omits `## TL;DR` or uses a different stance value, the `tldr` verb returns `tldr_text: null` or `stance: null`. The moderator's false-consensus guard then surfaces the affected role explicitly (a \"≥1 null stance\" distribution row) — but only because the format is rigid. Loosening any of the four landmarks above makes the drift undetectable.

This is the invariant `tests/manifest-invariants.sh` enforces:

- contains `## TL;DR`
- contains `[stance:`
- contains all of `hold`, `concede`, `add`
- contains `## Argument`
