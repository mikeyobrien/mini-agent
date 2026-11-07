# Telegram UX improvement plan

Grounded in `channels.d/telegram.lisp`, `channels.d/agent-responder.lisp`,
bus topics (`telegram/inbound|outbound`, `agent/*`). Ordered by user-visible
impact per unit of work. P0/P1 are small, local diffs; P2/P3 slightly larger.

## P0 -- feel alive (silence is the #1 UX bug)

1. **Ack on accept.** `spawn-task` succeeds silently when queue is empty;
   user stares at nothing for up to 240s (`*wall-clock*`). Reply
   `â½ working: <task, truncated 60>` on *every* accept, not only when queued
   behind. One line in `queue-push`/`spawn-task`.
2. **Typing indicator.** `sendChatAction {chat_id, chat_action:"typing"}`
   lasts ~5s. Worker loop already wakes every second -- emit action when
   `queue-pop` returns a job, and re-emit on a 4s heartbeat while it runs.
   New tiny helper in telegram.lisp next to `api`.
3. **Thread replies.** Inbound already captures `message_id` but `reply`
   never sets `reply_to_message_id` -- answers float unlinked in groups.
   Add `reply_to` passthrough in `outbound-dispatch` + set it in `reply`.
4. **Fix warning markup.** Error path sends `"&#9888; ~a"` while
   `parse_mode` is Markdown -> literal `&#9888;` in chat. Use `â ` or an
   HTML `parse_mode` consistently (see P1 #6).

## P1 -- visible-surface reliability

5. **4096 chunking.** Telegram rejects longer texts; agent answers are
   unbounded. Split on paragraph/blank-line boundaries in
   `outbound-dispatch`, send sequentially, suffix `(2/3)`.
6. **Markdown fallback.** Bad markdown -> API error -> eventd retry loop ->
   duplicate-looking silence. Try `parse_mode:Markdown`, on failure resend
   plain. Do it once inside the sendMessage branch; benefits all senders.
7. **Progress pings from agent telemetry.** `agent/step` events already
   flow to the bus for free. New `channels.d/progress-notifier.lisp` boot
   hook: subscribe, throttle to one `â¦step N: $cmd` ping per 45s per chat.
   Zero responder changes; delete the file to turn off.

## P2 -- commandable bot (small parser in `handle`)

8. `/status` -- queue depth, worker alive, current task age, model name
   (all already in responder state).
9. `/cancel` -- set a cancel flag the worker checks between tasks;
   kills queued entries, flags the running one. (Interrupting mid-agent is
   P3: agent loop would need a check between steps in `src/agent.lisp`.)
10. `/memory` -- dump `state/<chat>.md` tail; `/forget` -- truncate it.
    Memory is currently opaque to the user who owns it.
11. Accept `/cmd@botname` suffix; ignore bare `/` unknown commands with a
    one-line hint instead of feeding them to the agent as tasks.

## P3 -- nicer output & group semantics

12. **Tame the step trace.** `run-agent` keeps `[step N] $ cmd` lines
    (strips only leading loader noise). Render them as italic/mono preamble
    or drop by default, answer first.
13. **editMessageText instead of message spam.** Send one `workingâ¦`
    placeholder, edit with progress, edit to final answer. Add an
    `telegram/edit` topic (same `api` helper) -- one message per task.
14. **Group memory scoping.** `state/<chat>.md` is communal in groups.
    Either document that, or key memory `chat_user` for group chats.
15. Non-text updates (photos/docs/edited) are silently dropped -- fine, but
    log them once at debug so silence is diagnosable.

## Verification

- `test/` smoke path for daemon boot; then live: text -> ack <1s, typing
  during run, threaded answer; 5k-char answer arrives as chunks; kill
  markdown in a reply to see fallback; `/status` `/cancel` `/memory`.
- No core edits required for P0-P2: telegram.lisp + agent-responder.lisp
  (+ one new optional hook file). `chanreg` re-registers by name, so
  hot-reload is drop-in.
