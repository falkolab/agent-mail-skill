#!/usr/bin/env bash
# Wait for mail and exit the moment it lands, so a window that is standing idle
# finds out about it.
#
#   amq-watch.sh                  # the base root AND this window's topic
#   amq-watch.sh --session <name> # one named topic instead
#   amq-watch.sh --timeout 300    # how long one wait lasts before it is re-armed
#
# Why this exists: the delivery hooks fire on things the WINDOW does — session start,
# a user prompt, the end of a turn. A window where nothing is happening runs no hooks,
# so a message can sit in its mailbox for hours with nobody told. Started as a
# background task, this script is the missing nudge: it blocks until something
# arrives, then exits, and the harness wakes the session to report the exit.
#
# CONSUMES NOTHING: `amq monitor --peek` leaves every message unread. The window still
# picks its mail up itself, with `amq drain`, when it gets round to it.
#
# Three waits, not one, and that is the point. Every scope is watched separately and none
# contains another: `amq monitor` with no --session sees ONLY mail sent without a session,
# `--session collab` only the shared basket, `--session <topic>` only that topic. On a
# scope that has mail the others are blind — 4, exactly as if the mailbox were empty.
# Measured on 0.80.1. A single watcher therefore misses most of the mail while looking
# like it is working, which is the worst way for a notifier to fail.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
# A pin inherited from the calling shell outranks .amqrc and would point every wait below
# at another project's mailbox. This script finds the mailbox itself.
unset AM_ROOT AM_BASE_ROOT AM_ROOT_ID AM_BASE_ROOT_ID AM_SESSION AM_ME

say() { echo "$@" >&2; }

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

TIMEOUT=900; ONE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session) ONE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) say "unknown argument: $1"; exit 2 ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*) say "--timeout takes seconds"; exit 2 ;; esac

command -v amq >/dev/null 2>&1 || { say "amq not found"; exit 1; }
DIR=$(amq_repo_root) || { say "not wired to agent-mail: no .amqrc here or above"; exit 3; }
IFS=$'\t' read -r ROOT ME <<<"$(python3 -c "
import json,sys
c=json.load(open(sys.argv[1]+'/.amqrc'))
print('\t'.join([c.get('root','.agent-mail'), c.get('handle','')]))" "$DIR")"
case "$ROOT" in /*) RP="$ROOT" ;; *) RP="$DIR/$ROOT" ;; esac
[ -n "$ME" ] || { say "no handle in .amqrc — rerun amq-setup-project.sh"; exit 3; }

# The topic this window claimed, keyed the same way amq-use.sh keys it.
WIN="${AMQ_WINDOW:-${CLAUDE_CODE_SESSION_ID:-}}"
MINE=$(cat "$RP/.window-$(printf '%s' "$WIN" | tr -c 'A-Za-z0-9_.-' '_')" 2>/dev/null)

TARGETS=()
if [ -n "$ONE" ]; then TARGETS=("$ONE")
else
  TARGETS=("" "collab")      # "" = mail sent with no session at all; collab = the basket
  # The claimed topic is where anything addressed to this window personally lands.
  [ -n "$MINE" ] && [ "$MINE" != "collab" ] && TARGETS+=("$MINE")
fi

HIT=$(mktemp -d "${TMPDIR:-/tmp}/amq-watch.XXXXXX") || exit 1
PIDS=""
# Job control, so each wait below becomes its own process group and can be killed WITH
# the amq it is blocked on. Killing the subshell alone leaves that amq running: measured
# — one orphaned `amq monitor` survived every watch, and they pile up all day.
set -m
cleanup() {
  for p in $PIDS; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
  rm -rf "$HIT"
}
trap cleanup EXIT INT TERM

# One wait per target. A timeout (4) is not an answer, so it is re-armed; anything else
# is reported and ends the watch, because a wait that fails silently is worse than none.
wait_on() {
  local s="$1" label out rc
  [ -n "$s" ] && label="$s" || label="(root: no session)"
  while :; do
    if [ -n "$s" ]; then out=$(cd "$DIR" && amq monitor --me "$ME" --session "$s" --peek --timeout "${TIMEOUT}s" 2>/dev/null)
    else                 out=$(cd "$DIR" && amq monitor --me "$ME" --peek --timeout "${TIMEOUT}s" 2>/dev/null); fi
    rc=$?
    case $rc in
      0) { echo "MAIL in $label:"; echo "$out"; } > "$HIT/out"; return 0 ;;
      4) continue ;;
      *) { echo "the watch on $label stopped, rc=$rc"; echo "$out"; } > "$HIT/out"; return "$rc" ;;
    esac
  done
}

for t in "${TARGETS[@]}"; do wait_on "$t" & PIDS="$PIDS $!"; done
say "watching: $(for t in "${TARGETS[@]}"; do [ -n "$t" ] && printf '%s ' "$t" || printf '(root) '; done)· nothing is consumed"

# `wait -n` would be the obvious way and needs bash 4.3; macOS still ships 3.2, and this
# skill is handed to other people's machines. Polling a sentinel file costs two seconds
# of latency on an event that is already asynchronous.
while :; do
  [ -f "$HIT/out" ] && break
  alive=""
  for p in $PIDS; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ -n "$alive" ] || break
  sleep 2
done

if [ -f "$HIT/out" ]; then cat "$HIT/out"; exit 0; fi
say "every watch ended without mail"
exit 1
