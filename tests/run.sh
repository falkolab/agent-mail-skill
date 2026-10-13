#!/usr/bin/env bash
# The skill's own test suite. Every case here is either a claim the documentation makes
# or a defect that reached a live mailbox; a defect gets a case so that the next change
# breaks a test instead of somebody's correspondence.
#
#   tests/run.sh            # everything
#   tests/run.sh claim      # only cases whose name contains "claim"
#
# It runs against disposable mailboxes under a fresh temp directory and never touches a
# real one: every case starts from an empty tree, and AM_* is cleared so an inherited pin
# cannot drag the run into somebody's project.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
unset AM_ROOT AM_BASE_ROOT AM_ROOT_ID AM_BASE_ROOT_ID AM_SESSION AM_ME AMQ_WINDOW CLAUDE_CODE_SESSION_ID

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../scripts"
FILTER="${1:-}"
PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=""

command -v amq >/dev/null 2>&1 || { echo "amq not found; nothing to test against" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/amq-skill-tests.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
echo "amq $(amq --version 2>/dev/null | head -1) · scripts $S"
echo

# ── helpers ──────────────────────────────────────────────────────────────
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
    $CASE: $1"; printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || no "$1" "expected [$3], got [$2]"; }
isnt() { [ "$2" != "$3" ] && ok "$1" || no "$1" "expected anything but [$3]"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "no [$3] in: $(printf '%s' "$2" | head -3 | tr '\n' ' ' | cut -c1-120)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1" "unexpected [$3]" ;; *) ok "$1" ;; esac; }
count(){ ls "$1" 2>/dev/null | wc -l | tr -d ' '; }

# A disposable project: git repo, mailbox, .amqrc. $1 = name, $2.. = peers "name:path"
mk() {
  local n="$1"; shift
  # Per case, not per name: the first cut of this suite put every project at $TMP/<name>,
  # so mail from one case was still lying in the next one's mailbox and four cases failed
  # on each other's leavings. A test that shares state does not test what it says.
  local d="$TMP/$(printf '%s' "$CASE" | tr -c 'A-Za-z0-9' '_')/$n"
  mkdir -p "$d" && ( cd "$d" && git init -q . ) || return 1
  ( cd "$d" && amq coop init --root .agent-mail --agents "$n-claude,user" >/dev/null 2>&1 )
  local peers="{}"
  if [ $# -gt 0 ]; then
    peers="{"
    local first=1 p
    for p in "$@"; do
      [ $first -eq 1 ] || peers="$peers,"
      first=0
      peers="$peers\"${p%%:*}\":\"${p#*:}\""
    done
    peers="$peers}"
  fi
  printf '{"root":".agent-mail","project":"%s","handle":"%s-claude","peers":%s}\n' "$n" "$n" "$peers" > "$d/.amqrc"
  printf '%s' "$d"
}

# Put a message straight into a scope, without going through the code under test.
# --root works from an unpinned shell, which is the point: seeding must not depend on
# the behaviour a case is about to check.
seed() {  # seed <mailbox-root> <scope|""> <handle> <subject> <body>
  local rp="$1" scope="$2" me="$3" subj="$4" body="$5" root="$1"
  [ -n "$scope" ] && root="$rp/$scope"
  amq send --me "$me" --root "$root" --to "$me" --allow-self --subject "$subj" --body "$body" >/dev/null 2>&1
}
last_id() { ls "$1" 2>/dev/null | sed 's/\.md$//' | tail -1; }

run_case() {
  CASE="$1"
  case "$CASE" in *"$FILTER"*) ;; *) SKIP=$((SKIP+1)); return 0 ;; esac
  printf '%s\n' "$CASE"
  "case_$2"
  echo
}

# ── cases ────────────────────────────────────────────────────────────────

# A foreign pin in the environment outranks .amqrc, and `amq session create` takes no
# --root, so an unguarded script created topics in somebody else's mailbox and said
# "created". Three scripts had this.
case_pin_leak() {
  local a b
  a=$(mk pa); b=$(mk pb)
  ( cd "$a" && AM_ROOT="$b/.agent-mail/collab" AM_BASE_ROOT="$b/.agent-mail" \
      AM_SESSION=collab AM_ME=pb-claude AMQ_WINDOW=w1 \
      "$S/amq-use.sh" "leak probe" --about x >/dev/null 2>&1 )
  is "topic lands in this project" "$([ -d "$a/.agent-mail/leak-probe" ] && echo yes || echo no)" "yes"
  is "and not in the pinned one"   "$([ -d "$b/.agent-mail/leak-probe" ] && echo yes || echo no)" "no"
}

