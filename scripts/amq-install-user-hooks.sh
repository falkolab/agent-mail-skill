#!/usr/bin/env bash
# Register the AMQ delivery hooks once, for your user, so every repository on the
# machine is covered — including ones created later — with nothing installed into
# any project.
#
#   amq-install-user-hooks.sh            # install (idempotent)
#   amq-install-user-hooks.sh --remove   # take them out again
#   amq-install-user-hooks.sh --check    # report what is registered, change nothing
#
# Writes only this skill's own entries into ~/.claude/settings.json (or
# $CLAUDE_CONFIG_DIR/settings.json), leaving every other tool's hooks untouched.
# The command it registers is the absolute path of THIS checkout, resolved at install
# time, so the skill works wherever you cloned it.
#
# The hook stays silent in repositories that are not wired to AMQ: inside a git
# repository it looks only at that repository's own .amqrc and never above it.
#
# Two things worth knowing before you run it:
#  - Cloud sessions (claude.ai/code) do NOT read your local settings; they read the
#    repository's committed .claude/settings.json. User-level hooks cover local
#    sessions only.
#  - If a project also registers these hooks in its own .claude/settings.json, BOTH
#    fire: Claude Code merges hooks across settings levels and only deduplicates
#    byte-identical commands. This script warns when it finds such a project.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/amq-hook.sh"
CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CFG="$CFG_DIR/settings.json"

MODE=install
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remove) MODE=remove; shift ;;
    --check)  MODE=check; shift ;;
    --force)  FORCE=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -x "$HOOK" ] || { echo "not found or not executable: $HOOK" >&2; exit 1; }

# Registrations stack: user + project-tracked + project-local all fire. Claude Code
# deduplicates only byte-identical commands, and a vendored copy is a different path,
# so installing on top of a project that registers its own hooks doubles every event —
# and the two copies can be different versions of the script. A project that has put
# its own house in order cannot see this layer, so we refuse rather than warn after
# the damage: it is their sessions that change behaviour, not ours.
scan_projects() {
  python3 - <<'PY'
import json, os
seen = {os.getcwd()}
try:
    cfg = json.load(open(os.path.expanduser("~/.amqrc")))
    for p in (cfg.get("peers") or {}).values():
        seen.add(os.path.dirname(p))
except Exception:
    pass
for d in sorted(seen):
    print(d)
PY
}
find_project_hooks() {
  local d s
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    while IFS= read -r s; do
      grep -q 'amq-hook.sh' "$s" 2>/dev/null && printf '%s\n' "$s"
    done < <(find "$d" -maxdepth 5 \( -name 'settings.json' -o -name 'settings.local.json' \) \
             -path '*/.claude/*' 2>/dev/null)
  done <<< "$(scan_projects)"
}
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
mkdir -p "$CFG_DIR" 2>/dev/null || { echo "cannot create $CFG_DIR" >&2; exit 1; }

if [ "$MODE" = "install" ] && [ "$FORCE" != "1" ]; then
  CLASH=$(find_project_hooks | grep -v "^$CFG\$" || true)
  if [ -n "$CLASH" ]; then
    echo "refusing to install: these projects register the hooks themselves," >&2
    echo "so every event would fire twice, from two different copies of the script:" >&2
    printf '  %s\n' $CLASH >&2
    echo >&2
    echo "Remove the project-level registration first (it does NOT touch the mailbox" >&2
    echo "or .amqrc), then run this again:" >&2
    echo "  amq-setup-project.sh --remove --dir <repo>" >&2
    echo "  rm -r <repo>/.claude/hooks/agent-mail" >&2
    echo >&2
    echo "Or --force if you understand the duplication and want it anyway." >&2
    exit 6
  fi
fi

HOOK="$HOOK" CFG="$CFG" MODE="$MODE" python3 <<'PY'
import json, os, sys

hook, cfg_path, mode = os.environ["HOOK"], os.environ["CFG"], os.environ["MODE"]
MARK = "amq-hook.sh"          # recognises our entries whatever the path around them
EVENTS = (("SessionStart", "session-start", 15),
          ("UserPromptSubmit", "prompt", 10),
          ("Stop", "stop", 10))

