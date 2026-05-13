# Stance tags (Inquiry preset)

Closed set: `{supports, refutes, lateral, inconclusive}`. All other values surface as `null` (format drift signal).

## Per-role mutex (enforced by role identity + system prompt)

| Role | Allowed stances | Why |
|---|---|---|
| verifier | `supports`, `inconclusive` | Verifier searches for supporting evidence; if absent, `inconclusive` is honest. Producing `refutes` means the role drifted into Falsifier's job. |
| falsifier | `refutes`, `inconclusive` | Symmetric to verifier. |
| triangulator | `lateral`, `inconclusive` | Triangulator looks for orthogonal evidence; if none surfaces, `inconclusive`. `supports`/`refutes` mean the role drifted to V/F. |
| wildcard | all 4 values | Wildcard may cross frames, including taking V/F/T's stance if the role surfaces evidence those scoped roles missed. |

## Moderator's reading

| Distribution | Reading |
|---|---|
| All `supports` (V) + `lateral`/`inconclusive` (others) | Hypothesis tentatively supported; check `source-kind` coherence (multiple `analogy` only = weak). |
| All `refutes` (F) + others quiet | Hypothesis falsified; F's `source-kind: counter-example` is strongest signal. |
| Mixed `supports` and `refutes` | Irreducible dispute — present both to user; do not synthesize. |
| All `inconclusive` | Insufficient evidence; suggest gathering more data before deciding. |
| ≥1 `null` stance | Format drift; apply format-correction (see SKILL.md §False-consensus guard, applies regardless of preset). |