# Claiming a topic, its description, the claim file, and the age shown by --show.
case_use_claim() {
  local a out
  a=$(mk pa)
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" "api redesign" 2>&1 )
  has "a new topic demands a description" "$out" "needs a description"
  is  "and nothing was created" "$([ -d "$a/.agent-mail/api-redesign" ] && echo yes || echo no)" "no"
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" "api redesign" --about "what this window does" 2>&1 )
  has "claimed with a description" "$out" "window claimed the topic: api-redesign"
  has "and says to arm the watcher" "$out" "ARM THE WATCHER"
  is  "the claim names the topic" "$(cat "$a/.agent-mail/.window-w1" 2>/dev/null)" "api-redesign"
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" --show 2>&1 )
  has "--show prints the topic" "$out" "topic:    api-redesign"
  has "--show prints the age"   "$out" "claimed:"
  has "--show prints the description" "$out" "what this window does"
}

# Releasing: refused while mail is unread, --force lets go, the mail stays put.
case_use_release() {
  local a out rc
  a=$(mk pa)
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" "topic one" --about x >/dev/null 2>&1 )
  out=$( cd "$a" && AMQ_WINDOW=w9 "$S/amq-use.sh" --release 2>&1 ); rc=$?
  has "a window with no claim is told so" "$out" "claimed no topic"
  is  "and that is not an error" "$rc" "0"
  seed "$a/.agent-mail" "topic-one" "pa-claude" s "b"
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" --release 2>&1 ); rc=$?
  is  "refused while mail is unread" "$rc" "2"
  has "and says what to do first" "$out" "amq drain --session topic-one"
  is  "the claim is still there" "$(cat "$a/.agent-mail/.window-w1" 2>/dev/null)" "topic-one"
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" --release --force 2>&1 ); rc=$?
  is  "--force releases" "$rc" "0"
  has "and says what it left behind" "$out" "left behind"
  is  "the claim is gone" "$([ -f "$a/.agent-mail/.window-w1" ] && echo yes || echo no)" "no"
  is  "the mail is untouched" "$(count "$a/.agent-mail/topic-one/agents/pa-claude/inbox/new")" "1"
}

