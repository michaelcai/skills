# Sample debate session

> **This is an illustrative transcript** showing what a real `/debate` invocation produces. It shows the structure, the prompt files, the assistant outputs, and the moderator's reasoning. Wording is hand-crafted for clarity — actual outputs from running `/debate` on your codebase will follow this exact format.

## Setup

**Original proposal** (came up in a prior conversation):

> Use Redis Pub/Sub to broadcast notification events across multiple service instances.

**User's challenge** (typed `/debate "what happens to lost messages during horizontal scaling?"`):

> What happens to lost messages during horizontal scaling?

**Project context**: Python 3.12, FastAPI, redis-py 5.x, deployed on GKE.

## Step 2: Plan & spawn

`agent-session doctor` reports `claude` and `opencode` available — multi-model ✓.

The main agent assigns:

| Role | Backend | Family | Identity |
|---|---|---|---|
| Defender | claude | anthropic | Defender of the Pub/Sub proposal |
| Role A (`role-a`) | opencode | openai | Engineer focused on message-broker reliability |

Spawned via:

```bash
DEBATE_DIR=/tmp/debate-a3f7
SESSIONS_DIR=$DEBATE_DIR/sessions
# (shared-context.md and per-role .md files written here — see SKILL.md §2.4)

agent-session spawn --backend claude --role-id defender \
  --prompt-file $DEBATE_DIR/defender-r1-full.md \
  --state-dir $SESSIONS_DIR \
  --system-prompt "You are the Defender. ..."

agent-session spawn --backend opencode --role-id role-a \
  --prompt-file $DEBATE_DIR/role-a-r1-full.md \
  --state-dir $SESSIONS_DIR \
  --system-prompt "You are an engineer focused on broker reliability. ..."
```

## Round 1 outputs

`agent-session output --role-id defender --state-dir $SESSIONS_DIR`:

```
## TL;DR
Pub/Sub is the right call here — notifications are best-effort UX hints, not financial events.
The horizontal-scaling concern is overstated in modern k8s deployments.
[stance: add]

## Argument
The proposal targets notifications, not durable state. A dropped "you have a new comment" toast
is recoverable — the user sees it next time they open the page. Trading complexity (consumer
groups, manual ack, backlog pruning) for at-least-once on a UX-tier signal is over-engineering.

For the rolling-update window specifically: PreStop hooks + a 5s drain delay let the old pod
finish in-flight publishes. The remaining gap is bounded to seconds, and the next push (e.g.
the user opening the app) refreshes any state. Streams becomes the right answer the moment
there's a downstream consumer that *can't* tolerate gaps — but we don't have that consumer.
```

`agent-session output --role-id role-a --state-dir $SESSIONS_DIR`:

```
## TL;DR
Redis Pub/Sub does not guarantee message delivery; during horizontal scaling, losing a
subscriber silently drops notifications. We should switch to Streams + consumer group.
[stance: add]

## Argument
Look at `src/notify/redis_bus.py:42` — it uses the `PUBLISH` command, so any messages sent
while a subscriber is offline are simply discarded. During a k8s rolling restart, the old pod
has been SIGTERM'd before the new pod comes up, and every notification emitted in that window
is lost.

Redis Streams with a consumer group gives us at-least-once: when an offline pod reconnects,
it can pull the backlog via `XREADGROUP`. The cost is manual ack and a step up in complexity.
But compared with silent message loss — where the user has no idea what happened — it's worth
that cost.
```

**Moderator notes**: both stances are `add` (round 1 default). Disagreement is real: Defender argues "best-effort is OK for UX"; Role A argues "silent loss is unacceptable". Need to push to round 2.

## Round 2

Moderator constructs incremental prompts (other role's TL;DR + this round's focus):

`$DEBATE_DIR/defender-r2.md`:

```markdown
## Last round, other participants (TL;DR)
### Role A
Redis Pub/Sub does not guarantee delivery; horizontal scaling silently drops notifications.
We should switch to Streams + consumer group.

## Focus this round
Are there real-world UX scenarios where a dropped notification causes harm beyond "user reloads"? Be specific.
```

Sent via:

```bash
agent-session send --role-id defender --prompt-file $DEBATE_DIR/defender-r2.md \
  --state-dir $SESSIONS_DIR
```

Defender round-2 output:

```
## TL;DR
Conceded — there's at least one harmful scenario: action confirmations after slow async work.
For those, switching to Streams is justified.
[stance: concede]

## Argument
The case I missed: when a user submits a long-running async job and gets the confirmation
notification 30 seconds later. If their pod just rolled, the toast never arrives — and unlike
"new comment", the user has no obvious way to "refresh" to recover. They'll either re-submit
(creating duplicate work) or assume failure (creating support tickets).

Counter-proposal: Streams only for the action-confirmation channel; Pub/Sub stays for the
"social/feed" notifications where the user reload semantic actually works. This gives
at-least-once where it matters and avoids the operational complexity of consumer groups
on every event type.
```

Role A round-2 output:

```
## TL;DR
Defender's "PreStop hook" claim is wrong — k8s only delays SIGTERM, not the network deletion
that severs the subscriber connection. Pub/Sub is unsafe for any notification, not just
confirmations.
[stance: hold]

## Argument
The 5s preStop drain window doesn't help: when k8s removes the pod from the Service endpoints,
the subscriber's TCP connection to Redis is severed *before* preStop runs in some configurations
(see kubernetes/kubernetes#106554). Even with preStop, the subscriber must re-register on the
new pod, and any message published in the gap is gone.

The "user can refresh" argument also fails for push-only channels — mobile apps rely on the
notification arriving; there's no manual refresh path. Streams everywhere is the safe choice.
```

## Checkpoint (after round 2 = first checkpoint)

```markdown
## Discussion progress (rounds 1–2)

### Consensus
- Pub/Sub is unsafe for action-confirmation notifications (Defender conceded)

### Divergence
- Defender: hybrid (Streams for confirmations, Pub/Sub for social) — practical compromise
- Role A: Streams everywhere — Pub/Sub is fundamentally unsafe even with preStop hooks

### Moderator judgment
- Convergence level: Medium (1 concede + 1 hold = partial agreement)
- The preStop claim contradicts; needs verification before deciding "Streams only for confirmations"
- Recommend: continue 1 more round focused on whether preStop genuinely closes the gap

### You decide
- Continue (1 round on preStop verification)?
- Or accept hybrid as good-enough?
- Or accept Role A's "Streams everywhere"?
```

User says: "continue, focus on preStop".

## Round 3 + conclusion

(Round 3 omitted for brevity — the focus would be: who's right about preStop. After round 3, the moderator concludes.)

## Conclusion

```markdown
## Conclusion

### Original proposal
Redis Pub/Sub for cross-instance notifications.

### Final recommendation
Hybrid: Redis Streams + consumer groups for **action-confirmation** notifications;
Pub/Sub for **social/feed** notifications where user-side reload recovers state.

### Key arguments
- Defender: Pub/Sub fits UX-tier best-effort signals; Streams is over-engineering for
  recoverable events. Conceded that confirmations are not recoverable.
- Role A: Pub/Sub is unsafe in horizontal scaling regardless of preStop. Streams should
  be the default for any push channel where the user has no manual recovery path.

### Unresolved divergence
- Whether to immediately migrate the social channel to Streams. Defer until measurable
  delivery loss is observed in production.
```

## Cleanup

```bash
for r in defender role-a; do
  agent-session cleanup --role-id "$r" --state-dir "$SESSIONS_DIR"
done
rm -rf "$DEBATE_DIR"
```

---

## What this example illustrates

1. **Multi-model discipline**: Defender (claude/anthropic) + Role A (opencode/openai) = ≥2 families. Single-family debates are rejected by `agent-session doctor`.
2. **Stance tags expose the dialogue shape**: round 1 `add`/`add` (no engagement yet), round 2 `concede`/`hold` (partial convergence — the strongest signal of a real-progress debate).
3. **TL;DR + Argument split** keeps the moderator's read cost low: in normal flow only TL;DRs are read; full Arguments are pulled only at checkpoint or on user request.
4. **Sessions persist**: round 2 prompts contain only the *delta* (other role's TL;DR + new focus). Each role's full history is held by `agent-session` in their own session.
