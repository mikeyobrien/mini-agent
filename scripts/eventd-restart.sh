#!/bin/bash
# Graceful eventd restart via the supervisor: kill child only; supervisor
# respawns within its backoff. Safe to call from agents.
cd "$(dirname "$0")/.."
[ -f eventd.pid ] && kill "$(cat eventd.pid)" 2>/dev/null
sleep 3
ps -p "$(cat eventd.pid 2>/dev/null)" >/dev/null 2>&1 && echo "eventd restarting" || echo "eventd down; supervisor will respawn"
