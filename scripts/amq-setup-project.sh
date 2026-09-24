#!/usr/bin/env bash
# Idempotent project setup for AMQ. Never write the config by hand.
#
#   amq-setup-project.sh --project <name> --dir <repo> --handle <handle> \
#                        [--peer <name>=<path>]... [--session <topic>]... \
#                        [--no-hooks] [--no-worktrees] [--add-path]
#
# Sets up the main checkout AND all of its git worktrees, pointing them at ONE mailbox:
# a worktree has no .amqrc of its own (it is outside git), so the mailbox is located
# through --git-common-dir, which every copy resolves to the same place.
#
# Safe to re-run: it repairs what is missing and overwrites nothing.
set -euo pipefail

PROJECT=""; DIR=""; HANDLE=""; PEERS=(); SESSIONS=(); HOOKS=0; WORKTREES=1; REMOVE=0; ADDPATH=0; PRUNE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --dir)     DIR="$2"; shift 2 ;;
    --handle)  HANDLE="$2"; shift 2 ;;
    --peer)    PEERS+=("$2"); shift 2 ;;
    --session) SESSIONS+=("$2"); shift 2 ;;
    --no-hooks)     HOOKS=0; shift ;;            # kept for compatibility; now the default
    --project-hooks) HOOKS=1; shift ;;
    --no-worktrees) WORKTREES=0; shift ;;
    --remove)       REMOVE=1; shift ;;
    --add-path)     ADDPATH=1; shift ;;
    --prune-worktree-amqrc) PRUNE=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$REMOVE" = "1" ]; then
  [ -n "$DIR" ] || { echo "--remove needs --dir" >&2; exit 2; }
else
  [ -n "$PROJECT" ] && [ -n "$DIR" ] && [ -n "$HANDLE" ] || {
    echo "--project, --dir and --handle are required (see --help)" >&2; exit 2; }
fi

DIR="$(cd "${DIR/#\~/$HOME}" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
say() { printf '  %s\n' "$*"; }

# --dir may point at a worktree. The main checkout is what has to be configured:
# otherwise the script would put a new empty mailbox inside the worktree, mail would
# keep landing in the old one, and the divergence would be silent.
# A bare top level tracks nothing, so copying scripts into it is pointless — there
# would be nothing to commit and new copies would get nothing. In that layout the
# install target is a working copy.
# ANCHOR — where .amqrc and .agent-mail live (the project mailbox).
# DIR    — the working copy that scripts and hooks are written to and committed from.
# In an ordinary layout they are the same; in a bare one they differ.
ANCHOR="$DIR"
# The mailbox belongs to the REPOSITORY, not to a working copy. Resolved the same way
# as in the hook: first the directory NEXT TO git's common dir, and only then the
# common dir itself (a classic bare repo). Taking only the common dir used to send the
# anchor into <repo>/.git on a deferred checkout (core.bare=true with a .git present),
# putting the mailbox in the wrong place and making coop init refuse once the parent
# was already configured.
anchor_of() {
  local c d
  c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$c" ] || return 1
  d=$(dirname "$c")
  [ -f "$d/.amqrc" ] || [ -d "$d/.agent-mail" ] && { printf '%s' "$d"; return 0; }
  [ -f "$c/.amqrc" ] || [ -d "$c/.agent-mail" ] && { printf '%s' "$c"; return 0; }
  case "$(basename "$c")" in
    .git) printf '%s' "$d" ;;      # ordinary or deferred checkout
    *)    printf '%s' "$c" ;;      # classic bare: the common dir IS the root
  esac
}
CAND=$(anchor_of "$DIR" || true)
if [ -n "$CAND" ] && [ "$CAND" != "$DIR" ]; then
  echo "working-copy layout: the mailbox belongs to the repository"
  echo "  mailbox: $CAND"
  echo "  scripts: $DIR"
  ANCHOR="$CAND"
