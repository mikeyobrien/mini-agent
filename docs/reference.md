# API Reference

Internal reference for mini-agent's Common Lisp surface. Anything not listed
here is an implementation detail; rely only on exported/known names below.

Packages: `mini-agent`, `eventbus`, `eventd` — none re-export each other.

---

## mini-agent (agent.lisp)

### Entry

#### `main` — function `()`
Validates `MINI_AGENT_BASE_URL`/`MINI_AGENT_MODEL` (errors loudly with an
example if unset), reads the task from `uiop:command-line-arguments` (falls
back to a `task:` prompt on stdin), runs it, quits via `(uiop:quit 0)`.
Invoked automatically at load when `MINI_AGENT_AUTORUN` is set — which
`run.lisp` always sets.

#### `run (task)` — function
The loop. Returns after the first assistant turn with no tool calls (prints
the answer), or exhaustes `*max-steps*` when it's nonzero. Side effects:
- emits `agent/start`, `agent/step`, `agent/done` via `emit` when the eventbus loaded
- appends tool results to history as `(:role . "tool")` entries

### Configuration (special variables, all env-driven)

| variable | env | default |
|---|---|---|
| `*base-url*` | `MINI_AGENT_BASE_URL` | nil (required) |
| `*model*` | `MINI_AGENT_MODEL` | nil (required) |
| `*max-steps*` | `MINI_AGENT_MAX_STEPS` | 0 (unlimited) |
| `*step-timeout*` | `MINI_AGENT_TIMEOUT` | 120 s per bash call |
| `*http-timeout*` | `MINI_AGENT_HTTP_TIMEOUT` | 300 s per LM call |
| `*max-output*` | `MINI_AGENT_MAX_OUTPUT` | 20000 chars |
| `*trunc-head*` / `*trunc-tail*` | `..._TRUNC_HEAD/TAIL` | 10000 / 10000 |
| `*thinking*` | `MINI_AGENT_THINKING` | `enabled` |
| `*system-prompt-path*` | `MINI_AGENT_SYSTEM_MD` | `SYSTEM.md` |
| `*skills-path*` | `MINI_AGENT_SKILLS_PATH` | empty (repo `skills/` only) |

`*thinking*` accepts `off`/`false`/empty (disabled), `enabled` (budget 16384),
`enabled:N` (budget N), or a raw JSON snippet spliced into
`chat_template_kwargs`.

### Events

#### `emit (event payload)` — function
Publishes to topic `agent/<event>` when the eventbus loaded; `ignore-errors`
wrapped — telemetry failures never fail a run. Payloads are JSON objects
(`dict`), e.g. `agent/step` → `{"step":N,"command":"..."}`.

#### `load-eventbus` — function `()`
Loads sibling `eventbus.lisp` if present, sets `*eventbus*`, calls
`eventbus:ensure-schema`. Fully optional; silent no-op otherwise.

### Skills

- `discover-skills ()` — `(name description path)` for each `<root>/<dir>/SKILL.md`
  across `skill-roots` (env roots, then `<repo>/skills/`), dirs sorted, first
  name wins; skills without `name` or `description` are skipped.
- `parse-frontmatter (text)` — top-level `key: value` alist; quoted scalars,
  `>`/`|` blocks; nested maps ignored.
- `skills-prompt (skills)` — the `## Skills` section; `run` binds it to
  `*skills-section*` once per run and `build-request` appends it to SYSTEM.md.
- Regression: `timeout 60 sbcl --script test/skills-test.lisp`.

### Internals worth knowing

- `build-request (history)` — history is a list of plists
  `((:role . "...") (:content . ...) (:tool-calls . json-or-nil))`; system
  prompt prepended; `chat_template_kwargs` spliced before the brace when
  thinking enabled.
- `query-lm (history)` — POSTs, parses, returns the `message` object
  (hash-table). Guards nil/empty choices.
- `execute (cmd)` — `bash -c` via `uiop:run-program`, stdout+stderr merged,
  `:timeout *step-timeout*`, head+tail truncation. Errors become
  `"Error: ..."` strings (fed back to the model, never raised).
- `canonical-tool-calls (msg)` — vector/`:null`-safe filter; returns
  `(:id ... :type "function" :function (:name ... :arguments ...))` plists
  or nil.
- `dict (&rest kvs)` — builds an equal hash-table; symbol keys are downcased
  without the colon (jzon renders hash-tables as JSON objects).

---

## eventbus (eventbus.lisp)

The bus is the schema; any sqlite client in any language may participate.

Schema: `events(id INTEGER PRIMARY KEY, ts TEXT DEFAULT datetime('now'), topic TEXT NOT NULL, payload TEXT /*JSON*/)`.

#### `ensure-schema` — function `()`
Idempotent `CREATE TABLE`/`INDEX`.

#### `publish (topic payload)` — function → id
`payload` is any jzon-stringifyable structure. Returns the rowid — that id is
the cursor contract.

#### `since (last-id &optional topic-glob)` — function → list
Rows with `id > last-id`, optional `SQL GLOB` on topic (`agents/*`), oldest
first, cap 500. Each entry: `(:id :ts :topic :data)` with `data` parsed from
JSON. `:null` payloads parse to the keyword `:null` — handle it.

Connection per call; `busy_timeout=5000` and WAL set on every connection.
Single-writer semantics: serialize writes or accept SQLite's busy-retry.

---

## eventd (eventd.lisp)

Long-lived daemon; run detached, it writes `eventd.pid` next to itself.

- **stdin protocol**: lines `"<topic> <json>"` → publish, prints `ok`;
  `since <id> [glob]` → dumps matching events, one JSON object per line.
- **heartbeat**: publishes `eventd/beat {"ts":...}` every
  `EVENTD_BEAT_SECONDS` (default 30). Liveness only — never carry data on it.
- **lifetime**: on stdin EOF the main thread joins the heartbeat thread, so a
  daemon started with `< /dev/null` or nohup lives until `kill`/`stop`.
- `stop` — reads the pidfile, SIGTERMs.

---

## Cross-cutting contracts

1. **Cursoring**: consumers store the last `id` they processed; `since` from
   there is resume *and* replay. Ids are monotonic per database.
2. **Topic conventions**: `agent/*` lifecycle (from the loop),
   `eventd/beat` liveness, `chan/<name>` channels, `<publisher>/<what>`
   otherwise.
3. **Payloads are objects**: jzon renders plists as arrays — always build
   payloads with `dict`, never bare `list`.
4. **The bus is optional upstream**: `agent.lisp` works with no
   `eventbus.lisp` present; the reverse is not true (eventd loads it hard).
