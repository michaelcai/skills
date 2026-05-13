# Output format (Discovery preset)

Every role's reply MUST be exactly two H2 sections, in this order:

## TL;DR
(2-3 sentences from your Explorer / Wildcard framing — what you propose or how you've refined.)
[stage: propose|refine|settle]
[stance: expand|challenge|connect|converge]

## Argument
(150-300 words. Make the framing axis you're representing explicit; explain why the proposal makes sense from inside that axis.)

## Stage vocabulary (round protocol)

| stage | semantics | allowed in |
|---|---|---|
| `propose` | First proposal under your framing axis. | R1 only |
| `refine` | Revised proposal incorporating peers' R1 inputs. | R2+ |
| `settle` | This point will not move further (either converged with peers or marked irreducibly divergent). | R2+ |

## Stance vocabulary (argumentative function)

| stance | semantics |
|---|---|
| `expand` | Adds further detail / depth within your own framing axis. |
| `challenge` | Questions the premise of another framing axis OR the framing-axes set itself. (Wildcard only — Explorers stay in-axis.) |
| `connect` | Maps a peer's proposal back into your axis / acknowledges learning from a peer. |
| `converge` | This part of your framing now agrees with peer(s); or this part is irreducibly different and won't move. |

## Hard rules

1. Both `[stage:]` and `[stance:]` lines MUST appear inside the TL;DR block.
2. R1 stage MUST be `propose`; R2+ stage MUST be in `{refine, settle}`.
3. Explorer stance MUST be in `{expand, connect, converge}`. Wildcard stance may be anything in the vocabulary. Compiler does NOT emit `[stage:]` or `[stance:]` — Compiler only produces the checkpoint synthesis.
4. Speak from inside your assigned framing axis (Explorer) or as a cross-frame challenger (Wildcard).