# The empty return address: a send that arrives with nowhere to reply to.
case_send_reply_to() {
  local a b out f
  b=$(mk pb); a=$(mk pa "pb:$b/.agent-mail")
  printf '{"root":".agent-mail","project":"pb","handle":"pb-claude","peers":{"pa":"%s/.agent-mail"}}\n' "$a" > "$b/.amqrc"
  ( cd "$b" && AMQ_WINDOW=w2 "$S/amq-use.sh" "their topic" --about x >/dev/null 2>&1 )
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" "my topic" --about x >/dev/null 2>&1 )
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-send.sh" --to pb-claude --project pb --session their-topic \
           --subject s --body "hello" 2>&1 )
  has "the send reports delivery" "$out" "Sent"
  f="$b/.agent-mail/their-topic/agents/pb-claude/inbox/new/$(last_id "$b/.agent-mail/their-topic/agents/pb-claude/inbox/new").md"
  local fm
  fm=$(python3 -c "
import json,sys
t=open(sys.argv[1],encoding='utf-8').read()
d=json.loads(t.split('---json',1)[1].split('\n---',1)[0])
print('%s|%s|%s' % (d.get('reply_to'), d.get('from_project'), d.get('thread')))" "$f" 2>/dev/null)
  is  "reply_to names the sender's topic" "${fm%%|*}" "pa-claude@my-topic"
  has "from_project is filled in" "$fm" "|pa|"
  has "the thread names both topics" "$fm" "pa:my-topic:pa-claude__pb:their-topic:pb-claude"
}

# Claiming a message: it has to be looked for, not guessed at. A message with no session
# lives in the base root, and assuming collab made it unreadable AND left a claim behind.
case_claim_scopes() {
  local a id out rc
  a=$(mk pa)
  ( cd "$a" && amq session create topic-a --me pa-claude >/dev/null 2>&1 )
  seed "$a/.agent-mail" ""        "pa-claude" rootmsg   "body-ROOT"
  seed "$a/.agent-mail" "collab"  "pa-claude" collabmsg "body-COLLAB"
  seed "$a/.agent-mail" "topic-a" "pa-claude" topicmsg  "body-TOPIC"

  id=$(last_id "$a/.agent-mail/agents/pa-claude/inbox/new")
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-claim.sh" "$id" 2>&1 ); rc=$?
  is  "a root-level message is claimed" "$rc" "0"
  has "and its body is printed" "$out" "body-ROOT"
  is  "and it leaves the inbox" "$(count "$a/.agent-mail/agents/pa-claude/inbox/new")" "0"

  id=$(last_id "$a/.agent-mail/collab/agents/pa-claude/inbox/new")
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-claim.sh" "$id" 2>&1 ); rc=$?
  is  "a collab message is claimed" "$rc" "0"
  has "and its body is printed" "$out" "body-COLLAB"

  id=$(last_id "$a/.agent-mail/topic-a/agents/pa-claude/inbox/new")
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-claim.sh" "$id" 2>&1 ); rc=$?
  is  "a topic message is claimed" "$rc" "0"
  has "and its body is printed" "$out" "body-TOPIC"
}

# A claim that outlives a failed read locks the message to a window that never got it.
case_claim_failed_read() {
  local a id rc
  a=$(mk pa)
  ( cd "$a" && amq session create topic-a --me pa-claude >/dev/null 2>&1 )
  seed "$a/.agent-mail" "topic-a" "pa-claude" m "body-X"
  id=$(last_id "$a/.agent-mail/topic-a/agents/pa-claude/inbox/new")
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-claim.sh" "$id" --session collab >/dev/null 2>&1 ); rc=$?
  isnt "a read from the wrong scope fails" "$rc" "0"
  is  "the claim it made is withdrawn" "$(ls "$a/.agent-mail/.claims" 2>/dev/null | grep -c "$id")" "0"
  is  "the message is still unread" "$(count "$a/.agent-mail/topic-a/agents/pa-claude/inbox/new")" "1"
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-claim.sh" "$id" >/dev/null 2>&1 ); rc=$?
  is  "and the next attempt succeeds" "$rc" "0"
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-claim.sh" nosuchid >/dev/null 2>&1 ); rc=$?
  is  "an id that is nowhere is refused" "$rc" "3"
  is  "without claiming anything" "$(ls "$a/.agent-mail/.claims" 2>/dev/null | grep -c nosuchid)" "0"
}

# Looking at a message must not take it, including one in the base root.
case_peek() {
  local a id out
  a=$(mk pa)
  seed "$a/.agent-mail" "" "pa-claude" m "body-PEEK"
  id=$(last_id "$a/.agent-mail/agents/pa-claude/inbox/new")
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-peek.sh" "$id" --lines 0 2>&1 )
  has "the body is shown" "$out" "body-PEEK"
  has "the root is named as the topic" "$out" "(root)"
  is  "and nothing was consumed" "$(count "$a/.agent-mail/agents/pa-claude/inbox/new")" "1"
}

# The watcher must wake on what ARRIVES. Exiting on anything unread meant one stale
# message disabled it for good, while the window looked covered.
case_watch_census() {
  local a out pid
  a=$(mk pa)
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" "topic one" --about x >/dev/null 2>&1 )
  # in the basket, not in this window's topic: own unread mail is a refusal, tested separately
  seed "$a/.agent-mail" "collab" "pa-claude" old "body-OLD"
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-watch.sh" --interval 1 --timeout 6 > "$TMP/w.out" 2>&1 ) &
  pid=$!
  sleep 3
  is "it is still waiting despite old mail" "$(kill -0 $pid 2>/dev/null && echo alive || echo gone)" "alive"
  has "and says what it is ignoring" "$(cat "$TMP/w.out")" "already unread"
  seed "$a/.agent-mail" "topic-one" "pa-claude" new "body-NEW"
  wait $pid; local rc=$?
  out=$(cat "$TMP/w.out")
  is  "a new message ends the wait" "$rc" "0"
  has "and is reported" "$out" "MAIL in topic-one"
  has "with a request for a successor" "$out" "Start one"
  is  "nothing was consumed" "$(count "$a/.agent-mail/topic-one/agents/pa-claude/inbox/new")" "1"
  is  "and neither was the basket" "$(count "$a/.agent-mail/collab/agents/pa-claude/inbox/new")" "1"
}

# A watcher started over the window's own unread mail is deaf by construction: that mail
# is in its census and can never wake it. A window did exactly this and then stood there
# with four of its own messages unread and a watcher that looked healthy.
case_watch_backlog() {
  local a out rc
  a=$(mk pa)
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" "topic one" --about x >/dev/null 2>&1 )
  seed "$a/.agent-mail" "topic-one" "pa-claude" mine "body-MINE"
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-watch.sh" --interval 1 --timeout 4 2>&1 ); rc=$?
  is  "it refuses over your own unread mail" "$rc" "6"
  has "and says how to clear it" "$out" "amq drain --session topic-one"
  has "and how to override" "$out" "--ignore-backlog"
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-watch.sh" --interval 1 --timeout 2 --ignore-backlog 2>&1 ); rc=$?
  is  "--ignore-backlog starts anyway" "$rc" "4"
  has "and still names the backlog" "$out" "already unread"
  ( cd "$a" && amq drain --session topic-one --me pa-claude --limit 0 >/dev/null 2>&1 )
  seed "$a/.agent-mail" "collab" "pa-claude" theirs "body-THEIRS"
  out=$( cd "$a" && AMQ_WINDOW=w1 "$S/amq-watch.sh" --interval 1 --timeout 2 2>&1 ); rc=$?
  is  "but the basket alone does not stop it" "$rc" "4"
}

# The hook is what every window reads every turn; its branches are the contract.
case_hook() {
  local a out
  a=$(mk pa)
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" "topic one" --about x >/dev/null 2>&1 )
  out=$( printf '{"cwd":"%s","session_id":"w1"}' "$a" | "$S/amq-hook.sh" prompt 2>&1 )
  is  "an empty mailbox says nothing" "$(printf '%s' "$out" | grep -c 'unread:')" "0"
  seed "$a/.agent-mail" "topic-one" "pa-claude" m "b"
  out=$( printf '{"cwd":"%s","session_id":"w1"}' "$a" | "$S/amq-hook.sh" prompt 2>&1 )
  has "own-topic mail is YOURS" "$out" "YOURS"
  has "with a drain by session, not by root" "$out" "amq drain --session topic-one"
  hasnt "and never a drain by root" "$out" "amq drain --root"
  has "and a reply through the wrapper" "$out" "amq-send.sh reply"
  has "and the re-arm reminder" "$out" "arm a new watcher"
  seed "$a/.agent-mail" "" "pa-claude" m2 "b"
  out=$( printf '{"cwd":"%s","session_id":"w1"}' "$a" | "$S/amq-hook.sh" prompt 2>&1 )
  has "root-level mail is surfaced" "$out" "(root)"
}

# A claim nobody renews keeps its topic looking owned, so the mail inside it is filed as
# another window's and never surfaces. The hook has to say the claim is old.
case_hook_stale_claim() {
  local a out
  a=$(mk pa)
  ( cd "$a" && AMQ_WINDOW=w1 "$S/amq-use.sh" "their topic" --about x >/dev/null 2>&1 )
  touch -t 202001010000 "$a/.agent-mail/.window-w1"
  seed "$a/.agent-mail" "their-topic" "pa-claude" m "b"
  seed "$a/.agent-mail" "collab" "pa-claude" m2 "b"
  out=$( printf '{"cwd":"%s","session_id":"w2"}' "$a" | "$S/amq-hook.sh" prompt 2>&1 )
  has "the stale claim is named" "$out" "has not been renewed"
  has "with the file that holds it" "$out" ".window-w1"
  # and with nothing else to report, it still says so instead of going silent
  ( cd "$a" && amq drain --session collab --me pa-claude --limit 0 >/dev/null 2>&1 )
  out=$( printf '{"cwd":"%s","session_id":"w2"}' "$a" | "$S/amq-hook.sh" prompt 2>&1 )
  has "and it is not silent when that is all there is" "$out" "held by a claim"
}

# Facts about amq itself that the scripts are built on. If a new amq changes one of
# these, the skill is wrong before any of its own code is.
case_amq_scopes() {
  local a
  a=$(mk pa)
  ( cd "$a" && amq session create topic-a --me pa-claude >/dev/null 2>&1 )
  seed "$a/.agent-mail" "collab" "pa-claude" m "b"
  ( cd "$a" && amq monitor --me pa-claude --peek --timeout 2s >/dev/null 2>&1 )
  is "the root scope does not see collab" "$?" "4"
  ( cd "$a" && amq monitor --me pa-claude --session collab --peek --timeout 2s >/dev/null 2>&1 )
  is "collab sees its own" "$?" "0"
  ( cd "$a" && amq monitor --me pa-claude --session topic-a --peek --timeout 2s >/dev/null 2>&1 )
  is "a topic does not see collab" "$?" "4"
  ( cd "$a" && amq list --session collab --me pa-claude --new >/dev/null 2>&1 )
  is "list --session works unpinned" "$?" "0"
  ( cd "$a" && amq send --me pa-claude --to pa-claude --session topic-a --allow-self --body x >/dev/null 2>&1 )
  isnt "send --session is refused unpinned" "$?" "0"
}

run_case "pin inherited from the caller"        pin_leak
run_case "claiming a topic"                     use_claim
run_case "releasing a topic"                    use_release
run_case "a send that can be answered"          send_reply_to
run_case "claiming a message in any scope"      claim_scopes
run_case "a claim whose read failed"            claim_failed_read
run_case "looking without taking"               peek
run_case "the watcher wakes on arrivals only"   watch_census
run_case "a watcher over your own backlog"      watch_backlog
run_case "what the hook tells a window"         hook
run_case "a claim nobody renewed"               hook_stale_claim
run_case "amq's own behaviour"                  amq_scopes

printf '%s\n' "----"
printf 'passed %s, failed %s%s\n' "$PASS" "$FAIL" "$([ "$SKIP" -gt 0 ] && echo ", $SKIP case(s) filtered out")"
[ "$FAIL" -eq 0 ] || { printf 'failures:%s\n' "$FAILED_NAMES"; exit 1; }
