# mini-agent

A bare-minimum coding agent in ~270 lines of Common Lisp. One tool (`bash`),
one loop. Your intelligence does the work; the harness only moves bytes.

```
query LM ──▶ tool_calls? ──yes──▶ run bash ──▶ append result ──┐
   ▲                                                           │
   └───────────────────────────────────────────────────────────┘
   no ──▶ print answer, done
```

Lineage: inspired by [mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent)
(one tool, stateless subshells, errors-as-messages) and
[minimal-agent.com](https://minimal-agent.com)'s minimalism — reimplemented
from scratch in SBCL.

## Requirements

- [SBCL](https://www.sbcl.org/) (tested on 2.6.x, arm64 + x86-64)
- `curl` on PATH
- [QuickLisp](https://quicklisp.org) at `~/.quicklisp` — `agent.lisp` loads it
  automatically and installs [`com.inuoe.jzon`](https://github.com/ruricolist/inuoe.jzon)
  on first run

## Setup

```bash
brew install sbcl            # or your package manager
curl -O https://beta.quicklisp.org/quicklisp.lisp
sbcl --load quicklisp.lisp --eval '(quicklisp-quickstart:install)'
```

Configure (see [`.env.example`](.env.example) for the full set):

```bash
export MINI_AGENT_BASE_URL=http://my-server:8000/v1   # OpenAI-compatible
export MINI_AGENT_MODEL=my-model                       # exactly as /models reports
```

## Usage

```bash
sbcl --script src/run.lisp "fix the failing test in foo.py"
sbcl --script src/run.lisp            # prompts for the task
```

Watch it work:

```
[step 1] $ cd app && pytest -x -q
...tool output...
[step 2] $ ...
Final answer text from the model.
```

Programmatic:

```lisp
(load "src/agent.lisp")            ; after loading ~/quicklisp/setup.lisp
(setf *base-url* ...  *model* ...)  ; or rely on env
(mini-agent::run "refactor the parser")
```

## Configuration

Everything is env-driven (12-factor); no endpoints or model names are baked in.

| Variable | Default | Meaning |
|---|---|---|
| `MINI_AGENT_BASE_URL` | *(required)* | OpenAI-compatible base, e.g. `http://host:8000/v1` |
| `MINI_AGENT_MODEL` | *(required)* | model id as `GET /base/models` reports it |
| `MINI_AGENT_MAX_STEPS` | `0` | loop cap; `0` = unlimited (mini-swe style) |
| `MINI_AGENT_TIMEOUT` | `120` | seconds per `bash` call (`uiop:run-program :timeout`) |
| `MINI_AGENT_HTTP_TIMEOUT` | `300` | seconds per LM request (`curl --max-time`) |
| `MINI_AGENT_MAX_OUTPUT` | `20000` | tool-result chars before truncation |
| `MINI_AGENT_TRUNC_HEAD` | `10000` | head kept on truncation |
| `MINI_AGENT_TRUNC_TAIL` | `10000` | tail kept on truncation |
| `MINI_AGENT_THINKING` | `enabled` | `off` \| `enabled` (budget 16384) \| `enabled:N` |
| `MINI_AGENT_SYSTEM_MD` | `SYSTEM.md` | system-prompt path, resolved against cwd |
| `MINI_AGENT_AUTORUN` | unset | set to run `main` at load (script wrappers) |
| `MINI_AGENT_SKILLS_PATH` | *(empty)* | extra skill roots, `:`-separated, searched before `skills/` (e.g. `~/.agents/skills`) |

Truncation keeps head + tail with a `...N chars elided...` marker —
[mini-swe-agent's observation template](https://github.com/SWE-agent/mini-swe-agent/blob/main/src/minisweagent/config/mini.yaml).
Looser caps resolve more at flat cost; tune `MAX_OUTPUT` up for big-build repos.

## Skills

A skill is `<root>/<name>/SKILL.md` with `name` / `description` frontmatter,
the same layout Claude Code, Codex and Pi use. Each run lists every
discovered skill (name, description, absolute path) at the end of the
system prompt. The model `cat`s a SKILL.md when a task matches it, so skills
need no extra tool. Roots: `MINI_AGENT_SKILLS_PATH` first, then the repo's
`skills/`; the first skill found under a name wins. Shipped: `skills/rex`
(drives the Rex terminal through `rex skill show`).

## Repository layout

```
src/    agent.lisp eventbus.lisp eventd.lisp chanreg.lisp run.lisp agent-harbor.py
channels.d/ telegram.lisp agent-responder.lisp echo-responder.lisp progress-notifier.lisp
skills/ <name>/SKILL.md — progressive-disclosure instructions
test/   smoke.sh eventbus-test.lisp skills-test.lisp dispatch-test.lisp
        agent-test.lisp telegram-harness.lisp
eval/   o11y-report.lisp
docs/   reference.md operations.md telegram-ux.md
``` 
(one file per concern; `run.lisp`/adapters always resolved relative to their own location)

## Architecture

One file, `agent.lisp` (~270 lines):

| Section | Lines | Notes |
|---|---|---|
| Config | ~35 | env readers; fails loud if `BASE_URL`/`MODEL` unset |
| Request builder | ~40 | `dict` helper → hash-tables → `jzon:stringify`; thinking kwargs spliced when enabled |
| HTTP | ~20 | `curl` subprocess; body via temp file; non-200 raises with body excerpt |
| Agent loop | ~45 | history = plain alists; assistant turns re-encoded canonically; errors appended as tool messages |
| `run` | — | the loop; returns on first no-tool-call reply |

Design rules, enforced by [`SYSTEM.md`](SYSTEM.md) (the model-facing contract):

1. **Stateless shell** — every action is a fresh `bash -c`; prefix `cd`/env inline.
2. **One action per step, composed** — `&&` chains, not round-trips.
3. **Read before write** — no blind edits.
4. **Verify your work** — an unverified claim is unfinished.
5. **Output discipline** — quiet commands; >20k-char outputs truncated head+tail.

JSON is [`com.inuoe.jzon`](https://github.com/stylewarning/com.inuoe.jzon) —
the only library dependency. Everything else is the standard library plus
UIOP (bundled with SBCL).

### The one Python file

`agent-harbor.py` is **foreign-interface glue only**: Harbor loads benchmark
agents as Python classes (`--agent-import-path module:Class`), so ~60 lines of
IO shim (install sbcl/quicklisp in the container, upload the repo, exec
`sbcl --script run.lisp "<task>"`) are required to enter that contract. All
agent logic lives in `agent.lisp`; the adapter must never grow parsing, string
processing, or behavior. See `AGENTS.md` for the language policy.

## Terminal-Bench (harbor)

Smoke-verified against [terminal-bench 2.1](https://github.com/harbor-framework/terminal-bench-2-1)
via [harbor](https://github.com/harbor-framework/terminal-bench) with the
bundled adapter (3/3 on the smoke subset, 1 attempt each, real endpoint):

```bash
docker run -d -p 2375:2375 ...   # or start Docker Desktop; harbor needs it
uv tool install harbor
git clone --depth 1 https://github.com/harbor-framework/terminal-bench-2-1

MINI_AGENT_BASE_URL=http://host:PORT/v1 MINI_AGENT_MODEL=<id> \
PYTHONPATH=. harbor run \
  -p terminal-bench-2-1/tasks/fix-git \
  -a agent-harbor:MiniAgentAgent -k 1 -n 1
```

Per-trial verdicts land in `jobs/<ts>/<task>__<id>/verifier/reward.txt`
(`1` = resolved). Treat small-n runs as smoke, not scores.

## Extensions left as exercises

- `git diff` extraction for SWE-bench-style patch capture
- cost accounting from `usage` in responses (a la mini-swe `cost_limit`)
- history compaction for very long runs
- multi-tool support (the `tools` array is already a list)

## License

MIT
