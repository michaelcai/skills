---
preset: persuasion
primitives:
  role-topology:
    roles: [defender, role-a, role-b, wildcard]
    role-b-conditional: true
  stance-contract:
    values: [hold, concede, add]
    null-policy: format-correction-then-respawn
    distribution-interpretation:
      all-hold: low-convergence-continue
      mostly-concede: local-convergence
      all-add: false-consensus-warning
      mixed: medium-decide-via-tldr
  checkpoint-policy:
    trigger: every-3-rounds
    display: [consensus, divergence, moderator-judgment, you-decide]
  output-format:
    file: ../output-format-persuasion.md
---

# Persuasion mode

Resolves a difference of opinion between a defender of the original proposal and one or more focused critics. The wildcard provides a divergent axis to guard against everyone attacking from the same angle.

## When to use

- "Is X correct?" / "Is approach Y better than Z?" / "Does this proposal hold up?"
- Implicit assumption: a defensible position exists, the question is whether it survives examination.
- Avoid for trade-off questions ("should we do X" when the answer depends on which lens) — use `deliberation` preset instead.

## Cognitive structure

Asymmetric: 1 defender vs N critics. Convergence happens when:
- defender concedes a critic's point (stance shifts `add → concede`) — local resolution
- defender holds against all critics (stance `hold` × N) — proposal survives examination

The wildcard is structural insurance: forces consideration of axes the focused critics may share blind spots on.

## Walton type

Persuasion (Critical Discussion). See *The New Dialectic* (Walton 1998).
