# AGENTS.md — mini-agent

## Language policy: Common Lisp. Full stop.

The runtime language of this project is **Common Lisp (SBCL)**. New logic goes in
`.lisp` files — agent, bus, daemon, tests. Do not reach for Python by default.

The single sanctioned exception:

- `agent-harbor.py` — foreign-interface glue for Harbor's `--agent-import-path`
  contract (harbor loads agents as Python classes; that is their plugin ABI, not
  our code). It must stay ~60 lines of shelling/IO only. **No agent logic, no
  parsing, no string processing of substance in it** — anything nontrivial
  belongs in `agent.lisp`.

Before writing any `.py` here, check this list. If your idea isn't one of
those two, it's a `.lisp` file.

## Verification ritual (the mistakes this file exists to prevent)

1. **Before claiming anything runs:** `sbcl --script run.lisp "<real task>"`.
   Load-time silence is not success — check for `[step N]` output or the final
   answer line.
2. **Before changing run/entry semantics:** remember `uiop:command-line-arguments`
   under `--script` EXCLUDES the script name (verified: `("echo a")` for
   `sbcl --script x.lisp "echo a"`). No stray `cdr`.
3. **quicklisp lives at `~/.quicklisp` on this host, `~/quicklisp` in containers**
   — any bootstrap must probe both (`eventbus.lisp`, `agent.lisp` already do).
4. **`SYSTEM.md` resolves cwd-first, then script dir** — tasks run from `/app`;
   never assume cwd == repo.
5. **Event bus is optional** — `eventbus.lisp` absent/failing must never fail the
   agent (`load-eventbus` is ignore-errors wrapped; keep it that way).
6. **Every repeat/verify loop gets `timeout <secs>`** — including sbcl invocations
   in tests; a hung sbcl is a hung CI.

## Repo hygiene

- `git status` clean before walking away. `jobs/`, `events.db*`, `__pycache__/`
  are ignored — never `git add` them explicitly.
- Commits: imperative, one concern. Push to `origin master` when green
  (`test/smoke.sh` + affected pieces).

## Where things live

| file | role |
|---|---|
| `agent.lisp` | the agent loop (bash tool, history, harbor-facing) |
| `eventbus.lisp` | sqlite pub/sub (`eventbus:publish/since`) |
| `eventd.lisp` | always-on bus daemon (stdin REPL + heartbeat) |
| `run.lisp` | entry; sets AUTORUN, loads agent, invokes main |
| `agent-harbor.py` | harbor glue ONLY (see above) |
| `test/smoke.sh` | bounded live smoke suite |
