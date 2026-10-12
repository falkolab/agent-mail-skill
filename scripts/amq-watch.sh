#!/usr/bin/env bash
# Wait for mail that arrives FROM NOW ON and exit the moment it lands, so a window
# standing idle finds out about it.
#
#   amq-watch.sh                    # mail with no session, collab, and this window's topic
#   amq-watch.sh --session <name>   # one named topic instead
#   amq-watch.sh --interval 5       # how often the mailbox is looked at (default 3s)
#   amq-watch.sh --timeout 3600     # give up after this long (default: wait forever)
#
# Why this exists: the delivery hooks fire on things the WINDOW does — session start, a
# user prompt, the end of a turn. A window where nothing is happening runs no hooks, so a
# message can sit in its mailbox for hours with nobody told. Started as a background task,
# this is the missing nudge: it blocks until something NEW arrives, then exits, and the
# harness wakes the session to report the exit.
#
# "NEW" is the whole point, and the first version got it wrong. `amq monitor` returns on
# any unread message, not only on one that arrived after it started — so a single old
# ORPHAN left in the root or in collab made the watcher exit instantly, every time, for
# good. The window looked covered and was not; restarting changed nothing. So this takes a
# census of what is already unread and waits for something outside it.
#
# CONSUMES NOTHING, and runs no subprocess in the loop: it reads the inbox directories the
# way amq-peek.sh reads a message, so the cost of waiting is one directory listing per
# scope per interval, whatever the size of the mailbox.
#
# Three scopes, because none of them contains the others: mail sent with no session at
# all, the shared collab, and this window's own topic.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
# A pin inherited from the calling shell outranks .amqrc and would point this at another
# project's mailbox. The mailbox is found here, from the repository's own .amqrc.
unset AM_ROOT AM_BASE_ROOT AM_ROOT_ID AM_BASE_ROOT_ID AM_SESSION AM_ME

say() { echo "$@" >&2; }

# Resolved before anything else: $0 may be relative to the caller's directory, and the
# re-arm line below has to be a command that can be run as printed.
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"

# The mailbox belongs to the REPOSITORY, not to a working copy: --git-common-dir from any
# worktree returns the common directory, and .amqrc sits next to it.
amq_repo_root() {
  local start="${1:-$PWD}" c d
  c=$(git -C "$start" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$c" ]; then
    d="${c%/*}"
    [ -f "$d/.amqrc" ] && { printf '%s' "$d"; return 0; }
    [ -f "$c/.amqrc" ] && { printf '%s' "$c"; return 0; }   # bare repository
    return 1
  fi
  d="$start"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.amqrc" ] && { printf '%s' "$d"; return 0; }
    d="${d%/*}"
  done
  return 1
}

INTERVAL=3; LIMIT=0; ONE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)  ONE="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout)  LIMIT="$2"; shift 2 ;;
    -h|--help)  sed -n '2,8p' "$0"; exit 0 ;;
    *) say "unknown argument: $1"; exit 2 ;;
  esac
done
case "$INTERVAL" in ''|*[!0-9]*|0) say "--interval takes whole seconds, at least 1"; exit 2 ;; esac
case "$LIMIT" in ''|*[!0-9]*) say "--timeout takes whole seconds (0 = no limit)"; exit 2 ;; esac

