#!/usr/bin/env bash
# Claim a topic for THIS window: create a session, record it against the window
# and print the context-pinning line.
#
#   eval "$(~/.claude/skills/agent-mail/scripts/amq-use.sh "api redesign")"
#   eval "$(~/.claude/skills/agent-mail/scripts/amq-use.sh --show)"   # what is claimed now
#
# Why: until a window claims its own topic it sits in the shared collab together
# with other windows — and they share one mailbox. Own topic = own mailbox, no races.


set -uo pipefail

# The mailbox belongs to the REPOSITORY, not to a working copy: --git-common-dir
# from any worktree returns the common directory, and .amqrc sits next to it.
# So a copy needs neither its own config nor a second setup run — including a
# copy created after the setup was already done.
amq_repo_root() {
  local start="${1:-$PWD}" c d
  c=$(git -C "$start" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$c" ]; then
    d=$(dirname "$c")
    [ -f "$d/.amqrc" ] && { printf '%s' "$d"; return 0; }
    [ -f "$c/.amqrc" ] && { printf '%s' "$c"; return 0; }   # bare repository
  fi
  d="$start"                                   # outside git — walk up the tree
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.amqrc" ] && { printf '%s' "$d"; return 0; }
    d=$(dirname "$d")
  done
  return 1
}

export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
say() { echo "$@" >&2; }

command -v amq >/dev/null 2>&1 || { say "amq not found"; exit 1; }
DIR=$(amq_repo_root) || { say "project is not connected to agent-mail (no .amqrc)"; exit 3; }

IFS=$'\t' read -r ROOT ME PROJECT <<<"$(python3 -c "
import json,sys
c=json.load(open(sys.argv[1]+'/.amqrc'))
print('\t'.join([c.get('root','.agent-mail'), c.get('handle',''), c.get('project','?')]))" "$DIR")"
case "$ROOT" in /*) RP="$ROOT" ;; *) RP="$DIR/$ROOT" ;; esac
[ -n "$ME" ] || { say "no handle in .amqrc — rerun amq-setup-project.sh"; exit 3; }

# The peer is an agent session, not a terminal: inside the app there is no real
# tty, and a tty-based key degenerates into a shared one — windows become alike.
WIN="${AMQ_WINDOW:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$WIN" ] || WIN="tty-$(printf '%s' "${TTY:-$(tty 2>/dev/null || echo nowin)}" | shasum | cut -c1-8)"
STATE="$RP/.window-$(printf '%s' "$WIN" | tr -c 'A-Za-z0-9_.-' '_')"

if [ "${1:-}" = "--show" ]; then
  # Answers "which mailbox is this window on?" in full, so it can be quoted back to a
  # human verbatim. Printing only the topic name left both sides guessing: AMQ calls a
  # topic a "session", so does the harness, and they are not the same thing.
  cur=$(cat "$STATE" 2>/dev/null)
  say "project:  $PROJECT"
  say "handle:   $ME"
  say "window:   $WIN"
  if [ -n "$cur" ]; then
    say "topic:    $cur"
    say "mailbox:  $RP/$cur"
    say "neighbours address it as: --project $PROJECT --session $cur"
    echo "eval \"\$(amq env --session $cur --me $ME)\""
  else
    say "topic:    (none claimed — this window is in the shared collab)"
    say "mailbox:  $RP/collab   — shared with every other unclaimed window here"
    say "claim one: amq-use.sh \"<topic>\""
  fi
  exit 0
fi

[ -n "${1:-}" ] || { say "specify a topic: amq-use.sh \"<any wording>\""; exit 2; }
SESSION=$(python3 "$HERE/slug.py" "$1")
[ -d "$RP/$SESSION" ] || ( cd "$DIR" && amq session create "$SESSION" --me "$ME" >/dev/null 2>&1 )
[ -d "$RP/$SESSION" ] || { say "could not create session '$SESSION'"; exit 1; }

printf '%s' "$SESSION" > "$STATE" 2>/dev/null || say "warning: could not write $STATE, the hook will not learn about the topic"
say "window claimed the topic: $SESSION"
say "neighbours should address it as: --session $SESSION"
say ""
say "From here on, NO eval. Always pass --root: amq looks for the root by the current"
say "directory and from a working copy will refuse silently, even with --session given."
say "  amq list  --root $RP/$SESSION --me $ME --new"
say "  amq drain --root $RP/$SESSION --me $ME --include-body --limit 0"
say "  amq reply --root $RP/$SESSION --me $ME --id <id> --kind answer --body ..."
say "  amq send  --root $RP/$SESSION --me $ME --to <recipient> --subject ... --body ..."
say "  neighbour:  ... --to <their-handle> --project <their-project> --session collab"
say "  another window: ... --to $ME --session <their-topic>"
say ""
say "Or pin the context once, if the shell allows it:"
say "  eval \"\$(amq env --session $SESSION --me $ME)\""
# We print the context from the repository ROOT: from a working copy amq env may
# refuse, but claiming the topic does not depend on that — don't spoil the exit code.
( cd "$DIR" && amq env --session "$SESSION" --me "$ME" 2>/dev/null ) || true
exit 0
