#!/usr/bin/env python3
"""mini-agent — the bare-minimum agent loop from minimal-agent.com.

query LM -> tool call -> execute -> append result -> repeat.

One tool: bash. Stateless subprocess per action. Linear append-only history.
Errors are appended as user/tool messages so the model self-corrects.

Usage:
    python3 agent.py "fix the failing test in foo.py"
    python3 agent.py            # interactive: type tasks, Ctrl-D quits
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

from urllib.request import Request, urlopen

# --- Config (env overrides) -------------------------------------------------
BASE_URL = os.environ.get("MINI_AGENT_BASE_URL", "http://spark-1:8888/v1")
MODEL = os.environ.get("MINI_AGENT_MODEL", "GLM-5.3-Flash-EXL3")
MAX_STEPS = int(os.environ.get("MINI_AGENT_MAX_STEPS", "40"))
STEP_TIMEOUT = int(os.environ.get("MINI_AGENT_TIMEOUT", "120"))
# High thinking per operator config; budget bounds a single thought.
THINKING = {"enable_thinking": True, "thinking_budget": 16384}

SYSTEM_PROMPT = """You are mini-agent. /SYSTEM.md is loaded as the system message.
Every response must use the bash tool at least once, except your final answer.
To finish: reply with plain text, no tool call."""

def load_system_md() -> str:
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "SYSTEM.md")
    with open(path, encoding="utf-8") as f:
        return f.read()

# --- LM ---------------------------------------------------------------------
def query_lm(messages: list[dict]) -> dict:
    """One chat completion. Returns the assistant message dict."""
    body = {
        "model": MODEL,
        "messages": messages,
        "tools": [{
            "type": "function",
            "function": {
                "name": "bash",
                "description": "Run a shell command in a fresh subshell. "
                    "No state persists between calls: prefix cd / export every time.",
                "parameters": {
                    "type": "object",
                    "properties": {"command": {"type": "string"}},
                    "required": ["command"],
                },
            },
        }],
        "tool_choice": "auto",
        "chat_template_kwargs": THINKING,
    }
    req = Request(
        f"{BASE_URL}/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urlopen(req, timeout=300) as resp:
        data = json.loads(resp.read())
    return data["choices"][0]["message"]

# --- Environment ------------------------------------------------------------
def execute(command: str) -> str:
    """Stateless subprocess: every action independent, like mini-swe-agent."""
    result = subprocess.run(
        command, shell=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=STEP_TIMEOUT,
    )
    out = result.stdout or "(no output)"
    if len(out) > 20_000:
        head, _, tail = out[:10_000], None, out[-5_000:]
        out = head + f"\n... truncated ({len(out)} chars) ...\n" + tail
    return out

# --- Agent loop -------------------------------------------------------------
def run(task: str) -> None:
    messages: list[dict] = [
        {"role": "system", "content": load_system_md()},
        {"role": "user", "content": task},
    ]
    for step in range(1, MAX_STEPS + 1):
        try:
            msg = query_lm(messages)
        except Exception as e:  # API errors: tell the model, let it adapt
            messages.append({"role": "user", "content": f"API error, retry: {e}"})
            continue

        messages.append(msg)  # assistant msg (content + tool_calls) verbatim

        calls = msg.get("tool_calls") or []
        if not calls:
            print(msg.get("content") or "(empty)")
            return

        for call in calls:
            args = json.loads(call["function"]["arguments"] or "{}")
            command = str(args.get("command", ""))
            print(f"[step {step}] $ {command}")
            try:
                output = execute(command)
            except subprocess.TimeoutExpired:
                output = f"Timeout after {STEP_TIMEOUT}s. Use nohup/& for long jobs."
            except Exception as e:
                output = f"Error: {e}"
            messages.append({
                "role": "tool",
                "tool_call_id": call["id"],
                "content": output,
            })
    print(f"(step budget {MAX_STEPS} exhausted)")

if __name__ == "__main__":
    task = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else input("task: ")
    run(task)
