---
preset: inquiry
primitives:
  role-topology:
    roles: [verifier, falsifier, triangulator, wildcard]
    role-b-conditional: false
  stance-contract:
    values: [supports, refutes, lateral, inconclusive]
    null-policy: format-correction-then-respawn
    per-role-mutex:
      verifier:     [supports, inconclusive]
      falsifier:    [refutes, inconclusive]
      triangulator: [lateral, inconclusive]
      wildcard:     [supports, refutes, lateral, inconclusive]
    distribution-interpretation:
      all-supports: convergence-on-truth
      all-refutes: hypothesis-falsified
      mixed-supports-refutes: irreducible-dispute
      all-inconclusive: insufficient-evidence
  checkpoint-policy:
    trigger: every-3-rounds
    display: [evidence-ledger, missing-evidence, irreducible-dispute, you-decide]
  output-format:
    file: ../output-format-inquiry.md
  source-kind-tag:
    values: [empirical, mechanism, analogy, theoretical, counter-example]
    cross-check: stance-vs-source-kind-coherence-heuristic
---