DIR=$(amq_repo_root) || { say "not wired to agent-mail: no .amqrc here or above"; exit 3; }
IFS=$'\t' read -r ROOT ME <<<"$(python3 -c "
import json,sys
c=json.load(open(sys.argv[1]+'/.amqrc'))
print('\t'.join([c.get('root','.agent-mail'), c.get('handle','')]))" "$DIR")"
case "$ROOT" in /*) RP="$ROOT" ;; *) RP="$DIR/$ROOT" ;; esac
[ -n "$ME" ] || { say "no handle in .amqrc — rerun amq-setup-project.sh"; exit 3; }

# The topic this window claimed, keyed the way amq-use.sh keys it.
WIN="${AMQ_WINDOW:-${CLAUDE_CODE_SESSION_ID:-}}"
MINE=$(cat "$RP/.window-$(printf '%s' "$WIN" | tr -c 'A-Za-z0-9_.-' '_')" 2>/dev/null)

# Scope name -> the inbox directory holding its unread mail. A session's mail lives under
# <root>/<session>/, and session-less mail directly under <root>/ — the layout amq-peek.sh
# relies on too.
NAMES=(); DIRS=()
add_scope() {
  NAMES+=("$1")
  [ -n "$2" ] && DIRS+=("$RP/$2/agents/$ME/inbox/new") || DIRS+=("$RP/agents/$ME/inbox/new")
}
if [ -n "$ONE" ]; then add_scope "$ONE" "$ONE"
else
  add_scope "(no session)" ""
  add_scope "collab" "collab"
  [ -n "$MINE" ] && [ "$MINE" != "collab" ] && add_scope "$MINE" "$MINE"
fi

ids_in() { ls "$1" 2>/dev/null | grep '\.md$' || true; }

# A watcher is spent once it has fired: it cannot start its own successor, because the
# wake comes from the harness reporting the exit of a task the AGENT started, and a
# process forked from here has no way back into the session. So the last thing it does is
# ask for one — here, in the output that is certainly read, at the moment it is true. The
# hook says the same, but the hook is silent on an empty inbox, and by the time the turn
# ends the mail is usually collected: the window would be told to re-arm only by accident.
rearm() {
  say ""
  say "This watcher has fired and is gone. Until another is running, this window hears"
  say "nothing while it stands still. Start one — BACKGROUND task (run_in_background):"
  say "  $SELF$REARM_ARGS"
}

# The census. Everything already unread is NOT a reason to wake: it was here before the
# wait began, and whatever it is, it is not the answer this window is waiting for.
BASE=""; PRIOR=0; PRIOR_MINE=0
i=0
while [ $i -lt ${#DIRS[@]} ]; do
  for f in $(ids_in "${DIRS[$i]}"); do
    BASE="$BASE|$i:$f"
    PRIOR=$((PRIOR+1))
    [ "${NAMES[$i]}" = "$MINE" ] && PRIOR_MINE=$((PRIOR_MINE+1))
  done
  i=$((i+1))
done

# The same watch, spelled out, so re-arming does not quietly narrow or widen it.
REARM_ARGS=""
[ -n "$ONE" ] && REARM_ARGS="$REARM_ARGS --session $ONE"
[ "$INTERVAL" != "3" ] && REARM_ARGS="$REARM_ARGS --interval $INTERVAL"
[ "$LIMIT" != "0" ] && REARM_ARGS="$REARM_ARGS --timeout $LIMIT"

say "watching: $(printf '%s ' "${NAMES[@]}")· every ${INTERVAL}s · nothing is consumed"
if [ "$PRIOR" -gt 0 ]; then
  say "· $PRIOR message(s) were already unread when this started; they will NOT wake you."
  if [ "$PRIOR_MINE" -gt 1 ]; then
    say "  $PRIOR_MINE of them are in your own topic — read those now, they are yours."
  elif [ "$PRIOR_MINE" -eq 1 ]; then
    say "  One of them is in your own topic — read it now, it is yours."
  else
    say "  Nothing of yours among them; the rest is for whoever sorts the basket."
  fi
fi

WAITED=0
while :; do
  sleep "$INTERVAL"
  i=0
  while [ $i -lt ${#DIRS[@]} ]; do
    for f in $(ids_in "${DIRS[$i]}"); do
      case "$BASE" in
        *"|$i:$f"*) ;;                      # was already there — not a wake reason
        *)
          say "MAIL in ${NAMES[$i]}:"
          python3 - "${DIRS[$i]}/$f" <<'PY' 2>/dev/null || echo "  ${f%.md}"
import json, sys
t = open(sys.argv[1], encoding="utf-8").read()
fm = json.loads(t.split("---json", 1)[1].split("\n---", 1)[0]) if "---json" in t else {}
def s(v, n=120):
    v = " ".join(str(v if v is not None else "").split())
    return (v[:n] + "…") if len(v) > n else v
print("  from:    %s%s" % (s(fm.get("from")),
      (" (project %s)" % s(fm.get("from_project"))) if fm.get("from_project") else ""))
print("  subject: %s" % s(fm.get("subject") or "(no subject)"))
print("  kind:    %s    priority: %s" % (s(fm.get("kind") or "-"), s(fm.get("priority") or "-")))
print("  id:      %s" % s(fm.get("id") or ""))
PY
          rearm
          exit 0 ;;
      esac
    done
    i=$((i+1))
  done
  WAITED=$((WAITED+INTERVAL))
  if [ "$LIMIT" -gt 0 ] && [ "$WAITED" -ge "$LIMIT" ]; then
    say "nothing new in ${LIMIT}s"
    rearm
    exit 4
  fi
done
