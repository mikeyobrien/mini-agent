# Operations Runbook

day-2: running, observing, and troubleshooting the agent + bus on a host.

## Components

| process | started by | long-lived? |
|---|---|---|
| agent run | `run.lisp` per task | no — exits when done |
| eventd | you / launchd / nohup | yes |
| docker (harbor runs) | harbor | per trial |

## Running an agent task

```bash
export MINI_AGENT_BASE_URL=http://spark-1:8000/v1
export MINI_AGENT_MODEL=my-model
sbcl --script run.lisp "fix the flaky test in foo.py"     # foreground
MINI_AGENT_TIMEOUT=300 timeout 900 sbcl --script run.lisp "big task"  # bounded
```

Exit 0 + final answer on stdout = success. Load-time silence means nothing
ran — check the env vars (`run.lisp` sets AUTORUN itself; you don't need to).

## Running the bus daemon

```bash
cd ~/mini-agent
nohup sbcl --noinform --load ~/.quicklisp/setup.lisp --script eventd.lisp \
  </dev/null >>/tmp/eventd.log 2>&1 &
# pid in eventd.pid; or run under launchd for keepalive (see below)
```

Publish/inspect without a client library:

```bash
exec 3>./evin                      # hold the fifo... or just use a pipe:
printf 'agents/mia {"ok":true}\n' | sbcl --script - <<'EOF' 2>/dev/null
