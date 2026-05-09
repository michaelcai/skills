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

The main agent assigns (Wildcard is mandatory; Role B is skipped because Role A's "broker reliability" angle covers the topic adequately):

| Role | Backend | Family | Identity |
|---|---|---|---|
| Defender | claude | anthropic | Defender of the Pub/Sub proposal |
| Role A (`role-a`) | opencode | openai | Engineer focused on message-broker reliability |
| Wildcard | opencode | openai | Free-form divergent thinker (NOT scoped to a specific angle) |

All three roles are spawned in parallel via agent-session's `spawn` verb (call shape: see [agent-session SKILL.md](../skills/agent-session/SKILL.md)). Each spawn carries its role-id, resolved backend, the role's first-turn prompt file, and a system prompt that includes the mandatory output format. Wall-clock ≈ slowest role's first-turn latency (~30s here, vs ~90s if sequential).

## Round 1 outputs

Defender's reply (retrieved via the `output` verb):

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

Role A's reply:

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

Wildcard's reply:

```
## TL;DR
The framing assumes Redis is the right transport at all. SSE/WebSocket directly from each pod
is cheaper, simpler, and side-steps the broker-reliability question entirely.
[stance: add]

## Argument
We're optimizing the wrong layer. Notifications are user-facing — they live and die at the WebSocket
session. Why route them through a pub/sub broker only to fan them back out to the same pod that
holds the user's connection?

Direct: each pod tracks its own connected users; cross-pod events go via a thin coordinator (or a
DB row's `pg_notify`, since we already have Postgres). Removes Redis from the notification path,
removes the entire "what if Redis loses messages" debate, and is fewer moving parts in production.
The Streams-vs-Pub/Sub argument is a lateral move within the wrong architecture.
```

**Moderator notes**: stances are all `add` (round 1 default). Defender argues "best-effort is OK for UX"; Role A argues "silent loss is unacceptable"; Wildcard reframes — "you don't need a broker at all". Wildcard's contribution is a *second-axis* signal — orthogonal to the focused critics, exactly the role's purpose. Push to round 2.

## Round 2

After round 1 finished, the moderator runs the **after-round step** (shell extracts each role's TL;DR straight to disk — these bytes never enter the moderator's assistant message):

```bash
mkdir -p $DEBATE_DIR/tldrs
for r in defender role-a wildcard; do
  agent-session output --role-id "$r" --state-dir "$SESSIONS_DIR" \
    | sed -n '/^## TL;DR/,/^## /{/^## [^T]/q;p}' > $DEBATE_DIR/tldrs/$r.md
done
```

Then the **pre-round step** assembles the shared `r2.md` from the on-disk TL;DRs (still no moderator-message bytes):

```bash
{
  echo "## Last round, other participants (TL;DR)"
  for r in defender role-a wildcard; do
    echo; echo "### $r"; cat $DEBATE_DIR/tldrs/$r.md
  done
  echo; echo "## Focus this round"
} > $DEBATE_DIR/r2.md
```

Now — and only now — the moderator appends a 4-line focus block. This is the **only** content from this round that lands in the moderator's own context:

```bash
cat >> $DEBATE_DIR/r2.md <<'EOF'
- **Defender**: Are there real-world UX scenarios where a dropped notification causes harm beyond "user reloads"? Be specific.
- **Role A**:   Defend the "Streams everywhere" claim against the cost objection (consumer-group ops, manual ack).
- **Wildcard**: Pick whichever divergent angle gives the most leverage.
EOF
```

Sent in parallel:

```bash
for r in defender role-a wildcard; do
  agent-session send --role-id "$r" --prompt-file $DEBATE_DIR/r2.md --state-dir $SESSIONS_DIR &
done
wait
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
