#!/usr/bin/env bash
# Send or reply from THIS window's topic, so the message carries a usable return address.
#
#   amq-send.sh --to <handle> --project <peer> --session <their-topic> --subject … --body …
#   amq-send.sh reply --id <msg_id> --kind answer --body …
#
# Why this exists. amq-use.sh claims a topic for the HOOK; amq itself is not pinned, and a
# fresh shell is unpinned. From there:
#   amq send --session X   → refused, "--session requires a session context"
#   amq send --root  X     → sent, but reply_to is empty: nobody can answer it
#   pinned to the default root → reply_to says <handle>@collab, naming the wrong window
# The documented `eval "$(amq env …)"` sets the pin, but a worktree guard can refuse it,
# and the pin needs six variables including two opaque ids.
#
# So: this reads the topic this window claimed, builds the pin itself, and execs amq. No
# eval, nothing to remember. Reading (list, drain, peek) does not need it — plain
# `--session <topic>` works unpinned.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"

case "${1:-}" in -h|--help) sed -n '2,20p' "$0"; exit 0 ;; esac
command -v amq >/dev/null 2>&1 || { echo "amq not found in PATH" >&2; exit 1; }

SUB=send
[ "${1:-}" = "reply" ] && { SUB=reply; shift; }
[ "${1:-}" = "send" ] && shift

amq_anchor() {
  local c d
  c=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$c" ]; then
    d="${c%/*}"
    [ -f "$d/.amqrc" ] && { printf '%s' "$d"; return 0; }
    [ -f "$c/.amqrc" ] && { printf '%s' "$c"; return 0; }
    return 1
  fi
  d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.amqrc" ] && { printf '%s' "$d"; return 0; }
    d="${d%/*}"
  done
  return 1
}

ANCHOR=$(amq_anchor) || { echo "not wired to agent-mail: no .amqrc here or above" >&2; exit 1; }
eval "$(ANCHOR="$ANCHOR" python3 - <<'PY'
import json, os, shlex
cfg = json.load(open(os.path.join(os.environ["ANCHOR"], ".amqrc")))
root = cfg.get("root", ".agent-mail")
if not os.path.isabs(root):
    root = os.path.join(os.environ["ANCHOR"], root)
print("RP=" + shlex.quote(root))
print("ME=" + shlex.quote(cfg.get("handle", "")))
PY
)"
[ -n "${ME:-}" ] || { echo "no handle in .amqrc — rerun amq-setup-project.sh" >&2; exit 1; }

WIN="${AMQ_WINDOW:-${CLAUDE_CODE_SESSION_ID:-}}"
MINE=""
[ -n "$WIN" ] && MINE=$(cat "$RP/.window-$(printf '%s' "$WIN" | tr -c 'A-Za-z0-9_.-' '_')" 2>/dev/null)
if [ -z "$MINE" ]; then
  echo "this window has claimed no topic, so a reply could not come back to it." >&2
  echo "  claim one first: $(cd "$(dirname "$0")" && pwd)/amq-use.sh \"<topic>\" --about \"<one line>\"" >&2
  exit 2
fi

# The pin must be the whole set from `amq env`: AM_ROOT alone is refused with
# "root is not the pinned session directory", and a hand-built AM_ROOT_ID with
# "unverifiable AMQ identity pin".
PIN=$(cd "$ANCHOR" && env -u AM_ROOT -u AM_BASE_ROOT -u AM_ROOT_ID -u AM_BASE_ROOT_ID \
        -u AM_SESSION -u AM_ME amq env --session "$MINE" --me "$ME" 2>/dev/null)
[ -n "$PIN" ] || { echo "could not pin to '$MINE' — does the topic still exist?" >&2; exit 1; }

# --strict always: without it a handle absent from the recipient's registry is accepted,
# a phantom inbox appears inside OUR OWN mailbox, "Sent" is printed and nothing arrives.
STRICT=--strict
for a in "$@"; do [ "$a" = "--strict" ] && STRICT=""; done
[ "$SUB" = "reply" ] && STRICT=""

( eval "$PIN"; exec amq "$SUB" --me "$ME" ${STRICT:+$STRICT} "$@" )
