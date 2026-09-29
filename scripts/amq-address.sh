#!/usr/bin/env bash
# Print the ready address for writing to a neighbour: handle, project and topic.
#
#   amq-address.sh              # every peer this repository knows
#   amq-address.sh <peer-name>  # one of them, with its topics
#
# Addressing has two parts a sender has to get right, and neither is guessable. The
# handle is not the project name — sending to the project name is accepted, invents a
# phantom inbox inside YOUR OWN mailbox, prints "Sent", and delivers nothing. The topic
# has to exist, and a window that claimed one sees only a count for mail left in collab.
#
# `amq who --json` is the obvious way to look this up and is unreliable: in a repository
# with a .claude/agents directory it returns null with exit code 0.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"

WANT="${1:-}"
case "$WANT" in -h|--help) sed -n '2,15p' "$0"; exit 0 ;; esac
command -v amq >/dev/null 2>&1 || { echo "amq not found in PATH" >&2; exit 1; }

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

ANCHOR=$(amq_anchor) || {
  echo "no .amqrc here and none above — this directory is not wired to agent-mail" >&2
  exit 1; }

eval "$(ANCHOR="$ANCHOR" python3 - <<'PY'
import json, os, shlex
cfg = json.load(open(os.path.join(os.environ["ANCHOR"], ".amqrc")))
print("ME=" + shlex.quote(cfg.get("handle", "")))
print("MYPROJ=" + shlex.quote(cfg.get("project", "?")))
PY
)"

ANCHOR="$ANCHOR" WANT="$WANT" ME="$ME" MYPROJ="$MYPROJ" python3 <<'PY'
import json, os, subprocess, sys

anchor, want = os.environ["ANCHOR"], os.environ["WANT"]
me, myproj = os.environ["ME"], os.environ["MYPROJ"]
peers = (json.load(open(os.path.join(anchor, ".amqrc"))).get("peers") or {})

if not peers:
    sys.exit(f"{myproj} has no peers configured — add one with "
             f"amq-setup-project.sh --peer <name>=<repo>")
if want and want not in peers:
    print(f"no peer called {want!r}. Known: {', '.join(sorted(peers))}", file=sys.stderr)
    raise SystemExit(3)

for name in ([want] if want else sorted(peers)):
    root = peers[name]
    print(f"\n{name}")
    if not os.path.isdir(root):
        print(f"  no mailbox at {root} — the path in your .amqrc is wrong or it moved")
        continue

    # The handle comes from the neighbour's own registry. Anything else is a guess, and a
    # wrong guess is accepted silently.
    try:
        agents = [a for a in json.load(
            open(os.path.join(root, "meta", "config.json")))["agents"] if a != "user"]
    except Exception:
        print("  not set up yet — no registry; run amq-setup-project.sh there")
        continue
    if not agents:
        print("  registry lists no agent besides user")
        continue

    # Their name for themselves must match the key we filed them under, or replies fail.
    try:
        theirs = json.load(open(os.path.join(os.path.dirname(root), ".amqrc")))
    except Exception:
        theirs = {}
    if theirs.get("project") and theirs["project"] != name:
        print(f"  ! they call themselves {theirs['project']!r}, you filed them as {name!r}")
        print(f"    replies will not come back. Re-run with --peer {theirs['project']}=<repo>")
    if theirs.get("peers") is not None and myproj not in (theirs.get("peers") or {}):
        print(f"  ! they do not list {myproj!r} as a peer — they cannot answer you")
        print(f"    they should run: amq-setup-project.sh --peer {myproj}=<your repo>")

    try:
        out = subprocess.run(["amq", "session", "list", "--root", root, "--json"],
                             capture_output=True, text=True, timeout=20)
        topics = [s["name"] for s in (json.loads(out.stdout or "{}").get("sessions") or [])]
    except Exception:
        topics = []

    claimed = set()
    for f in os.listdir(root):
        if f.startswith(".window-"):
            try:
                claimed.add(open(os.path.join(root, f)).read().strip())
            except OSError:
                pass

    def about(t):
        try:
            d = open(os.path.join(root, t, ".description")).read().strip()
            return d.splitlines()[0][:100] if d else ""
        except OSError:
            return ""

    for h in agents:
        for t in sorted(topics):
            if t == "collab":
                continue
            mark = "someone is on it" if t in claimed else "nobody is on it"
            # The slug alone does not say what a topic is for; the window that claimed it
            # is the only one who knows, and writes it down at claim time.
            desc = about(t) or "no description — the window that claimed it did not say"
            print(f"  {t} — {desc}  [{mark}]")
            print(f"    amq send --me {me} --to {h} --project {name} --session {t} "
                  f"--strict \\\n      --kind question --subject \"...\" --body \"...\"")
        if "collab" in topics:
            print(f"  amq send --me {me} --to {h} --project {name} --session collab "
                  f"--strict \\\n      --labels <their-topic> --kind question "
                  f"--subject \"...\" --body \"...\"   # only if no topic fits")

print("\n--strict is not optional: without it a wrong handle is accepted, a phantom")
print("inbox appears inside YOUR mailbox, \"Sent\" is printed and nothing is delivered.")
PY
