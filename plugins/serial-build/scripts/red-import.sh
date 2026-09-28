#!/bin/sh
# Brings the red lane's tests home from the worktree the red-breaker agent worked
# in, and nothing else. The agent's worktree is an isolated checkout of the same
# repository; whatever it did to code there never reaches the project. But a
# finding that only fails because the agent also changed the code under test is
# a planted bug, so any change outside red.test_paths voids the whole run.
#
# Refuses (exit 1, copying nothing) when: the worktree is not a worktree of this
# repository; its commit is not the one red-guard.sh snapshot recorded; a file
# outside red.test_paths changed; or a test file was deleted. Otherwise copies
# each changed test file into the project and lists it after "imported:".
# Ignored files the agent's test runs left behind (caches, build output) stay in
# the worktree and do not count.
# Usage: red-import.sh WORKTREE [--remove]   (from the project root)
#   --remove  delete the worktree afterwards (git worktree remove --force), and
#             its branch when it is one Claude Code made for an agent (worktree-agent-*)
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
wt=${1:-}
remove=${2:-}

sb_load_config || { echo "red-import: no usable .claude/serial-build.json" >&2; exit 1; }
[ "$(sb_count "$SB_CFG" red.test_paths)" -gt 0 ] || { echo "red-import: no red.test_paths in .claude/serial-build.json" >&2; exit 1; }
[ -d "$wt" ] || { echo "red-import: usage: red-import.sh WORKTREE [--remove]" >&2; exit 1; }
wt=$(cd "$wt" && pwd -P)
cd "$SB_ROOT" || exit 1

ours=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
theirs=$(cd "$wt" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
[ -n "$theirs" ] && [ "$ours" = "$theirs" ] || { echo "red-import: $wt is not a worktree of this repository" >&2; exit 1; }

snap="$(sb_state_dir)/red-snapshot"
[ -f "$snap" ] || { echo "red-import: no red-guard snapshot; the run cannot be checked" >&2; exit 1; }
was=$(head -n 1 "$snap")
at=$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null || echo none)
if [ "$was" != "$at" ]; then
  echo "red-import: the red run is void: the worktree is at $at, not the snapshot's $was, so the agent committed or started elsewhere" >&2
  exit 1
fi

prefix=$(git rev-parse --show-prefix)
proj="$wt/${prefix%/}"
proj=${proj%/}
[ -d "$proj" ] || { echo "red-import: the worktree has no $prefix" >&2; exit 1; }

home=$SB_ROOT
SB_ROOT=$proj
changed=$(sb_changed_files)
SB_ROOT=$home
problems= tests=
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! sb_match_any "$f" "$SB_CFG" red.test_paths; then
    problems="$problems$f changed, and it is not a test
"
  elif [ ! -f "$proj/$f" ]; then
    problems="$problems$f, a test, was deleted
"
  else
    tests="$tests$f
"
  fi
done <<EOF
$changed
EOF

if [ -n "$problems" ]; then
  printf 'red-import: the red run is void; nothing was copied. In its worktree the red-breaker agent changed:\n%s' "$problems" >&2
  exit 1
fi
printf '%s' "$tests" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  mkdir -p "$SB_ROOT/$(dirname "$f")"
  cp "$proj/$f" "$SB_ROOT/$f"
done
printf 'red-import: copied only test files.\nimported:\n%s' "$tests"
if [ "$remove" = --remove ]; then
  branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)
  git worktree remove --force "$wt" && echo "red-import: removed the worktree $wt"
  case "$branch" in worktree-agent-*)
    git branch -D "$branch" >/dev/null 2>&1 && echo "red-import: deleted its branch $branch" ;;
  esac
fi
exit 0
