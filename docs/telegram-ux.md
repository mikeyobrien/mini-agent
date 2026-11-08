# Telegram UX plan

Grounded in `channels.d/telegram.lisp`, `channels.d/agent-responder.lisp`,
`channels.d/progress-notifier.lisp` and the bus topics they share
(`telegram/inbound|outbound|typing`, `agent/*`).

## Shipped (P0/P1)

1. **Ack on accept** -- `working: <task>` or `queued (n/3): <task>` within
   ~0.2s (consumers and the dispatcher wake on publish, not on a 2s poll).
2. **Typing indicator** -- `telegram/typing` every 4s while a task runs; the
   heartbeat is joined before the answer goes out.
3. **Threaded replies** -- answers carry `reply_to` the user's message.
4. **Plain-text errors** -- `⚠ agent error: ...`, no markup entities.
5. **4096 chunking** -- paragraph-boundary splits, `(i/n)` suffixes.
6. **Send fallback** -- one retry without `parse_mode`/`reply_to`, then the
   dispatcher's backoff; plain text by default.
7. **Progress pings** -- `… step N: cmd`, at most one per 45s per chat,
   never after the answer; chat comes from the run's `agent/step` payload.
8. **Answer only** -- the reply is `mini-agent:run`'s value, no step trace.

## P2 -- commandable bot (small parser in `handle`)

9. `/status` -- queue depth, worker busy, model name
   (all already in responder state).
10. `/cancel` -- set a cancel flag the worker checks between tasks;
   kills queued entries, flags the running one. (Interrupting mid-agent is
   P3: agent loop would need a check between steps in `src/agent.lisp`.)
11. `/memory` -- dump `state/<chat>.md` tail; `/forget` -- truncate it.
    Memory is currently opaque to the user who owns it.
12. Accept `/cmd@botname` suffix; ignore bare `/` unknown commands with a
    one-line hint instead of feeding them to the agent as tasks.

## P3 -- nicer output & group semantics

12. ~~**Tame the step trace.**~~ Done: the reply is `mini-agent:run`'s
    return value, the model's text alone; steps surface only as progress pings.
13. **editMessageText instead of message spam.** Send one `working…`
    placeholder, edit with progress, edit to final answer. Add an
    `telegram/edit` topic (same `api` helper) -- one message per task.
14. **Group memory scoping.** `state/<chat>.md` is communal in groups.
    Either document that, or key memory `chat_user` for group chats.
15. Non-text updates (photos/docs/edited) are silently dropped -- fine, but
    log them once at debug so silence is diagnosable.

## Verification

- `timeout 450 sbcl --script test/telegram-harness.lisp [scenario...]` boots
  the real eventd against a fake Bot API + LM and checks ack, typing start/stop,
  threaded answer, progress throttle, chunking, reply_to fallback, LM failure,
  queue acks and verbatim text; prints per-chat transcripts and UX timings
  (ack target <1s). `HARNESS_LIVE=1` swaps in the real LM from `.env.agent`.
- Still manual: `/status` `/cancel` `/memory` (P2, not built).
- No core edits required for P2: hooks are `eventbus:tail` consumers in
  `channels.d/`; `chanreg` re-registers channels and hooks by name, so
  hot-reload is drop-in.
