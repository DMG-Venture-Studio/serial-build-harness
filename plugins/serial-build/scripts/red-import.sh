#!/bin/sh
# Brings the red lane's tests home from the worktrees the red-breaker agents worked
# in, and nothing else. Each worktree is an isolated checkout of the same
# repository; whatever an agent did to code there never reaches the project. But a
# finding that only fails because the agent also changed the code under test is
# a planted bug, so any change outside red.test_paths voids the whole run.
#
# Refuses (exit 1, copying nothing) when: a worktree is not a worktree of this
# repository; its commit is not the one red-guard.sh snapshot recorded; a file
# outside red.test_paths changed; a test file was deleted; or two worktrees (two
# lanes of one run) changed the same test file. Otherwise copies each changed test
# file into the project and lists it after "imported:".
# Ignored files the agents' test runs left behind (caches, build output) stay in
# the worktrees and do not count.
#
# --quarantine DIR salvages a voided run instead: it copies each worktree's
# changed test files into DIR/<worktree name>/ (DIR must be outside the project),
# whatever else the agent changed, and records nothing. The next run is briefed
# to judge and extend them; only a clean run's tests are ever imported.
#
# After copying, each imported test goes through the project's checks.on_edit
# rules whose paths match it, with SB_FILE set, exactly as an edit would; a rule
# that formats (ruff format, prettier --write) formats it now, before red-file.sh
# fingerprints it, instead of later, which would force a judge run and a re-pin.
# A rule that fails is reported and does not stop the import.
#
# Usage: red-import.sh WORKTREE... [--remove] [--quarantine DIR]   (from the project root)
#   --remove  delete each worktree afterwards (git worktree remove --force), and
#             its branch when it is one Claude Code made for an agent (worktree-agent-*)
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
usage="red-import: usage: red-import.sh WORKTREE... [--remove] [--quarantine DIR]"
wts= remove= quarantine=
while [ $# -gt 0 ]; do
  case "$1" in
    --remove) remove=1 ;;
    --quarantine) [ $# -ge 2 ] || { echo "$usage" >&2; exit 1; }; quarantine=$2; shift ;;
    *) [ -d "$1" ] || { echo "$usage ($1 is not a folder)" >&2; exit 1; }
       wts="$wts$(cd "$1" && pwd -P)
" ;;
  esac
  shift
done
[ -n "$wts" ] || { echo "$usage" >&2; exit 1; }

sb_load_config || { echo "red-import: no usable .claude/serial-build.json" >&2; exit 1; }
[ "$(sb_count "$SB_CFG" red.test_paths)" -gt 0 ] || { echo "red-import: no red.test_paths in .claude/serial-build.json" >&2; exit 1; }
cd "$SB_ROOT" || exit 1
ours=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
prefix=$(git rev-parse --show-prefix)
snap="$(sb_state_dir)/red-snapshot"
was=
if [ -z "$quarantine" ]; then
  [ -f "$snap" ] || { echo "red-import: no red-guard snapshot; the run cannot be checked" >&2; exit 1; }
  was=$(head -n 1 "$snap")
