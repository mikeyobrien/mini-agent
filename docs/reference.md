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

#### `run (task)` — function → `(values answer ok)`
The loop. Ends at the first assistant turn with no tool calls → `(values
answer t)`, or when `*max-steps*` (nonzero) steps ran → `(values reason nil)`.
Prints `[step N] $ cmd` lines and the answer for the CLI; hosts bind
`*standard-output*` away and use the values. Side effects:
- emits `agent/start`, `agent/step`, `agent/done` via `emit` when the eventbus loaded
- appends tool results to history as `(:role . "tool")` entries

#### `*context*` — special
Plist of string keys stamped onto every `agent/*` payload, e.g.
`(let ((mini-agent:*context* (list "chat_id" 42))) (mini-agent:run task))` —
how observers tie telemetry to the host's request.

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
Publishes to topic `agent/<event>` when the eventbus loaded, merged with
`*context*`; `ignore-errors` wrapped — telemetry failures never fail a run. Payloads are JSON objects
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
  without the colon (jzon renders hash-tables as JSON objects). Its own copy:
  the agent must run without the bus.

---

## eventbus (eventbus.lisp)

The bus is the schema; any sqlite client in any language may participate.

Schema: `events(id INTEGER PRIMARY KEY, ts TEXT DEFAULT datetime('now'), topic TEXT NOT NULL, payload TEXT /*JSON*/)`.

#### `ensure-schema` — function `()`
Idempotent `CREATE TABLE`/`INDEX`.

#### `publish (topic payload)` — function → id
`payload` is any jzon-stringifyable structure. Returns the rowid — that id is
the cursor contract. Wakes every `tail`/`await-publish` waiter in the image.

#### `dict (&rest kvs)` / `jget (h &rest keys)` — payload helpers
`(dict "chat_id" 1 "reply_to" nil)` → `{"chat_id":1}`: string keys, nil
values omitted. `(jget data "chat" "id")` walks nested objects, nil-safe.

#### `since (last-id &optional topic-glob)` — function → list
Rows with `id > last-id`, optional `SQL GLOB` on topic (`agents/*`), oldest
first, cap 500. Each entry: `(:id :ts :topic :data)` with `data` parsed from
JSON. `:null` payloads parse to the keyword `:null` — handle it.

#### `get-event (id)` — function → event or nil

#### `tail (topic-glob handler &key from idle name)` — function, never returns
The consumer loop: calls `handler` on each matching event with id > `from`
(default: the current tail), oldest first. A handler error is logged and that
event skipped. Wakes on publishes in this image; polls every `idle` seconds
(default 2) for other writers. Boot hooks are usually one `tail` call.

#### `publish-count` / `await-publish (seen timeout)` — the wakeup primitive
`(let ((seen (publish-count))) (work) (await-publish seen 2))` returns as
soon as anything published after `seen`, or after the timeout.

Connection per call; `busy_timeout=5000` and WAL set on every connection.
Single-writer semantics: serialize writes or accept SQLite's busy-retry.

---

## eventd (eventd.lisp)

Long-lived daemon; run detached, it writes `eventd.pid` next to itself.

- **stdin protocol**: lines `"<topic> <json>"` → publish, prints `ok`;
  `since <id> [glob]` → dumps matching events, one JSON object per line.
- **heartbeat**: publishes `eventd/beat {"ts":...}` every
  `EVENTD_BEAT_SECONDS` (default 30). Liveness only — never carry data on it.
- **dispatcher**: per-channel delivery (`deliveries.db`): due retries, then
  events past the channel's cursor. Runs on every publish in the image, and
  every `EVENTD_DISPATCH_POLL_SECONDS` (2) for outside writers and backoff.
  Exponential backoff to `EVENTD_DISPATCH_MAX_BACKOFF` (300s); `dead` after
  50 attempts.
- **lifetime**: the main thread runs the heartbeat forever; the REPL has its
  own thread and simply ends at stdin EOF, so a daemon started with
  `< /dev/null` lives until `kill`/`stop`. Every side thread logs its errors
  instead of letting them exit the process.
- `stop` — reads the pidfile, SIGTERMs.

---

## chanreg (chanreg.lisp) and channels.d/

eventd loads every `channels.d/*.lisp` after `eventbus` and `chanreg`, so
connector files name `eventbus:`/`chanreg:` symbols directly.

- `register (name poll-glob send-fn &optional start-fn)` — a channel: the
  dispatcher calls `(send-fn id ts topic data)` for events matching
  `poll-glob`; true = delivered, nil/error = retry with backoff. `start-fn`
  runs in its own thread at boot (e.g. Telegram's getUpdates loop).
- `add-boot-hook (name thunk)` — a consumer that is not a channel (responders,
  notifiers): `thunk` runs in a thread named `name` at boot, typically
  `(eventbus:tail glob #'handle)`.
- Both are idempotent by name. `repo-root` is the checkout eventd runs from.

Shipped: `telegram` (channel), `agent-responder`, `echo-responder`,
`progress-notifier` (hooks). They talk only through bus topics:
`telegram/inbound`, `telegram/outbound`, `telegram/typing`, `agent/*`.

---

## Cross-cutting contracts

1. **Cursoring**: consumers store the last `id` they processed; `since` from
   there is resume *and* replay. Ids are monotonic per database.
2. **Topic conventions**: `agent/*` lifecycle (from the loop),
   `eventd/beat` liveness, `chan/<name>` channels, `<publisher>/<what>`
   otherwise.
3. **Payloads are objects**: jzon renders plists as arrays — always build
   payloads with `dict` (`eventbus:dict`, or `mini-agent::dict` inside the
   agent), never bare `list`.
4. **The bus is optional upstream**: `agent.lisp` works with no
   `eventbus.lisp` present; the reverse is not true (eventd loads it hard).
