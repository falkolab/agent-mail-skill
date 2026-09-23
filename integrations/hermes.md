# Wiring another agent CLI into the same mailboxes

The hook contract is deliberately generic. `amq-hook.sh` takes a JSON payload on stdin,
reads `cwd` and `session_id` out of it, and prints the unread-mail reminder on stdout.
Any agent CLI that can run a command per turn and put text in front of its model can use
it. Below is the worked example for **hermes**, verified against its source rather than
only its docs — the two disagree in several places that matter.

## The short version

```yaml
# in the config.yaml of the ACTIVE PROFILE — see "Profiles" below
hooks:
  pre_llm_call:
    - command: "/absolute/path/to/agent-mail/scripts/amq-hook.sh prompt"
      timeout: 15
hooks_auto_accept: true   # or approve once interactively, see "Consent"
```

`prompt` is the plain-text mode: it prints the reminder and nothing else, and has no side
effects on the mailbox. hermes needs the output wrapped as `{"context": "..."}`, so put a
three-line adapter between them rather than teaching the shared script about hermes:

```bash
#!/usr/bin/env bash
# ~/.hermes/agent-mail/hook.sh — wraps the reminder into the hermes hook protocol.
set -uo pipefail
READER=/absolute/path/to/agent-mail/scripts/amq-hook.sh
[ -x "$READER" ] || exit 0
TEXT=$("$READER" prompt 2>/dev/null) || exit 0
[ -n "${TEXT//[$'\n\t ']/}" ] || exit 0
TEXT="$TEXT" python3 -c '
import os, json, sys
sys.stdout.write(json.dumps({"context": os.environ["TEXT"]}, ensure_ascii=False))
' 2>/dev/null || exit 0
```

Point the hook at the adapter. Keeping the integration on the hermes side means the shared
scripts — which get vendored into other people's repositories — stay agent-agnostic.

## What you get, and what you do not

`pre_llm_call` is the only usable delivery channel. Its return value is honoured and
`{"context": "..."}` is merged into the user message for the current turn.

**You do not get the stop-hook guarantee.** In Claude Code the `Stop` hook can refuse to
let a turn finish while mail is unread. hermes has no equivalent: return values are
ignored for every event except `pre_llm_call` and `pre_tool_call`. `on_session_end` does
fire at the end of every turn, so a hook there can log or notify, but it cannot hold the
turn and cannot add to the answer. So mail surfaces at the *start of the next turn*, not
before the current one ends. Plan around that — it is a real difference in behaviour, not
a detail.

Also note the hook is called **once per turn**, and its text lives only for that turn: it
is injected into a copy of the user message and never enters the session history. So the
mail has to be re-read every turn, and any "already shown" state must be kept by the hook
itself.

## Profiles — the part that wastes an afternoon

A hermes profile is a whole state directory (`HERMES_HOME`), not just a model choice.
`hooks:` is read from the **active profile's** `config.yaml`, never from a project. There
is no per-repository hook config: one script serves every project and must decide for
itself whether it is in a repository with a mailbox. `amq-hook.sh` already does that — it
exits silently where there is no `.amqrc`.

Find the file that is actually loaded:

```bash
hermes config path
```

Do not trust `hermes hooks list` here: with nothing configured it prints a hardcoded
"No shell hooks configured in ~/.hermes/config.yaml" even when it read a profile file.
`hermes config path` is the only reliable answer. Editing `~/.hermes/config.yaml` while a
named profile is active does nothing at all, silently.

Switching profiles — whether a one-off `hermes -p <name>` or a sticky
`hermes profile use <name>` — loads a different `config.yaml`, where the hook is simply
absent.

## Consent

A shell hook does not run until it is on the allowlist, keyed on the exact `(event,
command)` string pair. By default approval needs a TTY; without one the hook is skipped
with a warning and the agent carries on.

Ways to grant it without sitting at a terminal:

- `hooks_auto_accept: true` in the config — note this auto-approves *any* hook in that
  profile, not just this one;
- `HERMES_ACCEPT_HOOKS=1` in the environment;
- `hermes --accept-hooks chat` once — this writes a permanent allowlist entry and also
  covers later gateway and cron runs, which cannot take the CLI flag themselves.

The allowlist matches the command string literally. Leading and trailing spaces are
trimmed, but changing an argument, or writing the path as `~/...` instead of an absolute
path, counts as a different command and needs re-approving.

## Locating the mailbox

The payload's `cwd` is `Path.cwd()` of the hermes **process**. That is correct for an
interactive `hermes` started inside a repository, and it is correct under
`hermes --worktree`, because hermes puts its worktrees inside the repository and
`--git-common-dir` still resolves to the same mailbox.

It is *not* correct in two cases:

- **The process cwd is static.** It does not follow the agent's own `cd`, so if one run
  moves from project A to project B the hook keeps reading A's mailbox.
- **Under a gateway or cron job** the process cwd is wherever the daemon was started,
  which is usually not a project at all.

The environment variable `TERMINAL_CWD` tracks the live directory more closely and is
inherited by the hook, so `${TERMINAL_CWD:-<payload cwd>}` is the better base — ignoring
placeholder values like `.`, `auto` and `cwd`, and any relative path. In the TUI, desktop
and ACP frontends one process serves several sessions with different directories, and
deriving a single mailbox from the process cwd is not possible at all.

## Command execution

The command runs through `shlex.split` with `shell=False`. No `$(...)`, no `&&`, no pipes,
no redirection, no variable expansion — an executable path plus literal arguments, nothing
more.

One sharp edge: `os.path.expanduser` is applied to the whole command string *before*
splitting, and it only expands a tilde at the very beginning. So
`~/path/to/hook.sh prompt` expands, but `bash ~/path/to/hook.sh prompt` does not — the
tilde in the second token stays literal and the file is not found. Use an absolute path.

Failure handling is forgiving: an unparsable command, a missing or non-executable file,
malformed JSON, or a timeout all log a warning and become a no-op; the agent loop is never
aborted. A non-zero exit is *not* a no-op, though — stdout is still parsed. So write
diagnostics to stderr and put only the final JSON on stdout.

`timeout` defaults to 60 seconds and is capped at 300. A float is silently truncated to an
integer.

## Session identity

`session_id` has the form `YYYYMMDD_HHMMSS_<hex6>` and is stable across `--resume`, but it
**rotates** inside a live process on automatic context compression and on `/new`. If you
bind an AMQ topic to it, re-establish the claim rather than assuming it holds for the life
of the session.

Parallel hermes sessions in one repository are a normal scenario, so a single handle
shared across the repository will race; a topic per session will not. Delegation spawns
subagents with their own session ids, and `pre_llm_call` fires for them too — filter them
out or every subagent gets the mail reminder.
