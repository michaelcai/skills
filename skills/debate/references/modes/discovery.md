---
preset: discovery
primitives:
  role-topology:
    roles: [explorer, compiler, wildcard]
    explorer-count: 3-4
    compiler-count: 1
    wildcard-count: 1
  tag-system:
    type: two-tag
    tags:
      stage:
        values: [propose, refine, settle]
        round-mutex:
          R1: [propose]
          R2-plus: [refine, settle]
      stance:
        values: [expand, challenge, connect, converge]
        per-role-mutex:
          explorer: [expand, connect, converge]
          wildcard: [expand, challenge, connect, converge]
          compiler: []
  checkpoint-policy:
    trigger: every-3-rounds
    display: [framing-matrix, missing-axes, irreducible-divergences, open-questions]
    forbidden-sections: [recommendation, best-option, ranking]
  output-format:
    file: ../output-format-discovery.md
---