fi
if [ "$(git -C "$DIR" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
  WT=()
  while IFS= read -r line; do
    w="${line#worktree }"
    [ "$w" = "$DIR" ] || [ ! -d "$w" ] || WT+=("$w")
  done < <(git -C "$DIR" worktree list --porcelain 2>/dev/null | grep '^worktree ')
  # Pick the copy the scripts go into: the default branch first, otherwise the first
  # non-detached one. Refuse only when there are no copies at all — this used to refuse
  # whenever every copy simply sat on its own branch, which blocked the install for no
  # good reason.
  if [ "${#WT[@]}" -gt 1 ]; then
    DEFBR=$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null)
    PICK=""
    for w in "${WT[@]}"; do
      br=$(git -C "$w" rev-parse --abbrev-ref HEAD 2>/dev/null)
      [ "$br" = "$DEFBR" ] && { PICK="$w"; break; }
      [ -z "$PICK" ] && [ "$br" != "HEAD" ] && PICK="$w"
    done
    [ -n "$PICK" ] && WT=("$PICK")
  fi
  if [ "${#WT[@]}" -eq 1 ]; then
    PICKBR=$(git -C "${WT[0]}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$DEFBR" ] && [ "$PICKBR" != "$DEFBR" ]; then
      echo "NOTE: no working copy is on the default branch ($DEFBR)."
      echo "  Scripts will go into $(basename "${WT[0]}") on branch $PICKBR — the commit lands there."
      echo "  If you want $DEFBR, point --dir at the copy that has it."
    fi
    echo "--dir points at a bare repository${DEFBR:+ (default branch: $DEFBR)}."
    echo "  the mailbox stays with it: $DIR"
    echo "  scripts and hooks go into the working copy: ${WT[0]}"
    # Anchor the mailbox to the bare repository, not to the copy: a copy is mortal,
    # .amqrc does not reach it through git, and new copies would not find the mailbox.
    ANCHOR="$DIR"
    DIR="${WT[0]}"
  else
    echo "--dir points at a BARE repository — git tracks nothing there," >&2
    echo "so there is nowhere to commit scripts and hooks. Point at a working copy:" >&2
    for w in "${WT[@]+"${WT[@]}"}"; do echo "  --dir \"$w\"" >&2; done
    [ "${#WT[@]}" -eq 0 ] && echo "  (no working copies found — create one with git worktree add)" >&2
    exit 2
  fi
fi

