---
preset: deliberation
primitives:
  role-topology:
    roles: [stakeholder, synthesizer]
    role-multiplicity:
      stakeholder: 2-4
    stakeholder-extraction: from-challenge-text-confirmed-in-preflight
  stance-contract:
    values: [prefer, accept, oppose, abstain]
    null-policy: format-correction-then-respawn
    distribution-interpretation:
      all-prefer-or-accept: trade-off-resolved
      any-oppose: irreducible-conflict
      majority-abstain: stakeholder-list-may-be-wrong
      mixed-prefer-oppose: core-tension-continue
  checkpoint-policy:
    trigger: all-stakeholders-contributed-AND-(round-3-OR-all-prefer-accept)
    display: [trade-off-matrix, synthesizer-recommendation, you-decide]
  output-format:
    file: ../output-format-deliberation.md
---

# Deliberation mode

Selects a best course of action under uncertainty when multiple legitimate stakeholders have conflicting priorities. The goal is NOT consensus — it is making the trade-off explicit so a decision-maker can weigh it.

## When to use

- "Should we do X?" / "X or Y or stay put?" / "Is it worth doing X given Y?"
- The challenge implies trade-offs across affected parties (security vs velocity, current users vs new users, cost vs flexibility).
- Avoid when there's no real stakeholder conflict — `persuasion` is faster.

## Cognitive structure

Symmetric: N stakeholder advocates + 1 synthesizer. Each stakeholder argues from a fixed lens; the synthesizer maintains the trade-off matrix and surfaces:
- Dominant options (preferred or accepted by all, opposed by none)
- Irreducible trade-offs (positions where one stakeholder's prefer is another's oppose)

Convergence is the trade-off matrix being complete and stable, NOT all stakeholders agreeing.

## Stakeholder extraction

The moderator analyzes the challenge text to identify 2-4 candidate stakeholders, then asks the user to confirm/edit the list in the preflight gate. If the user can't name stakeholders, the question is probably not a deliberation — switch to `persuasion`.

## Walton type

Deliberation. See *The New Dialectic* (Walton 1998).
