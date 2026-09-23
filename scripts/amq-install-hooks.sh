#!/usr/bin/env bash
# AMQ delivery hooks for ONE specific working directory, written into the committed
# .claude/settings.json. The hook command resolves its own path from the current
# worktree root, so it holds nothing machine-specific and is safe to commit: git
# then distributes hooks and scripts to every working copy, including later ones.
#
#   amq-install-hooks.sh --dir <directory> [--remove]
set -euo pipefail
DIR=""; REMOVE=0; VENDOR="${VENDOR:-1}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    --no-vendor) VENDOR=0; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DIR" ] || { echo "--dir is required" >&2; exit 2; }
DIR="$(cd "${DIR/#\~/$HOME}" && pwd)"
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=".claude/hooks/agent-mail"          # own subdirectory, so we don't collide with other hooks
[ -x "$SRC/amq-hook.sh" ] || { echo "$SRC/amq-hook.sh is missing" >&2; exit 1; }
mkdir -p "$DIR/.claude"

# The scripts go INTO THE REPOSITORY and get committed: git then spreads them to every
# working copy, including ones created later, exactly as it does with any other tracked
# file. The source of truth stays in the installed skill directory.
if [ "$REMOVE" = "0" ] && [ "$VENDOR" = "1" ]; then
  # These files land in SOMEONE ELSE'S repository and pass through its gates. Breaking
  # another project's pre-commit with a vendored file is not acceptable: check upfront
  # with whatever is available.
  if command -v ruff >/dev/null 2>&1; then
    if ! ruff check "$SRC"/*.py >/dev/null 2>&1; then
      echo "  ✗ ruff rejects the scripts — cancelling the copy so we don't break your linter:" >&2
      ruff check "$SRC"/*.py 2>&1 | head -10 >&2
      exit 1
    fi
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S error "$SRC"/*.sh >/dev/null 2>&1 || \
      echo "  ⚠ shellcheck has remarks about the scripts (copying anyway, but worth a look)"
  fi
  mkdir -p "$DIR/$DEST"
  for f in amq-hook.sh amq-use.sh amq-claim.sh amq-log.sh slug.py; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DIR/$DEST/$f" && chmod +x "$DIR/$DEST/$f"
  done
  echo "  scripts copied into: $DIR/$DEST"
  echo "  commit them together with .claude/settings.json"
fi


DIR="$DIR" REMOVE="$REMOVE" SRC="$SRC" python3 <<'PY'
import json, os

d, remove, src = os.environ["DIR"], os.environ["REMOVE"] == "1", os.environ["SRC"]
MARK = "amq-hook.sh"   # recognises our hooks in any spelling

def strip_ours(cfgobj):
    """Remove our hooks from a settings object. Returns True if anything was removed."""
    hk = cfgobj.get("hooks") or {}
    changed = False
    for event in list(hk):
        kept = []
        for group in hk[event]:
            inner = [h for h in group.get("hooks", []) if MARK not in str(h.get("command", ""))]
            if len(inner) != len(group.get("hooks", [])):
                changed = True
            if inner:
                kept.append({**group, "hooks": inner})
            elif not group.get("hooks"):
                kept.append(group)
        if kept:
            hk[event] = kept
        else:
            hk.pop(event, None)
            changed = True
    if hk:
        cfgobj["hooks"] = hk
    else:
        cfgobj.pop("hooks", None)
    return changed

# Earlier versions of this installer wrote the hooks into the personal
# settings.local.json, back when the command held an absolute path. It does not any
# more, so the entries live in settings.json — and the old ones are always stripped
# out of settings.local.json, otherwise the hook would fire twice.
shared = os.path.join(d, ".claude", "settings.local.json")
if os.path.exists(shared):
    try:
        scfg = json.load(open(shared))
    except Exception:
        scfg = None
    if scfg is not None and strip_ours(scfg):
        json.dump(scfg, open(shared, "w"), indent=2, ensure_ascii=False)
        open(shared, "a").write("\n")
        print("  ! removed the old hooks from settings.local.json (they now live in settings.json)")

path = os.path.join(d, ".claude", "settings.json")
cfg = {}
if os.path.exists(path):
    try:
        cfg = json.load(open(path))
    except Exception:
        raise SystemExit(f"{path} is not valid JSON — sort it out by hand")

hooks = cfg.get("hooks", {})
cfg["hooks"] = hooks
strip_ours(cfg)                                  # our previous ones — idempotency
hooks = cfg.get("hooks", {})

if not remove:
    # The path is taken from the root of the CURRENT worktree, so the copy of the script
    # from the branch being worked on is the one that runs. No repository or no script —
    # do nothing silently, so we don't get in the way of people who don't use the mail.
    root = '$(git rev-parse --show-toplevel 2>/dev/null)'
    for event, mode, timeout in (("SessionStart", "session-start", 15),
                                 ("UserPromptSubmit", "prompt", 10),
                                 ("Stop", "stop", 10)):
        # Only the in-repository copy: nothing machine-specific, which is what makes the
        # file safe to commit. git then spreads both hooks and scripts to every working
        # copy, including ones created later.
        cmd = (f'H="{root}/.claude/hooks/agent-mail/amq-hook.sh"; '
               f'[ -x "$H" ] && bash "$H" {mode} || true')
        hooks.setdefault(event, []).append(
            {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]})

if hooks:
    cfg["hooks"] = hooks
else:
    cfg.pop("hooks", None)
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")

print(("removed" if remove else "installed") + f" hooks: {os.path.relpath(path, d)}")
PY
