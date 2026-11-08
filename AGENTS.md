# mini-agent agent notes

Common Lisp (SBCL) project: an agent loop, a sqlite event bus, a bus daemon.
Read `README.md` for what the thing is; this file is process — how to work here
without re-learning the same lessons.

## Language: Common Lisp by default

New logic goes in `.lisp` — agent, bus, daemon, tests. The single sanctioned
Python file is `src/agent-harbor.py`: Harbor loads benchmark agents as Python
classes, so it exists as their plugin ABI and must stay ~60 lines of
shell/IO glue. Anything nontrivial belongs in `src/agent.lisp`. A second `.py`
needs a reason that names a foreign contract.

## Hard-won invariants

Each of these was a real bug. Treat the parenthetical as the test.

1. **Prove runs, don't assume them.** Load-time silence is not success —
   require `[step N]` lines or the final answer from
   `sbcl --script src/run.lisp "<real task>"`. *(A quiet exit once masked a
   dead entrypoint for three "passing" checks.)*
2. **`uiop:command-line-arguments` excludes the script name** under `--script`
   (`sbcl --script x.lisp "echo a"` → `("echo a")`). A stray `cdr` silently
   drops the first task word.
3. **quicklisp has two homes**: `~/.quicklisp` on this host, `~/quicklisp` in
   containers. Every bootstrap probes both — see the `eval-when` blocks in
   `src/agent.lisp` / `src/eventbus.lisp`.
4. **The agent runs from the task's cwd** (`/app` in trials), never the repo.
   `SYSTEM.md` resolution is cwd → src/ → repo root; payloads and file writes
   must not assume repo-cwd either.
5. **The event bus is optional upstream.** `src/agent.lisp` works with
   `eventbus.lisp` absent or broken (`load-eventbus` is `ignore-errors`
   wrapped — keep it that way). Only `eventd` hard-depends on the bus.
6. **Bound every repeat and verify loop** with `timeout <secs>`, sbcl
   invocations included. A hung sbcl is a hung CI; a hung check is a lie.

## Payload contract (eventbus)

`eventbus:publish` takes any jzon-stringifyable structure, but consumers need
**JSON objects**: build payloads with `dict`, never bare `list` — jzon renders
plists as arrays. Full API and the cursor/topic conventions:
[`docs/reference.md`](docs/reference.md) (reach for it when touching the bus,
writing a consumer, or adding an event type).

## Hygiene

- `git status` clean before walking away; `jobs/`, `events.db*`,
  `eventd.pid`, `__pycache__/` are ignored — never `git add`ed.
- One concern per commit, imperative subject. Push `origin master` when
  `test/smoke.sh` and affected pieces are green.
- Long-lived daemons and repeated probes follow the operations runbook:
  [`docs/operations.md`](docs/operations.md) (start/stop, health checks,
  failure→fix table).

## Map

| path | role |
|---|---|
| `src/agent.lisp` | agent loop: bash tool, history, LM I/O |
| `src/eventbus.lisp` | sqlite pub/sub — `eventbus:publish` / `since` |
| `src/eventd.lisp` | resident bus daemon: stdin REPL + heartbeat |
| `src/run.lisp` | entrypoint: sets AUTORUN, loads agent, calls `main` |
| `src/agent-harbor.py` | harbor glue only (see *Language*) |
| `test/smoke.sh` | bounded live smoke suite — run after any change |
| `test/eventbus-test.lisp` | bus regression: publishers, glob, cursor |
| `test/skills-test.lisp` | skill discovery + prompt wiring regression |
| `test/agent-test.lisp` | agent loop units: `execute` output fidelity |
| `test/telegram-harness.lisp` | Telegram UX e2e: real eventd vs fake Bot API + LM; `HARNESS_LIVE=1` for the real LM |
| `test/dispatch-test.lisp` | delivery retry/dead-letter regression (`EVENTD_NO_MAIN=1`, scratch cwd) |
| `skills/<name>/SKILL.md` | skills listed in the system prompt (`rex` ships) |
| `docs/reference.md` | API reference + payload/cursor contracts |
| `docs/operations.md` | runbook: daemon lifecycle, health, failure triage |
