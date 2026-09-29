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

- `amq` — `brew install avivsinai/tap/amq`. Written against **0.80.1**; the hook says so
  once if the installed version differs.
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

The commands below are written as bare script names. They live in `scripts/` wherever you
just cloned this — prefix them with that path, or put it on your `PATH`.

Register the delivery hooks once, for your user:

```bash
amq-install-user-hooks.sh
```

That covers every repository on the machine, including ones created later and every
worktree, with **nothing installed into any project**. It writes only its own entries and
leaves other tools' hooks alone; `--check` reports what is registered and `--remove` takes
it back out. In repositories without a `.amqrc` the hook exits silently in about 70 ms and
spawns nothing.

Then give each repository a mailbox. One run per repository, listing every repository it
should be able to reach:

```bash
amq-setup-project.sh --project <name> --dir <repo> --handle <handle> \
                     [--peer <their-name>=<their-repo>]...
```

`--project` is this repository's name in the mail. `--handle` is who sends and receives
here; one per repository, so prefix it with the project to keep senders apart. `--peer`
names a repository this one may write to, and **the name must be the peer's own
`--project`** — otherwise the outbound route works and replies silently do not. The script
checks that.

Peering is mutual, so run it on both sides with the names mirrored:

```bash
# in the invoicing repo
amq-setup-project.sh --project invoicing --dir ~/code/invoicing \
                     --handle invoicing-claude --peer crm=~/code/crm

# in the CRM repo
amq-setup-project.sh --project crm --dir ~/code/crm \
                     --handle crm-claude --peer invoicing=~/code/invoicing
```

The first run says the neighbour is not configured yet — expected, it is not there so far.
After the second the route converges and the script verifies it in both directions.

**With more repositories it is still one run each, not one per pair** — `--peer` repeats.
Peer only the ones that actually correspond; a repository nobody writes to needs no peers
at all. Adding a fourth later means one run in it, plus a one-line run in each repository
it should talk to:

```bash
amq-setup-project.sh --project crm --dir ~/code/crm --handle crm-claude \
                     --peer shipping=~/code/shipping
```

Re-running is safe and additive: existing peers survive, the missing one is added, nothing
is overwritten. Use it the same way to repair the config after moving a repository, since
peer paths are absolute.

Mutual peering is not a formality: a reply fails outright without it
(`no peers configured in .amqrc`), so both sides must list each other.

## What it sets up

```
<repo>/.amqrc          project name, handle, peers (machine-local, git-excluded)
<repo>/.agent-mail/    the mailboxes and the whole correspondence (git-excluded)
```

That is all. Nothing is committed and no scripts are copied into the project: the hooks
are registered once for your user and run the scripts from wherever you cloned this skill.

The mailbox belongs to the **repository**, not to a working copy, so every worktree
shares one mailbox without its own config. A submodule is separate: it needs its own.

## How delivery works

Three hooks: on session start, on every user prompt, and before the turn ends. They only
*show* the inbox — the agent collects the mail itself with `amq drain`. The stop hook is
what keeps a session from ending a turn with unread mail.

A session learns about a message only while it is alive and something is happening in it.
If nobody has the project open, the message waits. This is mail, not a phone call:
delivery is guaranteed, immediacy is not.

## The rules the agents follow

[SKILL.md](SKILL.md) is what the model reads: which mail is yours, what to ignore, and
which commands consume a message rather than show it.
[references/commands.md](references/commands.md) is the command reference, split by what
consumes and what does not.

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
- No cloud sessions. A mailbox lives beside the repository and is excluded from git, so a
  clone made elsewhere — claude.ai/code included — has none, and the hook there has
  nothing to read.

## You might also like

[chekhov-skill](https://github.com/falkolab/chekhov-skill) — a Claude Code skill that makes
replies terse the way Chekhov edited prose: no preamble, no summing up, only the details
that fire.

## License

MIT. See [LICENSE](LICENSE).

`amq` itself is a separate MIT-licensed project. This repository does not redistribute
it — the installer pulls it from the upstream Homebrew tap.

## Author

Andrei Tkachenko, Telegram channel "Automate It" (Rus): [@aitomateit](https://t.me/aitomateit)
