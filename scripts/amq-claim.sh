#!/usr/bin/env bash
# Claim ONE message from a shared session so that a second window can't take the same one.
#
#   amq-claim.sh <msg_id> [--session collab]
#
# Why: collab is read by every window of the project, and `amq read` gives no sign of
# a claim — two of them can read the very same message. Here the claim is created
# atomically (O_EXCL), so exactly one window wins and the other is told who got there first.


set -uo pipefail

# The mailbox belongs to the REPOSITORY, not to a working copy: --git-common-dir
# from any worktree returns the shared directory that .amqrc sits next to.
# That's why a copy needs neither its own config nor a second install — including
# a copy created after the setup was already done.
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
command -v amq >/dev/null 2>&1 || { echo "amq not found" >&2; exit 1; }

MSG=""; SESSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) MSG="$1"; shift ;;
  esac
done
[ -n "$MSG" ] || { echo "give the message id" >&2; exit 2; }

DIR=$(amq_repo_root) || { echo "project is not connected to agent-mail" >&2; exit 3; }
IFS=$'\t' read -r ROOT ME <<<"$(python3 -c "
import json,sys
c=json.load(open(sys.argv[1]+'/.amqrc'))
print('\t'.join([c.get('root','.agent-mail'), c.get('handle','')]))" "$DIR")"
case "$ROOT" in /*) RP="$ROOT" ;; *) RP="$DIR/$ROOT" ;; esac
[ -n "$ME" ] || { echo "no handle in .amqrc" >&2; exit 3; }
[ -n "$SESSION" ] || SESSION=collab
# Same key as amq-use.sh: the harness session id, terminal only as a last
# resort. A literal "unknown" would make every window outside the app share
# one key, and claims between them would not be separated at all.
WIN="${AMQ_WINDOW:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$WIN" ] || WIN="tty-$(printf '%s' "${TTY:-$(tty 2>/dev/null || echo nowin)}" | shasum | cut -c1-8)"

# The claim. Exactly one winner: O_EXCL on a directory shared by all windows.
OUT=$(MSG="$MSG" RP="$RP" WIN="$WIN" SESSION="$SESSION" python3 <<'PY'
import os, sys, time
rp, msg, win, sess = (os.environ[k] for k in ("RP", "MSG", "WIN", "SESSION"))
d = os.path.join(rp, ".claims")
os.makedirs(d, exist_ok=True)
p = os.path.join(d, sess + "__" + "".join(c if c.isalnum() or c in "-_." else "_" for c in msg))
try:
    fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
except FileExistsError:
    try:
        holder = open(p).read().strip()
    except Exception:
        holder = "unknown"
    print("BUSY\t" + holder)
    raise SystemExit
with os.fdopen(fd, "w") as f:
    f.write("{}\t{}".format(win, time.strftime("%Y-%m-%dT%H:%M:%S")))
print("OK\t" + win)
PY
)
STATE="${OUT%%	*}"; REST="${OUT#*	}"
WHO="${REST%%	*}"          # the record is "window<TAB>time"; keep the window only
if [ "$STATE" = "BUSY" ]; then
  # A claim by THIS window is not a conflict, it is a re-entry: a retried
  # command or a restarted turn must still be able to answer its own message.
  # Only another window's claim is a refusal.
  if [ "$WHO" != "$WIN" ]; then
    echo "message already claimed by window: $WHO — don't reply to it" >&2
    exit 4
  fi
  echo "(already claimed by this window, continuing)" >&2
fi
amq read --root "$RP/$SESSION" --me "$ME" --id "$MSG"
echo
echo "(claimed by window $WIN; reply with: amq reply --id $MSG --kind answer --body \"...\")" >&2
