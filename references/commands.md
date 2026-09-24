# AMQ — command reference

Flags checked against `amq 0.80.1 --help` and verified by running them. A single dash in
the help output (`-me`) and a double one (`--me`) are equivalent; below it is always double.

## Context

| Variable | Meaning |
|---|---|
| `AM_ROOT` | the active mailbox (a root, or `<root>/<session>`) |
| `AM_BASE_ROOT` | the permitted parent for named sessions |
| `AM_SESSION` | session name; empty means bound to the root |
| `AM_ME` | your own handle |
| `AMQ_GLOBAL_ROOT` | fallback root for agents started outside a repo |

```bash
eval "$(amq env --session <topic> --me <handle>)"  # pin
# CAUTION: this does NOT replace the context wholesale. AM_ROOT outranks .amqrc,
# so when changing repository first: unset AM_ROOT AM_BASE_ROOT AM_SESSION AM_ME
eval "$(amq env --me <handle>)"                    # project root, no session
amq env --json                                     # what is active right now
amq env --session-name                             # just the session name (for a statusline)
```

Root resolution order:
`--root` → `AM_ROOT` → the project's `.amqrc` → `AMQ_GLOBAL_ROOT` → implicit fallbacks.

**Inside a git repository `~/.amqrc` does not apply** — otherwise a worktree could
silently drag in someone else's queue. A relative `root` is deliberately per-worktree: two
worktrees with the same session name read **different** mailboxes. If you need a shared
one, write the same absolute `root` into each one's local `.amqrc`.

## Sending

```bash
amq send --to <who> --body "<text>"                           # within your own session
amq send --to <who> --session <other> --body "..."            # your project, another session
amq send --to <who> --project <project> --session collab --body "..."   # another project
amq send --to "<who>@<project>:<session>" --body "..."        # the same, inline
```

Useful: `--subject`, `--kind`, `--priority`, `--labels a,b`, `--thread <id>`,
`--context '<json>'`, `--body @file`, `--body -` (stdin),
`--wait-for drained --wait-timeout 60s`, `--json`, `--strict`.

Without `--session`, a cross-project send goes to the **same-named** session at the
neighbour. If there is none there, it is refused. So for `collab` always say it explicitly.

Send **file paths, not file contents**. The recipient will open them; if they have no
access to your worktree, send a short diff.

## Receiving

**These consume** — the message moves from `new` to `cur` irreversibly: `amq` has no
reverse operation. A mailbox is a "session + handle" pair: in your own topic you are alone
in it and taking your own mail is safe; the `collab` mailbox is shared by the whole
project, and there a message disappears for every window.

```bash
amq drain --include-body --limit 0 # take EVERYTHING (the --limit 20 default truncates silently!)
amq drain --include-body --json     # the same, machine-readable
amq read --id <msg_id>              # ONE MESSAGE, BUT IT ALSO TAKES IT: this is not a view.
                                    # read has no "do not take" flag
amq monitor --timeout <N>s --include-body --json   # wait and take, returns on arrival
```

**These do not consume** — the read status does not change, which is how you identify
someone else's message:

```bash
amq list --new                      # metadata, no body
amq list --new --json               # + thread and path to the file
amq list --new --priority urgent --kind question --from <who> --label <label>
amq thread --id <thread> --include-body   # thread bodies; --id is the id of the THREAD,
                                          # given a message id it prints nothing and exits 0
amq monitor --peek --timeout <N>s   # wait without taking
amq watch --timeout <N>s            # wait only
amq-log.sh --body                   # bodies, reads the files directly (see below)
```

`--poll` is the fallback instead of fsnotify (network filesystems).

## Replying

```bash
amq reply --id <msg_id> --kind answer --body "..."
```
The thread, `refs` and the return route are filled in automatically. `--project` is not
needed. `reply` has **no** `--session` flag — it needs a pinned context or `--root`.

## Sessions and presence

```bash
amq session create <name>     # [a-z0-9_-] only; an existing one is a loud error
amq session list --json       # every session of the mailbox with paths (the hook walks them all)
amq who                       # sessions, agents, active/stale
amq who --json
amq presence set --status busy --note "<what you are doing>"
amq presence list --json
```
Read `stale` as "unknown", not as "busy". Presence is not cleaned up when a terminal dies.

## Project setup