COMMON=$(git -C "$DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ -n "$COMMON" ]; then
  MAIN=$(dirname "$COMMON")
  if [ "$MAIN" != "$DIR" ] && [ -d "$MAIN" ] \
     && [ "$(git -C "$MAIN" rev-parse --show-toplevel 2>/dev/null)" = "$MAIN" ]; then
    echo "--dir points at a git worktree; configuring the main checkout instead:"
    echo "  $MAIN"
    echo "  (worktrees are picked up automatically)"
    DIR="$MAIN"
  fi
fi

# -- 0. removal ----------------------------------------------------------
if [ "$REMOVE" = "1" ]; then
  echo "removing agent-mail: $DIR"
  TARGETS=("$DIR")
  if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r line; do
      wt="${line#worktree }"; [ "$wt" = "$DIR" ] || TARGETS+=("$wt")
    done < <(git -C "$DIR" worktree list --porcelain 2>/dev/null | grep '^worktree ')
  fi
  for t in "${TARGETS[@]}"; do
    [ -d "$t" ] || continue
    "$HERE/amq-install-hooks.sh" --dir "$t" --remove 2>/dev/null | sed "s|^|  $(basename "$t"): |"
    # NEVER delete .amqrc here. This used to remove it from every target except
    # $DIR, and in a bare layout $DIR is a working copy while the real config sits
    # at the repository anchor — so --remove silently deleted the project's only
    # config and killed delivery everywhere, while printing that the file was kept.
    # Stray per-worktree copies have their own explicit flag: --prune-worktree-amqrc.
    rm -f "$t/.agent-mail/.hook-blocked-"* 2>/dev/null
  done
  cat <<EOF

hooks removed, delivery stopped. STILL ON DISK (remove by hand if you want to):
  $DIR/.amqrc            - the project config
  $DIR/.agent-mail/      - the mailboxes and the whole correspondence
  lines in .git/info/exclude - .agent-mail/, .amqrc, .claude/settings.local.json
Neighbours still list us in their peers - remove it there too.
EOF
  exit 0
fi

# -- 1. the binary -------------------------------------------------------
if ! command -v amq >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "amq not found, installing: brew install avivsinai/tap/amq"; brew install avivsinai/tap/amq
  else
    echo "amq not found. Install it: brew install avivsinai/tap/amq" >&2; exit 1
  fi
fi
echo "amq $(amq --version 2>/dev/null || echo '?')  ·  project $PROJECT  ·  $DIR"

# -- 2. mailboxes of the main checkout -----------------------------------
# coop init, not amq setup: setup only accepts the handles of known adapters
# (claude/codex/cursor/grok) and rejects custom names. coop init takes any.
if [ -f "$ANCHOR/.amqrc" ]; then
  say "· .amqrc already exists — skipping coop init"
else
  say "· amq coop init"
  if ! out=$( cd "$ANCHOR" && amq coop init --root .agent-mail --agents "$HANDLE,user" --no-gitignore 2>&1 ); then
    echo "✗ coop init refused in $ANCHOR — nothing was installed:" >&2
    printf '  %s\n' "$out" >&2
    exit 1
  fi
fi

# -- 3. .amqrc: project + peers ------------------------------------------
# Paths are absolute: .amqrc is excluded from git anyway (machine-local), and a
# worktree can live anywhere — a relative path would not resolve there.
write_amqrc() {   # $1=directory  $2=value for root
  TARGET="$1" ROOTVAL="$2" PROJECT="$PROJECT" HANDLE="$HANDLE" FALLBACK_AMQRC="${3:-}" \
  PEERS_RAW="$(printf '%s\n' "${PEERS[@]+"${PEERS[@]}"}")" python3 <<'PY'
import json, os, sys
target, rootval, project = os.environ["TARGET"], os.environ["ROOTVAL"], os.environ["PROJECT"]
path = os.path.join(target, ".amqrc")
cfg = json.load(open(path)) if os.path.exists(path) else {}
cfg["root"] = rootval
cfg["project"] = project
cfg["handle"] = os.environ["HANDLE"]   # the hook reads it here instead of guessing from the registry
peers = cfg.get("peers", {})
# a worktree with no peers of its own inherits them from the main checkout:
# otherwise a cross-project send from a worktree silently has no route.
fb = os.environ.get("FALLBACK_AMQRC", "")
if not peers and fb and os.path.exists(fb):
    try:
        peers = dict(json.load(open(fb)).get("peers") or {})
    except Exception:
        peers = {}
# Keep peer paths absolute. A relative path inherited from the main checkout would
# resolve against the worktree's own directory — that is, against the wrong place.
# Resolve it against the directory it was actually relative to.
base = os.path.dirname(fb) if fb else target
peers = {k: (v if os.path.isabs(v) else os.path.abspath(os.path.join(base, v)))
         for k, v in peers.items()}
for line in os.environ.get("PEERS_RAW", "").splitlines():
    if not line.strip():
        continue
    if "=" not in line:
        sys.exit(f"--peer expects <name>=<path>, got: {line}")
    name, p = line.split("=", 1)
    p = os.path.abspath(os.path.expanduser(p.strip()))
    if not p.rstrip("/").endswith(".agent-mail"):
        p = os.path.join(p, ".agent-mail")
    peers[name.strip()] = p
if peers:
    cfg["peers"] = peers
json.dump(cfg, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
}
# .gitignore is tracked by git, and writing to it dirties the working tree of every
# branch. info/exclude is per-worktree and not tracked at all — so after the setup the
# repository is left with NO changes whatsoever.
git_exclude() {
  local t="$1" ex
  git -C "$t" rev-parse --git-dir >/dev/null 2>&1 || return 0
  ex=$(git -C "$t" rev-parse --git-path info/exclude 2>/dev/null) || return 0
  case "$ex" in /*) ;; *) ex="$t/$ex" ;; esac
  mkdir -p "$(dirname "$ex")" 2>/dev/null || return 0
  local line
  for line in ".agent-mail/" ".amqrc" ".claude/settings.local.json"; do
    grep -qxF "$line" "$ex" 2>/dev/null || printf '%s\n' "$line" >> "$ex"
  done
}

write_amqrc "$ANCHOR" ".agent-mail"
git_exclude "$DIR"
[ "$ANCHOR" = "$DIR" ] || git_exclude "$ANCHOR"
say "· .amqrc: project=$PROJECT, peers ${#PEERS[@]}"

# -- 4. sessions: always collab + the requested topics --------------------
# An amq session name is [a-z0-9_-] only. Non-ASCII is transliterated rather than
# dropped: otherwise a topic named in another script collapses to an empty string
# and the session is never created.
slug() { python3 "$HERE/slug.py" "$1"; }
for raw in collab "${SESSIONS[@]+"${SESSIONS[@]}"}"; do
  s="$(slug "$raw")"
  if [ -d "$ANCHOR/.agent-mail/$s" ]; then say "· session $s — exists"
  else ( cd "$ANCHOR" && amq session create "$s" --me "$HANDLE" >/dev/null ) && say "· session $s — created"; fi
done

# -- 5. worktrees: no walk needed ----------------------------------------
# The mailbox is found through --git-common-dir, and git itself spreads hooks and
# scripts as tracked files. Old per-worktree .amqrc files are removed: they are no
# longer needed and would break when the tree is moved.
WTS=()
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r line; do
    wt="${line#worktree }"
    [ "$wt" = "$DIR" ] || [ "$wt" = "$ANCHOR" ] || WTS+=("$wt")
  done < <(git -C "$DIR" worktree list --porcelain 2>/dev/null | grep '^worktree ')
fi
# Stray .amqrc files in copies are no longer needed (the mailbox is found through
# --git-common-dir), but deleting someone's files silently is not acceptable: a copy
# may be another person's working branch mid-migration. Report it; delete only on
# an explicit request.
for wt in "${WTS[@]+"${WTS[@]}"}"; do
  [ -f "$wt/.amqrc" ] || continue
  if [ "$PRUNE" = "1" ]; then
    rm -f "$wt/.amqrc" && say "· removed the stray .amqrc from $(basename "$wt")"
  else
    say "⚠ copy $(basename "$wt") has its own .amqrc — it points at a SEPARATE mailbox"
    say "  look:   cat \"$wt/.amqrc\""
    say "  remove: amq-setup-project.sh --prune-worktree-amqrc --dir <repo>"
  fi
done
[ "${#WTS[@]}" -gt 0 ] && say "· worktrees: ${#WTS[@]}, no separate setup needed"

# -- 6. delivery hooks ---------------------------------------------------
# Registration belongs to amq-install-user-hooks.sh and to nothing else. It used to
# happen here by default, which meant any later run of this script — from memory, from
# an old README, in any repository — put the project layer back and the hooks fired
# twice again, from two different copies of the script. Removing the instances was not
# enough while the capability stayed the default; now the safe behaviour is the default
# and the other one needs --project-hooks.
USER_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ "$HOOKS" = "1" ]; then
  say "· registering hooks IN THE PROJECT (--project-hooks)"
  if grep -q 'amq-hook.sh' "$USER_CFG" 2>/dev/null; then
    say "  ⚠ they are also registered at user level in $USER_CFG —"
    say "    both layers fire, so every event will run twice, from two copies."
  fi
  "$HERE/amq-install-hooks.sh" --dir "$DIR" | sed 's/^/  · /'
elif grep -q 'amq-hook.sh' "$USER_CFG" 2>/dev/null; then
  say "· hooks already registered at user level — nothing to install in the project"
else
  say "· hooks are NOT registered yet — run this once, for your user:"
  say "    $HERE/amq-install-user-hooks.sh"
  say "  it covers every repository on this machine, including worktrees and"
  say "  repositories created later, and installs nothing into any project."
fi

# -- 7. verification -----------------------------------------------------
echo "verification:"
( cd "$ANCHOR"
  amq doctor 2>&1 | grep -E "✗|⚠" | grep -v "skill: not installed" | sed 's/^/  /' || true
  # Read exactly what was written into .amqrc, not the original --peer string:
  # otherwise the check could diverge from the config and lie in either direction.
  while IFS=$'\t' read -r name ppath; do
    [ -n "$name" ] || continue
    roster="$ppath/meta/config.json"
    if [ ! -f "$roster" ]; then
      say "· $name is not set up yet — run the script there too"; continue
    fi
    peer_handle=$(python3 -c "import json,sys;a=json.load(open(sys.argv[1]))['agents'];print(next((h for h in a if h!='user'),''))" "$roster")
    [ -n "$peer_handle" ] || { say "· $name has no agent besides user in its registry"; continue; }
    if amq route explain --me "$HANDLE" --to "$peer_handle" --project "$name" --session collab --json 2>&1 | grep -q '"routable": true'; then
      # A forward route is half the job. The reply travels by OUR name in THEIR peers:
      # if it is missing there, or we recorded the neighbour under a different key,
      # there is no way to answer — and that only surfaces once a message has been read.
      back=$(PEER_DIR="$(dirname "$ppath")" OUR="$PROJECT" KEY="$name" python3 <<'PY2'
import json, os
try:
    cfg = json.load(open(os.path.join(os.environ["PEER_DIR"], ".amqrc")))
except Exception:
    print("no-amqrc"); raise SystemExit
if cfg.get("project") != os.environ["KEY"]:
    print("wrong-name:" + str(cfg.get("project"))); raise SystemExit
print("ok" if os.environ["OUR"] in (cfg.get("peers") or {}) else "no-backref")
PY2
)
      case "$back" in
        ok) say "✓ route to $name ($peer_handle), and the return route too" ;;
        no-backref) say "✗ $name does not know us as \"$PROJECT\" — REPLIES WILL NOT ARRIVE. Add at the neighbour: --peer $PROJECT=$DIR" ;;
        wrong-name:*) say "✗ the neighbour has project=\"${back#wrong-name:}\" but we recorded it as \"$name\" — rename the key" ;;
        *) say "⚠ route to $name ($peer_handle) exists, could not check the return route" ;;
      esac
    else
      say "✗ route to $name ($peer_handle) does not resolve"
    fi
  done < <(python3 -c "
import json,sys
try: peers=json.load(open(sys.argv[1]+'/.amqrc')).get('peers') or {}
except Exception: peers={}
for k,v in peers.items(): print(k+chr(9)+v)" "$ANCHOR") )

# does the worktree really see the shared mailbox?
for wt in "${WTS[@]+"${WTS[@]}"}"; do
  [ -d "$wt" ] || continue
  got=$( cd "$wt" && amq env --session collab --me "$HANDLE" --json 2>/dev/null \
         | python3 -c "import sys,json;print(json.load(sys.stdin).get('root',''))" 2>/dev/null )
  case "$got" in
    "$DIR/.agent-mail/collab") say "✓ worktree $(basename "$wt") → shared mailbox" ;;
    "") say "✗ worktree $(basename "$wt") — root does not resolve" ;;
    *)  say "✗ worktree $(basename "$wt") → $got (expected the shared one)" ;;
  esac
done

# -- the scripts have to be reachable by the hook ------------------------
# The hook looks for them in the repository first, then on PATH. With neither, it
# silently does nothing, and that is impossible to debug.
SDIR="$HERE"
if [ -x "$DIR/.claude/hooks/agent-mail/amq-hook.sh" ]; then
  say "✓ scripts: copy in the repository (commit .claude/hooks/agent-mail/)"
elif command -v amq-hook.sh >/dev/null 2>&1; then
  say "✓ scripts: copy in the repository + reachable in the terminal via PATH"
else
  LINE="export PATH=\"$SDIR:\$PATH\""
  case "${SHELL:-}" in
    *zsh)  PROFILE="$HOME/.zshrc" ;;
    *bash) PROFILE="$HOME/.bashrc" ;;
    *)     PROFILE="" ;;
  esac
  if [ "$ADDPATH" = "1" ] && [ -n "$PROFILE" ]; then
    if grep -qF "$SDIR" "$PROFILE" 2>/dev/null; then
      say "✓ PATH: the line is already in $(basename "$PROFILE")"
    else
      printf '\n# agent-mail\n%s\n' "$LINE" >> "$PROFILE" && \
        say "✓ PATH: appended to $(basename "$PROFILE")"
      say "  IMPORTANT: the current session will not pick this up. Claude Code snapshots"
      say "  the shell at start, so a profile edit only reaches the NEXT session."
      say "  Restart it, or you will conclude that PATH does not work."
    fi
  else
    say "  for your own terminal you can add this to ${PROFILE:-your shell profile}:"
    say "    $LINE"
    say "  (or --add-path). It does not affect the hook — that calls the copy in the repo."
  fi
fi

cat <<EOF

done. to pin the context in a terminal (works in a worktree too):
  cd <directory> && eval "\$(amq env --session collab --me $HANDLE)"
EOF
