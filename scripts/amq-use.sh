#!/usr/bin/env bash
# Claim a topic for THIS window: create a session, record it against the window
# and print the context-pinning line.
#
#   eval "$(~/.claude/skills/agent-mail/scripts/amq-use.sh "api redesign")"
#   eval "$(~/.claude/skills/agent-mail/scripts/amq-use.sh --show)"   # what is claimed now
#   ~/.claude/skills/agent-mail/scripts/amq-use.sh --release           # give the topic back
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
# A pin inherited from the calling shell outranks .amqrc, and `amq session create` takes
# no --root: run from a shell pinned to ANOTHER project, this script would create the
# topic in that project's mailbox and report success. Measured, not theorised. This
# script finds the mailbox itself, from the .amqrc of the repository it was run in, so
# the inherited pin has no business surviving into it.
unset AM_ROOT AM_BASE_ROOT AM_ROOT_ID AM_BASE_ROOT_ID AM_SESSION AM_ME
HERE="$(cd "$(dirname "$0")" && pwd)"
say() { echo "$@" >&2; }

# When the topic was last claimed. The file is written by a claim and by nothing else —
# the hook only reads it — so this is the age of the claim, NOT a sign of life: a window
# idle for a month and a window that died a month ago look identical here. That is why
# nothing expires on its own; see --release.
claim_age() {
  python3 - "$1" <<'PY' 2>/dev/null || printf 'unknown'
import os, sys, time
d = time.time() - os.path.getmtime(sys.argv[1])
n, w = (d // 86400, "day") if d >= 86400 else \
       ((d // 3600, "hour") if d >= 3600 else (d // 60, "minute"))
print("%d %s%s" % (n, w, "" if n == 1 else "s"))
PY
}

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
    say "claimed:  $(claim_age "$STATE") ago"
    say "about:    $(cat "$RP/$cur/.description" 2>/dev/null || echo '(none — set it with --about)')"
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

if [ "${1:-}" = "--release" ]; then
  # Giving a topic up is explicit and nothing else does it. A claim cannot expire on a
  # timer: on disk an idle window is indistinguishable from a dead one, and expiring the
  # quiet one would hand its topic — and its unread mail — to whoever sorts the basket
  # while it is still working. The cost of being explicit is a stale claim; the cost of a
  # timer is lost mail.
  cur=$(cat "$STATE" 2>/dev/null)
  [ -n "$cur" ] || { say "this window has claimed no topic — nothing to release"; exit 0; }
  FORCE=""; [ "${2:-}" = "--force" ] && FORCE=1
  # Only stdout is parsed: amq puts its version banner on stderr.
  N=$( ( cd "$DIR" && amq list --session "$cur" --me "$ME" --new --json 2>/dev/null ) | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(len(d if isinstance(d, list) else d.get("messages", [])))
except Exception:
    print(0)' 2>/dev/null )
  case "$N" in ''|*[!0-9]*) N=0 ;; esac
  if [ "$N" -gt 0 ] && [ -z "$FORCE" ]; then
    say "refusing: $N unread message(s) in '$cur'."
    say "  With nobody on the topic they become ORPHAN — shown to every window, held by"
    say "  none, and answered only if somebody volunteers. Take them first:"
    say "    amq drain --session $cur --me $ME --include-body --limit 0"
    say "  or let them go:  amq-use.sh --release --force"
    exit 2
  fi
  rm -f "$STATE" 2>/dev/null || { say "could not remove $STATE"; exit 1; }
  say "released '$cur' — this window is back in the shared collab"
  [ "$N" -gt 0 ] && say "⚠ $N unread message(s) left behind in '$cur'; they are ORPHAN now"
  say "the topic keeps its mail and its description; re-claim it with:"
  say "  amq-use.sh \"$cur\""
  exit 0
fi

TOPIC=""; ABOUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --about) ABOUT="$2"; shift 2 ;;
    -*) say "unknown argument: $1"; exit 2 ;;
    *) [ -n "$TOPIC" ] || TOPIC="$1"; shift ;;
  esac
done
[ -n "$TOPIC" ] || { say "specify a topic: amq-use.sh \"<any wording>\" --about \"<one line>\""; exit 2; }
SESSION=$(python3 "$HERE/slug.py" "$TOPIC")
DESC="$RP/$SESSION/.description"

# A topic name is a slug. Whoever claims it knows what it is for; nobody else can tell
# from `td-021-refused-read-notice` whether their question belongs there. So the
# description is required when the topic is NEW — that is the only moment the knowledge
# exists — and inherited silently when an existing topic is re-claimed.
if [ ! -d "$RP/$SESSION" ] && [ -z "$ABOUT" ]; then
  say "new topic '$SESSION' needs a description — senders see it when they look you up:"
  say "  amq-use.sh \"$TOPIC\" --about \"<what this window is working on, one line>\""
  exit 2
fi

[ -d "$RP/$SESSION" ] || ( cd "$DIR" && amq session create "$SESSION" --me "$ME" >/dev/null 2>&1 )
[ -d "$RP/$SESSION" ] || { say "could not create session '$SESSION'"; exit 1; }

if [ -n "$ABOUT" ]; then
  printf '%s\n' "$ABOUT" > "$DESC" 2>/dev/null \
    && say "· description saved — senders will see it" \
    || say "warning: could not write $DESC"
elif [ ! -f "$DESC" ]; then
  say "⚠ this topic has no description; senders cannot tell what it is for."
  say "  add one: amq-use.sh \"$TOPIC\" --about \"<one line>\""
fi

printf '%s' "$SESSION" > "$STATE" 2>/dev/null || say "warning: could not write $STATE, the hook will not learn about the topic"
say "window claimed the topic: $SESSION"
say "neighbours should address it as: --session $SESSION"
say ""
say "Reading needs no pin — --session works from any shell:"
say "  amq list  --session $SESSION --me $ME --new"
say "  amq drain --session $SESSION --me $ME --include-body --limit 0"
say ""
say "Sending does need one, and --session is refused without it while --root sends with"
say "an empty return address. Use the wrapper; it pins itself from this claim:"
say "  $HERE/amq-send.sh --to <handle> --project <peer> --session <their-topic> ..."
say "  $HERE/amq-send.sh reply --id <id> --kind answer --body ..."
say "  neighbour:  ... --to <their-handle> --project <their-project> --session collab"
say "  another window: ... --to $ME --session <their-topic>"
say ""
say "Or pin the context once, if the shell allows it:"
say "  eval \"\$(amq env --session $SESSION --me $ME)\""
# We print the context from the repository ROOT: from a working copy amq env may
# refuse, but claiming the topic does not depend on that — don't spoil the exit code.
( cd "$DIR" && amq env --session "$SESSION" --me "$ME" 2>/dev/null ) || true
exit 0
