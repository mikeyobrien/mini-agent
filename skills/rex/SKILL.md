---
name: rex
description: Use the rex CLI to manage Rex terminal sessions, open tabs, split panes, run commands in them, and read terminal output.
---

Run `rex skill show` and follow the guide it prints. The guide comes from the
installed Rex CLI, so it matches that version's commands — don't work from
memory.

mini-agent specifics:

- `REX_SESSION` and `REX_BLOCK` are inherited from the shell that launched
  mini-agent. Check them with `echo "$REX_SESSION $REX_BLOCK"`; if empty, start
  from `rex whoami --json` then `rex ls --json`.
- Every command is a fresh subshell, so pass targets explicitly each time
  (`-s "$REX_SESSION"`, `-b "$REX_BLOCK"`); nothing carries over between steps.
- Prefer `--json` output and pipe through `jq` to keep tool output small.

If `rex skill show` fails, the installed Rex predates the guide: use
`rex --help` and `rex COMMAND --help`.
