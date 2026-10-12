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
# A pin inherited from the calling shell outranks .amqrc, and the amq calls below take
# no --root of their own: run from a shell pinned to ANOTHER project, they would act on
# that project's mailbox and report success. This script finds the mailbox itself, from
# the .amqrc of the repository it was given; the inherited pin must not survive into it.
unset AM_ROOT AM_BASE_ROOT AM_ROOT_ID AM_BASE_ROOT_ID AM_SESSION AM_ME
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
# Find the message before claiming anything. This used to default to collab and read
# from "$RP/collab" whatever the id was — so a message sent with no session, which lives
# in the base root, could not be read at all. The claim was written first and never
# withdrawn, so the read failed, the script still said "claimed", and the message stayed
# unread behind a claim no window could ever release. One sat like that for eleven days.
SCOPE=""; SCOPE_ROOT=""
find_scope() {
  local d b s
  if [ -n "$SESSION" ]; then                       # an explicit --session is an answer
    [ "$SESSION" = "(root)" ] || [ "$SESSION" = "root" ] \
      && { SCOPE="root"; SCOPE_ROOT="$RP"; } \
      || { SCOPE="$SESSION"; SCOPE_ROOT="$RP/$SESSION"; }
    return 0
  fi
  for b in new cur; do
    [ -f "$RP/agents/$ME/inbox/$b/$MSG.md" ] && { SCOPE="root"; SCOPE_ROOT="$RP"; return 0; }
  done
  for d in "$RP"/*/; do
    [ -d "$d" ] || continue
    s=${d%/}; s=${s##*/}
    case "$s" in meta|threads|agents) continue ;; esac
    for b in new cur; do
      [ -f "${d}agents/$ME/inbox/$b/$MSG.md" ] && { SCOPE="$s"; SCOPE_ROOT="${d%/}"; return 0; }
    done
  done
  return 1
}
find_scope || {
  echo "no message $MSG in this mailbox (looked in the root and every session)" >&2
  echo "  $RP" >&2
  exit 3
}
SESSION="$SCOPE"
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
# The read is what makes the claim mean anything. If it fails, the claim must go with
# it — otherwise the message is locked to a window that never got it. Only a claim THIS
# run created is withdrawn; one we merely re-entered belongs to an earlier run.
# Status taken from the command itself: inside `if ! cmd`, $? is the NEGATED status, so
# a failed read reported 0 and the script went on claiming success — the very thing being
# fixed here.
amq read --root "$SCOPE_ROOT" --me "$ME" --id "$MSG"; rc=$?
if [ "$rc" -ne 0 ]; then
  [ "$STATE" = "OK" ] && rm -f "$RP/.claims/${SESSION}__$(printf '%s' "$MSG" | tr -c 'A-Za-z0-9._-' '_')" 2>/dev/null
  echo "could not read $MSG from $SCOPE_ROOT (rc=$rc); the claim was withdrawn" >&2
  exit "$rc"
fi
echo
echo "(claimed by window $WIN from ${SCOPE}; reply with:" >&2
echo "   $(cd "$(dirname "$0")" && pwd)/amq-send.sh reply --id $MSG --kind answer --body \"...\")" >&2
