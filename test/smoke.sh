#!/usr/bin/env bash
# smoke.sh — bounded live smoke tests for mini-agent.
#
# Requires MINI_AGENT_BASE_URL + MINI_AGENT_MODEL in the environment (or a
# .env sourced beforehand). Every case is time-bounded; the suite always
# exits within ~3 minutes. Exit 0 = all pass, 1 = failure (message says which).
#
# Usage: test/smoke.sh            # run all cases
#        test/smoke.sh basic      # one case, by name
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root (test/ -> ..)

# --- env check -------------------------------------------------------------
: "${MINI_AGENT_BASE_URL:?MINI_AGENT_BASE_URL not set (e.g. http://host:8000/v1)}"
: "${MINI_AGENT_MODEL:?MINI_AGENT_MODEL not set}"
export MINI_AGENT_AUTORUN=1

PER_CASE_TIMEOUT=90
TOTAL_DEADLINE=$((SECONDS + 170))
PASS=0; FAIL=0; FAILED=()

run_case() { # name expect_re seconds task
  local name="$1" expect_re="$2" tmo="$3"; shift 3
  local task="$*"
  if (( SECONDS > TOTAL_DEADLINE )); then
    echo "SKIP $name (global deadline)"
    return 0
  fi
  local out
  if out=$(timeout "$tmo" sbcl --script src/run.lisp "$task" 2>&1); then
    if [[ "$out" =~ $expect_re ]]; then
      echo "PASS $name"
      PASS=$((PASS+1)); return 0
    fi
    echo "FAIL $name (output missing /$expect_re/)"
  else
    echo "FAIL $name (exit $? after ${tmo}s)"
  fi
  echo "---- last output ----"; echo "$out" | tail -5; echo "--------------------"
  FAIL=$((FAIL+1)); FAILED+=("$name"); return 1
}

# --- cases -----------------------------------------------------------------
CASES=("$@"); (( ${#CASES[@]} )) || CASES=(basic multi config)

for c in "${CASES[@]}"; do
  case "$c" in
    basic)
      # 1. single-step: trivial echo round-trip
      marker="smoke-$(date +%H%M%S)"
      run_case basic "$marker" "$PER_CASE_TIMEOUT" \
        "run echo $marker and confirm its output"
      ;;
    multi)
      # 2. multi-step: create, verify, modify — exercises history accumulation
      f="/tmp/mini-agent-smoke-$$.txt"
      run_case multi "smoke-multi-ok" "$PER_CASE_TIMEOUT" \
        "Write smoke-multi to $f, then append -ok, then cat it and report the exact final content."
      rm -f "$f"
      ;;
    config)
      # 3. missing-env failure path: loud error, non-zero exit
      if env -u MINI_AGENT_BASE_URL MINI_AGENT_AUTORUN=1 timeout 20 \
           sbcl --script src/run.lisp "x" >/tmp/mi-smoke-env.out 2>&1; then
        echo "FAIL config (missing-env run should exit non-zero)"
        FAIL=$((FAIL+1)); FAILED+=("config")
      elif grep -q "MINI_AGENT_BASE_URL not set" /tmp/mi-smoke-env.out; then
        echo "PASS config"; PASS=$((PASS+1))
      else
        echo "FAIL config (no MINI_AGENT_BASE_URL error in output)"
        FAIL=$((FAIL+1)); FAILED+=("config")
      fi
      ;;
    *) echo "unknown case: $c"; exit 2 ;;
  esac
done

# --- summary ---------------------------------------------------------------
echo "=================================================="
echo "smoke: $PASS passed, $FAIL failed  (model=$MINI_AGENT_MODEL)"
(( FAIL == 0 )) || printf 'failed: %s\n' "${FAILED[*]}"
exit $(( FAIL > 0 ? 1 : 0 ))
