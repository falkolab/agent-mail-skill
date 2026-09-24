#!/usr/bin/env bash
# Forward a message you took by mistake to the topic that actually owns it.
#
#   amq-return.sh <id> --to <topic> [--note "<one line>"]
#
# Why this exists: reading a message CONSUMES it, and amq has no reverse operation —
# nothing puts it back into the unread box. Moving the file by hand would return it to
# everyone sharing that mailbox, including the window that already read it. So the only
# honest repair is a copy into the addressee's topic, carrying the original thread,
# labels and kind so the trail does not break.
#
# Run it from inside the repository. The message must already be in your read box
# (that is the situation this command is for).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"

MSG=""; TO=""; NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to)   TO="$2"; shift 2 ;;
    --note) NOTE="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *)  MSG="$1"; shift ;;
  esac
done
[ -n "$MSG" ] && [ -n "$TO" ] || { echo "usage: amq-return.sh <id> --to <topic>" >&2; exit 2; }
command -v amq >/dev/null 2>&1 || { echo "amq not found in PATH" >&2; exit 1; }

# The mailbox belongs to the repository, exactly as the hook resolves it.
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "not inside a git repository — run this from the repo that holds the mailbox" >&2; exit 1; }
PARENT=$(dirname "$COMMON")
for c in "$PARENT" "$COMMON"; do
  [ -f "$c/.amqrc" ] && { ANCHOR="$c"; break; }
done
[ -n "${ANCHOR:-}" ] || { echo "no .amqrc found for this repository" >&2; exit 1; }

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
[ -n "${ME:-}" ] || { echo "no handle in .amqrc — re-run amq-setup-project.sh" >&2; exit 1; }

# Find the message among the sessions of this mailbox and read back the fields that
# --thread and --labels have to reproduce. Without them amq starts a fresh thread and
# drops the labels, which is exactly the broken trail this command exists to avoid.
FOUND=$(MSG="$MSG" RP="$RP" ME="$ME" python3 - <<'PY'
import json, os, subprocess, sys
rp, me, want = os.environ["RP"], os.environ["ME"], os.environ["MSG"]
try:
    names = [d for d in os.listdir(rp) if os.path.isdir(os.path.join(rp, d))
             and d not in ("meta", "threads")]
except OSError:
    sys.exit(0)
for s in names:
    for box in ("--cur", "--new"):
        try:
            out = subprocess.run(
                ["amq", "list", "--root", os.path.join(rp, s), "--me", me, box, "--json"],
                capture_output=True, text=True, timeout=20)
            rows = json.loads(out.stdout or "[]")
        except Exception:
            continue
        for m in rows:
            if str(m.get("id")) == want:
                print(json.dumps({
                    "session": s, "box": box.lstrip("-"),
                    "thread": m.get("thread") or "",
                    "labels": ",".join(m.get("labels") or []),
                    "kind": m.get("kind") or "question",
                    "subject": m.get("subject") or "(no subject)",
                    "frm": m.get("from") or "?",
                    "path": m.get("path") or "",
                }, ensure_ascii=False))
                sys.exit(0)
PY
)
[ -n "$FOUND" ] || { echo "message $MSG not found in $RP" >&2; exit 3; }

eval "$(FOUND="$FOUND" python3 -c '
import json, os, shlex
d = json.loads(os.environ["FOUND"])
for k in ("session", "box", "thread", "labels", "kind", "subject", "frm", "path"):
    print("M_%s=%s" % (k.upper(), shlex.quote(str(d[k]))))')"

# The body lives in the file: amq list does not return it, and re-reading through
# `amq read` would consume a message that is still unread in the --new case.
# The sender's own project comes from the message frontmatter, not from ours: the
# addressee needs it to reply, and substituting our project name would send them to
# the wrong place.
BODY=$(M_PATH="$M_PATH" python3 -c '
import os, sys
p = os.environ.get("M_PATH") or ""
if not p or not os.path.exists(p):
    sys.exit(0)
txt = open(p, encoding="utf-8", errors="replace").read()
sys.stdout.write(txt.partition("---json")[2].partition("\n---")[2].lstrip("\n"))')
[ -n "$BODY" ] || BODY="(body could not be read from disk — see the original, id $MSG)"

FROM_PROJECT=$(M_PATH="$M_PATH" python3 -c '
import json, os, sys
p = os.environ.get("M_PATH") or ""
if not p or not os.path.exists(p):
    sys.exit(0)
try:
    h = json.loads(open(p, encoding="utf-8", errors="replace").read()
                   .partition("---json")[2].partition("\n---")[0])
except Exception:
    sys.exit(0)
sys.stdout.write(str(h.get("from_project") or h.get("reply_project") or ""))')

ORIGIN="$M_FRM"
[ -n "$FROM_PROJECT" ] && ORIGIN="$M_FRM@$FROM_PROJECT"
TRAIL="— forwarded by $ME. Original: from $ORIGIN, id $MSG, topic $M_SESSION."
[ -n "$NOTE" ] && TRAIL="$TRAIL
$NOTE"

set -- amq send --root "$RP/$TO" --me "$ME" --to "$ME" --allow-self \
  --kind "$M_KIND" --subject "Forwarded: $M_SUBJECT" \
  --body "$BODY

$TRAIL"
[ -n "$M_THREAD" ] && set -- "$@" --thread "$M_THREAD"
[ -n "$M_LABELS" ] && set -- "$@" --labels "$M_LABELS"

if out=$("$@" 2>&1); then
  echo "forwarded to topic '$TO': $M_SUBJECT"
  echo "  thread and labels preserved; the original stays read in '$M_SESSION'"
  if [ -n "$FROM_PROJECT" ]; then
    echo "  the addressee replies to the ORIGINAL sender: --to $M_FRM --project $FROM_PROJECT"
  else
    echo "  the addressee replies to the ORIGINAL sender: --to $M_FRM (same project)"
  fi
else
  echo "forward failed:" >&2
  printf '  %s\n' "$out" >&2
  exit 1
fi
