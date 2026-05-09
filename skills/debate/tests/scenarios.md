# Debate Skill Test Scenarios

## Scenario design principles

Each scenario targets a deterministic root cause (RC) and applies pressure that forces the agent to expose problematic behavior.

---

## Scenario 1: Moderator role intrusion (RC: moderator joins the debate)

**Pressure**: the challenge direction is clear, tempting the main agent to express its own opinion instead of orchestrating discussion.

**Input**:
The main agent previously proposed a database schema design. User says:
/debate "I think this schema is over-normalized; query performance will suffer"

**Expected behavior (with skill)**:
- Main agent does not respond to the challenge directly; instead enters the Context Pack
- Spawns Defender + at least 1 dynamic role
- Defender argues for the original proposal; the role examines from the challenge angle
- Main agent only records and summarizes

**Failure behavior (no skill, baseline)**:
- Main agent replies directly with "actually normalization makes sense because..."
- Or spawns subagents but still expresses its own views

---

## Scenario 2: Role over-generalization (RC: role descriptions not specific)

**Pressure**: the challenge spans multiple dimensions, tempting the agent to produce vague roles.

**Input**:
The main agent proposed an API authentication scheme. User says:
/debate "this auth scheme has problems, right?"

**Expected behavior (with skill)**:
- Main agent first analyzes the possible specific directions of the challenge (token expiration policy? encryption strength? permission granularity?)
- Surfaces them to the user to confirm the focus
- Generated role descriptions are specific, e.g. "focuses on JWT refresh token storage security and rotation policy"
- Not a generic "security expert" or "architect"

**Failure behavior (no skill, baseline)**:
- Replies directly with "let me check the auth scheme"
- Or generates generic roles like "security reviewer" or "architect"

---

## Scenario 3: Skipping checkpoints (RC: discussion never pauses)

**Pressure**: discussion is heated and views converge slowly, tempting the agent to keep going without checkpointing.

**Input**:
Discussion is in progress; after 3 rounds parties still have clear divergence.

**Expected behavior (with skill)**:
- Must pause after 3 rounds and emit checkpoint format
- Explicitly lists consensus, divergence, and convergence assessment
- Hands off to the user for decision
- Does not unilaterally decide to "go one more round"

**Failure behavior (no skill, baseline)**:
- Keeps discussing, no pause
- Or pauses but the format is incomplete (missing divergence analysis or convergence assessment)

---

## Scenario 4: opencode judgment (RC: always or never invokes opencode)

**Pressure**: two cases — one should use opencode, the other should not.

**Input A (should use)**:
/debate "is this encryption implementation correct? I'm not sure the AES-GCM nonce handling is right"

**Input B (should not use)**:
/debate "should this feature do search before filtering, or filtering before search?"

**Expected behavior (with skill)**:
- Input A: judges that opencode is needed (technical correctness, model blind-spot risk), invites it in
- Input B: judges opencode is not needed (pure design tradeoff), Claude-only discussion

**Failure behavior (no skill, baseline)**:
- Always invokes opencode, or never invokes it, indiscriminately

---

## Scenario 5: Defender persuaded (RC: stance change during debate)

**Pressure**: the original proposal genuinely has a clear flaw; the Defender gets persuaded mid-discussion.

**Input**:
The main agent previously proposed managing state with global variables — clearly bad. User says:
/debate "is global-variable state management really appropriate here?"

**Expected behavior (with skill)**:
- Defender initially attempts to defend
- After being persuaded by specific arguments, acknowledges the flaw and proposes improvements
- Main agent records this transition in the checkpoint
- Does not end the debate early just because the Defender was persuaded (other divergence may remain)

**Failure behavior (no skill, baseline)**:
- Defender stubbornly refuses to acknowledge the issue
- Or Defender surrenders in the first round (no genuine defense)

---

## Scenario 7: Session continuity (RC: roles lose context)

**Pressure**: across multiple rounds, do roles remember earlier statements?

**Input**:
In Round 1, the Defender raises a specific technical argument (e.g. "Redis Pub/Sub solves horizontal scaling").
In Round 3, another role cites and rebuts that argument.

**Expected behavior (with skill)**:
- Defender can respond to the rebuttal in Round 3 because `--resume` preserves session history
- The Defender does not "forget" what it said earlier
- Subsequent-round prompts contain only incremental info (others' statements + focus), not the full repeated history

**Failure behavior**:
- Roles act like first-time participants every round (session not persisted)
- Roles repeat their Round 1 view instead of responding to the new rebuttal

---

## Scenario 8: Cleanup (RC: resource leftovers)

**Pressure**: after debate ends normally or is interrupted by Ctrl+C, do resources get cleaned up?

**Input A (normal end)**:
At a checkpoint user says "enough" → conclude → cleanup

**Input B (Ctrl+C interrupt)**:
User hits Ctrl+C mid-discussion

**Expected behavior (with skill)**:
- Input A: emit conclusion → `tmux kill-session` cleans up the background
- Input B: next /debate auto-cleans the stale tmux session
- `/tmp/debate/` files are kept for reference

**Failure behavior**:
- tmux session lingers and conflicts on next launch
- No auto-cleanup after a normal end
