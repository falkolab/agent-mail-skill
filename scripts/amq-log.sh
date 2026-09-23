#!/usr/bin/env bash
# Combined message feed: gathers mail from the files and prints it in time order.
# amq has `thread` for a single thread and `list` for a single mailbox, but no combined view.
#
#   amq-log.sh                    last 30 messages of this project
#   amq-log.sh --all              + mail of neighbouring projects (both sides)
#   amq-log.sh --body             with bodies
#   amq-log.sh --thread <id>      one whole thread
#   amq-log.sh --follow           live feed, Ctrl+C to exit
#   amq-log.sh --dir <repo>       explicit project (by default — from the current directory)


set -uo pipefail
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
exec python3 - "$@" <<'PY'
import json, os, sys, time, glob

args = sys.argv[1:]
def flag(n): return n in args
def opt(n, d=None):
    return args[args.index(n) + 1] if n in args and args.index(n) + 1 < len(args) else d

start = os.path.abspath(opt("--dir") or os.getcwd())
limit = int(opt("--limit", "30"))
want_body, follow, only_thread = flag("--body"), flag("--follow"), opt("--thread")

def find_cfg(d):
    while d and d != "/":
        p = os.path.join(d, ".amqrc")
        if os.path.exists(p):
            try: return d, json.load(open(p))
            except Exception: return d, {}
        d = os.path.dirname(d)
    return None, None

base, cfg = find_cfg(start)
if not cfg:
    sys.exit("no .amqrc here — point at a project with --dir <repo>")

def root_of(d, c):
    r = c.get("root", ".agent-mail")
    return r if os.path.isabs(r) else os.path.join(d, r)

roots = {cfg.get("project", "?"): root_of(base, cfg)}
if flag("--all"):
    for name, p in (cfg.get("peers") or {}).items():
        p = p if os.path.isabs(p) else os.path.abspath(os.path.join(base, p))
        if os.path.isdir(p): roots[name] = p

def read_all():
    """One message sits both in the sender's outbox and in the recipient's inbox —
    we deduplicate by msg_id, otherwise every reply shows up twice."""
    seen, out = {}, []
    for proj, root in roots.items():
        for f in glob.glob(os.path.join(root, "**", "*.md"), recursive=True):
            try:
                txt = open(f, encoding="utf-8", errors="replace").read()
                if not txt.startswith("---json"): continue
                head, _, body = txt.partition("---json")[2].partition("\n---")
                m = json.loads(head)
            except Exception:
                continue
            mid = m.get("id") or m.get("msg_id")
            if not mid or mid in seen: continue
            rel = os.path.relpath(f, root).split(os.sep)
            m["_project"], m["_session"] = proj, (rel[0] if rel[0] != "agents" else "(root)")
            m["_body"] = body.lstrip("\n")
            seen[mid] = 1
            out.append(m)
    out.sort(key=lambda x: str(x.get("created", "")))
    return out

CTRL = {c: None for c in range(32)}
for _c in (0x09, 0x0a, 0x0b, 0x0c, 0x0d):
    CTRL[_c] = 32            # newlines and tabs become a space, otherwise words run together
CTRL[0x7f] = None
CTRL[0x2028] = 32
CTRL[0x2029] = 32

def clean(v, limit=200):
    """The messages are written by other agents, while the feed goes to a human terminal:
    ESC sequences and newlines in the subject break the output."""
    t = " ".join(str(v if v is not None else "").translate(CTRL).split())
    return (t[:limit] + "…") if len(t) > limit else t

KIND_W = 14
def show(m):
    ts = str(m.get("created", ""))[11:19] or "--:--:--"
    src = m.get("from_project") or m.get("_project")
    dst = ", ".join(str(x) for x in (m.get("to") or ["?"]))
    line = "{}  {} -> {}  [{}/{}]  {}  {}".format(
        ts, clean(m.get("from", "?"), 24), clean(dst, 24), clean(src, 20),
        clean(m.get("_session", "?"), 24),
        clean(m.get("kind") or "-", KIND_W).ljust(KIND_W)[:KIND_W],
        clean(m.get("subject") or "(no subject)"))
    if str(m.get("priority")) == "urgent": line += "   !URGENT"
    print(line)
    if want_body and m.get("_body", "").strip():
        for ln in m["_body"].strip().splitlines()[:20]:
            print("        | " + clean(ln, 200))

msgs = read_all()
if only_thread:
    msgs = [m for m in msgs if m.get("thread") == only_thread]

if not follow:
    if not msgs:
        print("no messages. Projects in the feed: " + ", ".join(roots)); raise SystemExit
    for m in msgs[-limit:]:
        show(m)
    print("\n{} messages · projects: {}".format(len(msgs), ", ".join(roots)))
    raise SystemExit

known = {m.get("id") or m.get("msg_id") for m in msgs}
for m in msgs[-10:]:
    show(m)
print("--- live feed, Ctrl+C to exit ---")
try:
    while True:
        time.sleep(2)
        for m in read_all():
            mid = m.get("id") or m.get("msg_id")
            if mid not in known:
                known.add(mid)
                if not only_thread or m.get("thread") == only_thread:
                    show(m)
except KeyboardInterrupt:
    print()
PY
