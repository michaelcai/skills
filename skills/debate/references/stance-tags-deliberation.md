# Stance tags (Deliberation preset)

Closed set: `{prefer, accept, oppose, abstain}`. All other values surface as `null` (format drift signal).

| value | when to use | when NOT to use |
|---|---|---|
| `prefer` | This option matches your stakeholder's #1 priority. | If you can also live with another option — that's `accept`. |
| `accept` | Your red-line is not touched; not your first choice but workable. | If you actually have a preference but are being polite. |
| `oppose` | Your stakeholder's red-line is touched — this option, if chosen, harms them in a way they can't absorb. | If you just don't like it. Disagreement-without-red-line is `accept` or `abstain`. |
| `abstain` | Your stakeholder has no skin in this particular dimension. | If you do have an opinion but are unsure — `accept` is honest, `abstain` is evasive. |

## Moderator's reading

| Distribution | Reading |
|---|---|
| All `prefer` or `accept`, none `oppose` | Trade-off appears resolved; can checkpoint early. |
| Any `oppose` | Irreducible conflict; user needs explicit trade-off resolution. |
| Majority `abstain` | Stakeholder list may be wrong — moderator considers re-extracting. |
| Mix of `prefer` and `oppose` | Core tension; continue discussion to test if positions are flexible. |