```bash
amq coop init --root .agent-mail --agents <handle>,user   # arbitrary handles
amq setup --preview --project-root <path> ...            # preview + digest; adapter handles only
amq init --root .agent-mail --agents a,b,user            # registry without .gitignore
```
`amq setup` accepts only the handles of supported adapters (claude, codex, cursor, grok) —
arbitrary names need `coop init`.
`coop init` and `setup` append to `.gitignore` themselves; `init` does not.

## `.amqrc`

```json
{
  "root": ".agent-mail",
  "project": "<project-name>",
  "peers": { "<neighbour-name>": "/absolute/path/to/neighbour/.agent-mail" }
}
```
`coop init` writes only `root` — `project` and `peers` are added by our script.
`coop init` also puts `.amqrc` into `.gitignore`: it is a machine-local config, do not commit it.
The peer key must match the `project` declared at the neighbour, otherwise the return
route breaks silently. Relative paths do resolve — keep them relative.
Peering is bidirectional.

## On-disk layout

```
.agent-mail/                     base root
.agent-mail/meta/config.json     agent registry
.agent-mail/<session>/           an isolated topic
  agents/<handle>/inbox/{new,cur,tmp}
  agents/<handle>/{outbox/sent,dlq,receipts}
```
A message is a `.md` file: a JSON frontmatter (`id`, `from`, `to`, `thread`, `subject`,
`kind`, `priority`, `labels`, `from_project`, `reply_project`) plus the body.

## Threads

- within a project: `p2p/<a>__<b>`
- between projects: `p2p/<projectA>:<session>:<a>__<projectB>:<session>:<b>`
- topical: your own stable id, the same in both projects, e.g. `decision/api-v2`, `gate/<topic>`

## Repairing a message you took by mistake

```bash
amq-return.sh <id> --to <topic> [--note "<one line>"]
```
Forwards a copy into the topic that owns it, carrying the original thread, labels and
kind, and naming the original sender so the addressee knows who to answer. Run it from
inside the repository. There is no true "return": nothing puts a consumed message back
into `new`, and moving the file by hand would return it to every window sharing that
mailbox, including the one that already read it.

## Which mailbox is this window on

```bash
amq-use.sh --show
```
Prints project, handle, window, topic and the absolute mailbox path. The same path is in
the hook header every turn. Use this when asked "which mailbox / which session are you
on" — "session" means a topic to AMQ and a window to the harness, so quote the labelled
output instead of paraphrasing.

## Reading the exchange and identifying a message

```bash
amq-log.sh [--dir <repo>] [--all] [--body] [--thread <id>] [--limit N] [--follow]
```
Gathers messages from the files of both projects and prints them in time order. It
consumes nothing and does not change the read status — which makes it useful not only to a
human reading history but to an agent working out whose message it is without taking it.
`--all` pulls in the projects from `peers`. `--follow` loops forever; do not give it to an agent.

## Diagnostics

```bash
amq doctor              # binary, .amqrc, mailboxes, registry
amq doctor --ops        # + queue depth, DLQ, presence, worktree divergence
amq doctor --fix-mailboxes
amq route explain --to <who> --project <project> --session <session> --json
amq dlq list            # dead messages
amq receipts list --me <handle>   # delivery receipts
# Bare `amq dlq` and `amq receipts` print help and return 0 — they look like a
# check that passed and found everything clean. The subcommand is mandatory.
amq trace               # evidence for a message
amq cleanup             # tmp, quarantine, recovery artifacts
```

When pinned to a topic, `amq doctor` prints `⚠ Config: config.json not found`: the
registry lives in the base root, while a pinned doctor looks for it in the topic root.
This is not a breakage — on the base root the same command gives
`✓ Config: agents: [...]`. Verified on 0.80.1.

`amq doctor` will complain `claude skill: not installed` — it is looking for the
**upstream** skill installed through `npx skills`. This one is not that; the warning is
cosmetic.

## Exit codes

`0` success · `1` general error · `2` arguments · `3` not found · `4` timeout ·
`5` context mismatch (pin / unsuitable root) · `6` a human has to act.

A read-only `list` warns and continues when the pin does not match; state-changing
commands fail with `5`. Parsing stderr text as a signal is not allowed — the contract is
the exit code.

## Left out of this scheme

Not part of this setup, but present in AMQ: `coop exec` (starting an agent with a
preconfigured environment and wake), `launch`, `swarm` (Claude Code Agent Teams),
`integration symphony|kanban`, `amq-bridge` (two machines), `amq-acp`, `wake`.
`wake` needs a TTY and does not work in the Claude app.
`amq-bridge` is what you need if the projects end up on different hosts.
