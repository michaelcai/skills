# Stance tags (Discovery preset)

Closed set: `{expand, challenge, connect, converge}`. All other values surface as `null` (format drift).

## Per-role mutex

| Role | Allowed stances | Why |
|---|---|---|
| explorer | `expand`, `connect`, `converge` | Explorer works within their assigned framing axis. They may go deeper (`expand`), incorporate peer signal into their axis (`connect`), or note where their axis aligns/cannot align with peers (`converge`). They do NOT `challenge` the axes set itself — that is Wildcard's job. |
| wildcard | all 4 values | Wildcard may cross frames freely and is the only role that can `challenge` framing premises. |
| compiler | none — Compiler does not emit `[stance:]` | Compiler is a synthesizer (produces the checkpoint matrix) not a participant; format-correction triggers if Compiler emits any tag. |

## Moderator's reading

| Distribution | Reading |
|---|---|
| Many `expand`, few `connect` | Explorers are deepening but not learning across axes — moderator may probe for connections explicitly in next round's focus block |
| Many `connect` | Healthy cross-pollination |
| Wildcard `challenge` | A framing premise has been questioned — moderator decides whether to add/remove a framing axis before next round |
| Many `converge` | Approaching settled — likely checkpoint-ready |
| Compiler emits any stance | Format violation (Compiler must not participate as a debater) |