else
  mkdir -p "$quarantine" && quarantine=$(cd "$quarantine" && pwd -P) || { echo "red-import: cannot make $quarantine" >&2; exit 1; }
  here=$(pwd -P)
  case "$quarantine/" in "$here"/*) echo "red-import: the quarantine folder must be outside the project, or the next snapshot sees it: $quarantine" >&2; exit 1 ;; esac
fi

# changed_in WT: the project's changed files in that worktree, one per line.
changed_in() {
  _home=$SB_ROOT
  SB_ROOT="$1/${prefix%/}"; SB_ROOT=${SB_ROOT%/}
  sb_changed_files
  SB_ROOT=$_home
}

problems= plan=
while IFS= read -r wt; do
  [ -n "$wt" ] || continue
  theirs=$(cd "$wt" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
  if [ -z "$theirs" ] || [ "$ours" != "$theirs" ]; then echo "red-import: $wt is not a worktree of this repository" >&2; exit 1; fi
  proj="$wt/${prefix%/}"; proj=${proj%/}
  [ -d "$proj" ] || { echo "red-import: the worktree $wt has no $prefix" >&2; exit 1; }
  if [ -z "$quarantine" ]; then
    at=$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null || echo none)
    if [ "$was" != "$at" ]; then
      echo "red-import: the red run is void: the worktree $wt is at $at, not the snapshot's $was, so the agent committed or started elsewhere" >&2
      exit 1
    fi
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! sb_match_any "$f" "$SB_CFG" red.test_paths; then
      problems="$problems$f changed, and it is not a test (in $wt)
"
    elif [ ! -f "$proj/$f" ]; then
      problems="$problems$f, a test, was deleted (in $wt)
"
    else
      plan="$plan$f	$proj	$wt
"
    fi
  done <<EOF
$(changed_in "$wt")
EOF
done <<EOF
$wts
EOF

remove_all() {
  [ -n "$remove" ] || return 0
  printf '%s' "$wts" | while IFS= read -r wt; do
    branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)
    git worktree remove --force "$wt" && echo "red-import: removed the worktree $wt"
    case "$branch" in worktree-agent-*)
      git branch -D "$branch" >/dev/null 2>&1 && echo "red-import: deleted its branch $branch" ;;
    esac
  done
}

if [ -n "$quarantine" ]; then
  printf '%s' "$plan" | while IFS="$(printf '\t')" read -r f proj wt; do
    [ -n "$f" ] || continue
    d="$quarantine/$(basename "$wt")"
    mkdir -p "$d/$(dirname "$f")" && cp "$proj/$f" "$d/$f"
  done
  printf 'red-import: quarantined, not imported; nothing is recorded. The tests are in %s:\n%s' "$quarantine" "$(printf '%s' "$plan" | cut -f 1)"
  echo
  remove_all
  exit 0
fi

collide=$(printf '%s' "$plan" | cut -f 1 | LC_ALL=C sort | uniq -d)
[ -n "$collide" ] && problems="$problems$(printf '%s\n' "$collide" | sed 's/$/ was written by two lanes; give each lane its own test file names/')
"
if [ -n "$problems" ]; then
  printf 'red-import: the red run is void; nothing was copied. The red-breaker agents changed:\n%s' "$problems" >&2
  exit 1
fi
printf '%s' "$plan" | while IFS="$(printf '\t')" read -r f proj wt; do
  [ -n "$f" ] || continue
  mkdir -p "$SB_ROOT/$(dirname "$f")"
  cp "$proj/$f" "$SB_ROOT/$f"
done
# The project's on-edit rules, as an edit of each imported test would run them.
nrules=$(sb_count "$SB_CFG" checks.on_edit)
fmt=$(mktemp "${TMPDIR:-/tmp}/sb-import.XXXXXX") || exit 1
printf '%s' "$plan" | cut -f 1 | while IFS= read -r f; do
  [ -n "$f" ] || continue
  r=0
  while [ "$r" -lt "$nrules" ]; do
    run=$(sb_get "$SB_CFG" "checks.on_edit.$r.run") || { r=$((r + 1)); continue; }
    name=$(sb_get "$SB_CFG" "checks.on_edit.$r.name") || name=$run
    if printf '%s\n' "$f" | sb_filter "$SB_CFG" "checks.on_edit.$r.paths" | grep -q .; then
      if ! (cd "$SB_ROOT" && SB_FILE=$f sh -c "$run") > "$fmt" 2>&1; then
        printf 'red-import: note: the on-edit rule "%s" fails on %s (the test is imported as the agent wrote it):\n%s\n' "$name" "$f" "$(tail -n 5 "$fmt" | sed 's/^/    /')"
      fi
    fi
    r=$((r + 1))
  done
done
rm -f "$fmt"
printf 'red-import: copied only test files.\nimported:\n%s' "$(printf '%s' "$plan" | cut -f 1)"
echo
remove_all
exit 0
