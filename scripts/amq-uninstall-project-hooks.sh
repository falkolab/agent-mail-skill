#!/usr/bin/env bash
# Remove a per-project installation of agent-mail: the hook registrations and the
# vendored copies of the scripts.
#
#   amq-uninstall-project-hooks.sh --dir <working copy> [--keep-scripts]
#
# Nothing registers hooks inside a project any more — that belongs to
# amq-install-user-hooks.sh, so there is one layer and nothing can stack. This is the
# cleanup path for repositories that still carry the old installation.
#
# It touches only hooks and vendored scripts. The mailbox (.agent-mail/) and the config
# (.amqrc) are never touched: an earlier version of the removal path deleted .amqrc and
# killed delivery across a whole project while printing that it had kept the file.
#
# .claude/settings.json is usually tracked by git, so removing entries from it leaves a
# change to commit. This script does not commit anything.
set -uo pipefail

DIR=""; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --keep-scripts) KEEP=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DIR" ] || { echo "--dir is required" >&2; exit 2; }
DIR="$(cd "${DIR/#\~/$HOME}" && pwd)" || exit 1
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

DIR="$DIR" python3 <<'PY'
import json, os

d = os.environ["DIR"]
MARK = "amq-hook.sh"


def strip_ours(cfgobj):
    """Remove only our entries; another tool's hooks stay exactly as they are."""
    hk = cfgobj.get("hooks") or {}
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
    if hk:
        cfgobj["hooks"] = hk
    else:
        cfgobj.pop("hooks", None)
    return removed


total = 0
for name in ("settings.json", "settings.local.json"):
    path = os.path.join(d, ".claude", name)
    if not os.path.exists(path):
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as exc:
        print(f"  ! {name} is not valid JSON ({exc}) — left alone")
        continue
    n = strip_ours(cfg)
    if not n:
        continue
    tmp = path + ".amq-tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)
    print(f"  removed {n} hook entr{'y' if n == 1 else 'ies'} from {name}")
    total += n
if not total:
    print("  no project hook registrations here")
PY

if [ "$KEEP" != "1" ]; then
  V="$DIR/.claude/hooks/agent-mail"
  if [ -d "$V" ]; then
    # Remove the vendored files by name. A recursive delete on a path assembled from an
    # argument is exactly the mistake that costs someone a tree.
    for f in amq-hook.sh amq-use.sh amq-claim.sh amq-log.sh amq-return.sh \
             amq-setup-project.sh amq-install-hooks.sh amq-install-user-hooks.sh \
             amq-uninstall-project-hooks.sh slug.py; do
      [ -f "$V/$f" ] && rm -f "$V/$f"
    done
    rmdir "$V" 2>/dev/null && echo "  removed the vendored scripts: $V" \
      || echo "  vendored scripts removed; $V still holds files that are not ours"
  fi
fi

cat <<EOF

The mailbox and .amqrc were NOT touched — mail keeps arriving. Delivery now depends on
the user-level hooks:
  $(cd "$(dirname "$0")" && pwd)/amq-install-user-hooks.sh --check

If .claude/settings.json is tracked here, the change above is waiting to be committed.
EOF
