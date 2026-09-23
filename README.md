# agent-mail

A Claude Code skill that lets agents in different repositories, worktrees and sessions
send each other mail.

It is a thin layer over [AMQ](https://github.com/avivsinai/agent-message-queue) (`amq`), a file-based
agent message queue. AMQ does the transport; this skill adds the part that makes it usable
by an agent rather than by a person: project setup in one command, delivery hooks that put
unread mail in front of the model, per-window topics so two sessions in one repository do
not race for the same inbox, and a written set of rules for the failure modes that cost
you a message.

No server, no daemon, no ports, no Docker. A message is a `.md` file with a JSON
frontmatter written into the recipient's directory.

## What it is for

- **Handoffs.** One session finishes a piece of work and hands the context to another.
- **Cross-project questions.** An agent in repo A asks the agent who actually owns repo B,
  instead of guessing from the code.
- **Coordination between windows.** Several Claude Code sessions in the same repository,
  each on its own topic, without stepping on each other.

## Requirements

- `amq` — `brew install avivsinai/tap/amq`. Written against **0.80.1**; flags have moved
  between minor versions, so check `amq --version` if something in the reference does not
  match.
- `git`, `python3`, `bash`.
- Claude Code, for the hooks. The scripts themselves work without it.

Developed on macOS. The tap ships Linux builds too and the scripts avoid GNU-only flags,
but Linux is not yet exercised — if something breaks there, an issue with the output is
welcome.

## Install

Put the skill where Claude Code looks for skills:

```bash
git clone https://github.com/falkolab/agent-mail-skill ~/.claude/skills/agent-mail
```

`~/.claude/skills/` makes it available in every project. For one project only, clone into
`<repo>/.claude/skills/agent-mail` instead.

Then set up each repository that should be able to send and receive:

```bash
~/.claude/skills/agent-mail/scripts/amq-setup-project.sh \
  --project backend --dir ~/code/backend --handle backend-claude \
  --peer frontend=~/code/frontend
```

Run it **on both sides** — peering is bidirectional, and a one-sided one does not answer.
The first run will say the neighbour is not configured yet; after the second the route
converges and the script verifies it in both directions.

Re-running is safe: it repairs what is missing and overwrites nothing.

## What it sets up

```
<repo>/.amqrc                            project name, handle, peers (machine-local, not committed)
<repo>/.agent-mail/                      the mailboxes and the whole correspondence
<repo>/.claude/hooks/agent-mail/*.sh     vendored copies of the scripts — commit these
<repo>/.claude/settings.json             the three delivery hooks — commit this
```

The hook command resolves its own path from the worktree root, so it holds nothing
machine-specific. Commit `.claude/` and git distributes hooks and scripts to every working
copy, including ones created later.

The mailbox belongs to the **repository**, not to a working copy: it is located through
`git rev-parse --git-common-dir`, so every worktree shares one mailbox without its own
config.

## How delivery works

Three hooks: on session start, on every user prompt, and before the turn ends. They only
*show* the inbox — the agent collects the mail itself with `amq drain`. The stop hook is
what keeps a session from ending a turn with unread mail.

A session learns about a message only while it is alive and something is happening in it.
If nobody has the project open, the message waits. This is mail, not a phone call:
delivery is guaranteed, immediacy is not.

## The one thing worth reading before you start

`amq read --id` does not show a message — it **takes** it. The message moves out of the
unread box, and in the shared `collab` mailbox that means it disappears for every window
in the project, with no trace. There is no command that puts it back.

To look at a message without consuming it, use `amq list --new --json`,
`amq thread --id <thread> --include-body`, `amq monitor --peek`, or
`scripts/amq-log.sh --all --body`.

[SKILL.md](SKILL.md) covers this and the rest of the rules. [references/commands.md](references/commands.md)
is the command reference, split by what consumes and what does not.

## Other agent CLIs

[integrations/hermes.md](integrations/hermes.md) describes wiring a non-Claude agent CLI
into the same mailboxes, using hermes as the worked example. The hook contract is generic:
JSON payload on stdin, the reminder text on stdout.

## What this does not do

- No broadcast — `--project` takes exactly one recipient. A shared thread is how several
  parties follow one conversation.
- No push into a running terminal. `amq wake` exists in AMQ and needs a real TTY; it does
  not work inside the Claude app, and this skill does not use it.
- No delivery across machines. AMQ has `amq-bridge` for that; this skill assumes one host.

## Licence

MIT. See [LICENSE](LICENSE).

`amq` itself is a separate MIT-licensed project. This repository does not redistribute
it — the installer pulls it from the upstream Homebrew tap.
