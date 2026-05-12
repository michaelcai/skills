# Stance tags

Every role's TL;DR carries a `[stance: hold|concede|add]` tag. The tag matters from round 2 (round 1 is always `add`).

| Tag | Meaning | Moderator interpretation |
|---|---|---|
| `hold` | Maintains stance after counter-argument | Disagreement remains |
| `concede` | Adjusts own stance toward another role's view | Local convergence |
| `add` | Parallel expansion (no direct response to peers) | Beware false consensus when widespread |

## Closed set

The whitelist is exactly `hold`, `concede`, `add` — agent-session's `tldr` verb only accepts these three. Any other word inside `[stance: ...]` returns `stance: null` to the moderator, which surfaces as \"format drift\" in the false-consensus guard (§Round N).

## Why three tags

Two tags (agree/disagree) collapse the \"I'm building on this without engaging\" case into either category, which is exactly the false-consensus failure mode. Four tags introduce a bikeshed about whether \"partial agree\" is `partial` or `nuance` — `concede` already covers it adequately. Three is the smallest set that distinguishes engagement (`hold`/`concede`) from non-engagement (`add`).
