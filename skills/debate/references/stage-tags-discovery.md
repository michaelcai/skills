# Stage tags (Discovery preset)

Closed set: `{propose, refine, settle}`. Stage tracks **round protocol** — what phase of the Discovery process the reply belongs to. This is independent of `[stance:]` which tracks the **argumentative function** of the reply.

## Round mutex (enforced)

| Round | Allowed stages |
|---|---|
| R1 | `propose` only — all participants make first independent proposals |
| R2 | `refine` or `settle` — must show movement OR explicit lock |
| R3+ | `refine` or `settle` — same as R2 |

## Why a separate tag

Discovery's process has a *direction* (independent ideation → cross-pollination → convergence/divergence). Existing stance vocabularies in other presets are position-only (`hold`/`concede`/`add` etc.) and lose the "did this role learn from peers this round" signal if it's encoded into stance. Two tags also let the moderator validate them independently — a role producing `[stance: converge]` at R1 still violates `[stage: propose]` and the format-correction can target the right tag.

## Moderator's reading

| Distribution | Reading |
|---|---|
| All R2+ stages = `refine` | Healthy cross-pollination; continue rounds |
| ≥1 stage = `settle` at R2 (premature) | Role gave up early; check Argument for whether they hit a real wall or just disengaged |
| All R3 stages = `settle` | Discovery complete; produce final framing matrix |
| Compiler emits any `[stage:]` or `[stance:]` | Format violation — Compiler is a synthesizer not a participant |
