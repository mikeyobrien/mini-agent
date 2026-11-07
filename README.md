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
sbcl --script run.lisp "fix the failing test in foo.py"
sbcl --script run.lisp                # prompts for the task
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
(load "agent.lisp")                 ; after loading ~/quicklisp/setup.lisp
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

Truncation keeps head + tail with a `...N chars elided...` marker —
[mini-swe-agent's observation template](https://github.com/SWE-agent/mini-swe-agent/blob/main/src/minisweagent/config/mini.yaml).
Looser caps resolve more at flat cost; tune `MAX_OUTPUT` up for big-build repos.

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

## Extensions left as exercises

- `git diff` extraction for SWE-bench-style patch capture
- cost accounting from `usage` in responses (a la mini-swe `cost_limit`)
- history compaction for very long runs
- multi-tool support (the `tools` array is already a list)

## License

MIT