cfg = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as exc:
        sys.exit(f"{cfg_path} is not valid JSON ({exc}) — fix it by hand, refusing to overwrite")
if not isinstance(cfg, dict):
    sys.exit(f"{cfg_path} does not hold a JSON object — refusing to touch it")

hooks = cfg.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}


def strip_ours(hk):
    """Drop only our entries. Everything another tool registered stays exactly as it is."""
    removed = 0
    for event in list(hk):
        groups = hk.get(event)
        if not isinstance(groups, list):
            continue
        kept = []
        for group in groups:
            if not isinstance(group, dict):
                kept.append(group)
                continue
            inner = group.get("hooks")
            if not isinstance(inner, list):
                kept.append(group)
                continue
            survivors = [h for h in inner if MARK not in str(h.get("command", ""))]
            removed += len(inner) - len(survivors)
            if survivors:
                kept.append({**group, "hooks": survivors})
        if kept:
            hk[event] = kept
        else:
            hk.pop(event, None)
    return removed


if mode == "check":
    found = [(e, h.get("command", ""))
             for e, gs in hooks.items() if isinstance(gs, list)
             for g in gs if isinstance(g, dict)
             for h in (g.get("hooks") or []) if MARK in str(h.get("command", ""))]
    print(f"settings: {cfg_path}")
    if found:
        for event, cmd in found:
            print(f"  {event}: {cmd}")
    else:
        print("  no agent-mail hooks registered for this user")
    others = sum(len(g.get("hooks") or [])
                 for gs in hooks.values() if isinstance(gs, list)
                 for g in gs if isinstance(g, dict)) - len(found)
    print(f"  other tools' hooks present: {others}")
    raise SystemExit(0)

removed = strip_ours(hooks)

if mode == "install":
    for event, hook_mode, timeout in EVENTS:
        hooks.setdefault(event, []).append(
            {"hooks": [{"type": "command",
                        "command": f"{hook} {hook_mode}",
                        "timeout": timeout}]})

if hooks:
    cfg["hooks"] = hooks
else:
    cfg.pop("hooks", None)

tmp = cfg_path + ".amq-tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, cfg_path)

if mode == "install":
    print(f"installed 3 hooks in {cfg_path}")
    print(f"  command: {hook} <session-start|prompt|stop>")
    if removed:
        print(f"  (replaced {removed} earlier agent-mail entries)")
    print("  every repository with a .amqrc is now covered, in any worktree.")
else:
    print(f"removed {removed} agent-mail hooks from {cfg_path}" if removed
          else f"nothing of ours was registered in {cfg_path}")
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ "$MODE" = "check" ] && exit 0

# A project that still registers these hooks itself would double every event: Claude Code
# merges hooks across settings levels and deduplicates only byte-identical commands, and a
# vendored copy is a different path, so it is never identical to ours.
if [ "$MODE" = "install" ]; then
  echo
  echo "checking for project-level copies that would fire a second time..."
  found=0
  # Scan the projects we can actually name: the current directory, and every peer
  # listed in ~/.amqrc. Searching the whole disk would be slow and presumptuous.
  DIRS=$(python3 - <<'PY'
import json, os
seen = {os.getcwd()}
try:
    cfg = json.load(open(os.path.expanduser("~/.amqrc")))
    for p in (cfg.get("peers") or {}).values():
        seen.add(os.path.dirname(p))
except Exception:
    pass
for d in sorted(seen):
    print(d)
PY
)
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    while IFS= read -r s; do
      grep -q 'amq-hook.sh' "$s" 2>/dev/null || continue
      echo "  ! $s"
      found=1
    done < <(find "$d" -maxdepth 5 -name 'settings.json' -path '*/.claude/*' 2>/dev/null)
  done <<< "$DIRS"
  if [ "$found" = "1" ]; then
    echo "  Those register the hooks per project, so each event would run twice."
    echo "  Remove them with: amq-setup-project.sh --remove --dir <repo>"
  else
    echo "  none found"
  fi
fi
