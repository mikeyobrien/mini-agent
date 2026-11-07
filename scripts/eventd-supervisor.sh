#!/bin/bash
# eventd-supervisor.sh -- keep the bus daemon alive. Bounded backoff, logged.
# Launch:  nohup scripts/eventd-supervisor.sh </dev/null >>/tmp/eventd-sup.log 2>&1 &
# Stop:    kill the supervisor pid (it kills the child first); or eventd stop.

cd "$(dirname "$0")/.."   # repo root

DELAY=5
MAX_DELAY=60
while true; do
  # stale pidfile cleanup
  if [ -f eventd.pid ]; then
    pid=$(cat eventd.pid 2>/dev/null)
    if [ -n "$pid" ] && ! ps -p "$pid" >/dev/null 2>&1; then
      rm -f eventd.pid
    fi
  fi
  echo "$(date '+%F %T') supervising: starting eventd"
  sbcl --noinform --noprint --load ~/.quicklisp/setup.lisp \
       --script src/eventd.lisp </dev/null >>/tmp/eventd.log 2>&1
  code=$?
  echo "$(date '+%F %T') eventd exited rc=$code; restart in ${DELAY}s"
  # bounded backoff, reset on long runs
  DELAY=$(( code == 0 ? 5 : DELAY * 2 ))
  [ "$DELAY" -gt "$MAX_DELAY" ] && DELAY=$MAX_DELAY
  sleep "$DELAY"
done
