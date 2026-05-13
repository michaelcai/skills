# Output format (Inquiry preset)

Every role's reply MUST be exactly two H2 sections, in this order:

## TL;DR
(2-3 sentences from your investigative role's perspective — what evidence you found and what it implies)
[stance: supports|refutes|lateral|inconclusive]
[source-kind: empirical|mechanism|analogy|theoretical|counter-example]

## Argument
(150-300 words. Cite specific evidence, mechanism, or counter-example. Show the chain from your evidence to your stance.)

## Stance vocabulary

| stance | semantics |
|---|---|
| `supports` | Your evidence supports the hypothesis under your investigative angle. |
| `refutes` | Your evidence refutes the hypothesis under your investigative angle. |
| `lateral` | Your evidence is orthogonal — neither supports nor refutes directly, but introduces an adjacent consideration. |
| `inconclusive` | Your investigation found insufficient signal in either direction. |

## Source-kind vocabulary

| source-kind | semantics |
|---|---|
| `empirical` | Direct measurement / observation / production data. |
| `mechanism` | Reasoning from how the system actually works internally. |
| `analogy` | Comparison with a similar/adjacent system that has played out. |
| `theoretical` | Derivation from accepted theory or formal result. |
| `counter-example` | A specific case that contradicts a general claim. |

## Hard rules

1. Both `[stance:]` and `[source-kind:]` lines MUST appear inside the TL;DR block, after the prose sentences.
2. `stance` value MUST be from your role's mutex (see `references/modes/inquiry.md`). Cross-role drift (e.g., Verifier producing `refutes`) is a format violation.
3. `source-kind` MUST be from the vocabulary. `stance: supports` + `source-kind: counter-example` is logically inconsistent — moderator may flag.
4. Speak in the first-person voice of your investigative role; do not break frame to evaluate other roles' outputs directly.
