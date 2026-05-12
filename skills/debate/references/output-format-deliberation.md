# Output format (Deliberation preset)

Every role's reply MUST be exactly two H2 sections, in this order:

## TL;DR
(2-3 sentences from your stakeholder's perspective — what this option looks like through their lens)
[stance: prefer|accept|oppose|abstain]

## Argument
(150-300 words. State your stakeholder's win-condition for this proposal, their red-line, what trade they'd accept, and any condition that flips your stance.)

## Stance vocabulary

| stance | semantics |
|---|---|
| `prefer` | Matches your stakeholder's core priority. |
| `accept` | Not optimal but no red-line touched; you can live with it. |
| `oppose` | Touches your stakeholder's red-line; recommend rejection. |
| `abstain` | Your stakeholder has no strong preference on this dimension. Better than a false-positive `prefer`. |

## Hard rules

1. The bracketed `[stance: X]` line MUST appear on a line of its own inside the TL;DR block, after the 2-3 prose sentences.
2. `X` is exactly one value from the vocabulary above. Compound stances (`prefer on cost, oppose on velocity`) violate this rule and will be rejected — the moderator runs format-correction.
3. Speak in the first-person voice of your stakeholder. Don't break frame to compare options abstractly; argue from the lens you were assigned.
