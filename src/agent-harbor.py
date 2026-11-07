"""Harbor adapter: mini-agent (sbcl --script run.lisp) inside the task container.

Env expected on the host before `harbor run ... -a mini-agent`:
  MINI_AGENT_BASE_URL   OpenAI-compatible endpoint reachable FROM the container
                        (host broker: http://host.docker.internal:PORT/v1)
  MINI_AGENT_MODEL      model id
  OPENAI_API_KEY        if the endpoint needs it (passed through)

Installs sbcl+quicklisp+jzon in the container, uploads this repo, runs
run.lisp with the task instruction.
"""
from __future__ import annotations
import os
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

REPO = Path(__file__).resolve().parent.parent  # repo root (adapter lives in src/)


class MiniAgentAgent(BaseInstalledAgent):
    @staticmethod
    def name() -> str:
        return "mini-agent"

    @staticmethod
    def model_connection_env() -> dict[str, str]:
        env = {}
        for k in ("MINI_AGENT_BASE_URL", "MINI_AGENT_MODEL", "OPENAI_API_KEY", "OPENAI_BASE_URL"):
            if v := os.environ.get(k):
                env[k] = v
        return env

    def get_version_command(self) -> str | None:
        return "sbcl --version"

    async def install(self, environment: BaseEnvironment) -> None:
        await self.ensure_system_dependencies(environment, ("curl",))
        await self.exec_as_agent(environment, command=(
            "set -e; export DEBIAN_FRONTEND=noninteractive; "
            "command -v sbcl >/dev/null || { apt-get update -qq && apt-get install -y -qq sbcl ca-certificates; }; "
            "if [ ! -f $HOME/quicklisp/setup.lisp ]; then "
            "cd /tmp && curl -sO https://beta.quicklisp.org/quicklisp.lisp && "
            "sbcl --noinform --non-interactive --load quicklisp.lisp "
            "--eval '(quicklisp-quickstart:install)' >/dev/null && rm quicklisp.lisp; fi; "
            "sbcl --noinform --non-interactive --load $HOME/quicklisp/setup.lisp "
            "--eval '(ql:quickload :com.inuoe.jzon)' --quit"
        ))

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        await environment.upload_dir(REPO, "/opt/mini-agent")
        env = self.model_connection_env()
        await self.exec_as_agent(
            environment,
            env=env,
            command=(
                "cd /app 2>/dev/null || cd $HOME; "
                "sbcl --noinform --script /opt/mini-agent/run.lisp "
                + "'" + instruction.replace("'", "'\\''") + "'"
            ),
            timeout_sec=None,
        )
