#!/bin/sh
# The red lane's guarantee that the breaker changed nothing it should not.
# The red-breaker agent works in its own git worktree (an isolated checkout that
# shares this repository's .git), and red-import.sh copies back only its tests.
# This script checks the other side: that the main checkout, and the parts of
# .git every worktree shares, are exactly as they were.
#
#   snapshot  refuses unless the project's work is committed (the worktree is cut
#             from the last commit, so uncommitted work would go unattacked), and
#             unless no watched ignored file was modified in the last two minutes
#             (something still writing into the project, such as a dev-stack
#             daemon's log, would void the run; it is named so it can be stopped
#             first). Then records the commit, a checksum of every ignored file in
#             the project (a planted .env or sitecustomize.py hides there), and of
#             .git's config, info/exclude, info/attributes, and hooks (a planted
#             post-commit hook or exclude rule hides there), and takes the red
#             lock: the red-lock hook refuses every agent but the red-breaker
#             writes into the project until verify or abort.
#   verify    fails, voiding the red run, when the commit moved, any shared .git
#             file changed, any file outside red.test_paths changed, or an ignored
#             file appeared, changed, or vanished. Test files that changed are
#             listed after "tests:". Releases the red lock either way.
#   abort     voids the run in progress and releases the red lock, for a run
#             that hung or a lock a crashed session left behind.
#
# .git/config is compared by its settings, not its bytes, with core.hooksPath
# resolved to an absolute path: Claude Code's worktree creation rewrites a
# relative hooksPath as the same folder's absolute path, which is no change.
# SB_RED_QUIET_MINUTES sets the preflight's window (default 2; 0 turns it off).
#
# The project may be a subfolder of a larger repository. Residual gap: a file
# inside an ignored folder (node_modules/) that is modified and then back-dated
# with touch. The worktree isolation, not this check, keeps that from the project.
# Usage: red-guard.sh snapshot | verify | abort    (from the project root)
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
mode=${1:-}

if ! sb_load_config; then
  echo "red-guard: no usable .claude/serial-build.json in $SB_ROOT; the red lane needs its red.test_paths" >&2
  exit 1
fi
if [ "$(sb_count "$SB_CFG" red.test_paths)" -eq 0 ]; then
  echo "red-guard: .claude/serial-build.json has no red.test_paths; the red lane cannot tell a test from the code under test" >&2
  exit 1
fi
git -C "$SB_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "red-guard: $SB_ROOT is not in a git work tree" >&2; exit 1; }
cd "$SB_ROOT" || exit 1
state=$(sb_state_dir)
snap="$state/red-snapshot"
marker="$state/red-snapshot.time"
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)

lock=$(sb_red_lock)
mkdir -p "$(dirname "$lock")"
head_of() { git rev-parse -q --verify HEAD 2>/dev/null || echo none; }
top=$(git rev-parse --show-toplevel)

# config_sig: .git/config's settings, with a relative core.hooksPath resolved
# against the main checkout's top, where hooks run; its bytes if git cannot read it.
config_sig() {
  if _list=$(git config --file "$common/config" --list 2>/dev/null); then
    printf '%s\n' "$_list" | while IFS= read -r _l; do
      case "$_l" in
        core.hookspath=*)
          _v=${_l#core.hookspath=}
          case "$_v" in /*) ;; *) _v="$top/$_v" ;; esac
          [ -d "$_v" ] && _v=$(cd "$_v" && pwd -P)
          printf 'core.hookspath=%s\n' "${_v%/}" ;;
        *) printf '%s\n' "$_l" ;;
      esac
    done | sb_hash
  else
    sb_sum "$common/config"
  fi
}

# Folders Claude Code symlinks into every worktree (worktree.symlinkDirectories
# in .claude/settings.json, such as node_modules): the breaker's test runs write
# caches into them through the link, so they are not watched. A file planted in
# one reaches the project; that residual risk is the price of runnable tests.
shared=
if [ -f .claude/settings.json ]; then
  _links=$(sb_flatten < .claude/settings.json 2>/dev/null)
  _k=0 _m=$(sb_count "$_links" worktree.symlinkDirectories)
  while [ "$_k" -lt "$_m" ]; do
    shared="$shared$(sb_get "$_links" "worktree.symlinkDirectories.$_k")
"
    _k=$((_k + 1))
  done
fi
shared_out() {
  SB_SHARED=$shared awk 'BEGIN { n = split(ENVIRON["SB_SHARED"], d, "\n") }
    { for (i = 1; i <= n; i++) if (d[i] != "" && ($0 == d[i] || $0 == d[i] "/" || index($0, d[i] "/") == 1)) next; print }'
}

# One line per watched thing: kind<TAB>signature<TAB>name.
inventory() {
  printf 'git\t%s\tconfig\n' "$(config_sig)"
  for f in info/exclude info/attributes; do printf 'git\t%s\t%s\n' "$(sb_sum "$common/$f")" "$f"; done
  if [ -d "$common/hooks" ]; then
    (cd "$common/hooks" && find . -type f | LC_ALL=C sort) | while IFS= read -r f; do
      printf 'git\t%s\thooks/%s\n' "$(sb_sum "$common/hooks/$f")" "${f#./}"
    done
  fi
  git -c core.quotePath=false ls-files -z --others --ignored --exclude-standard --directory -- . "$SB_NOT_WORKTREES" "$SB_NOT_LOCAL" 2>/dev/null \
    | tr '\0' '\n' | sed '/^$/d' | sb_drop_local | LC_ALL=C sort | shared_out | while IFS= read -r f; do
    case "$f" in
      */) printf 'dir\t%s\t%s\n' "$(find "./$f" -type f 2>/dev/null | wc -l | tr -d ' ')" "$f" ;;
      *) printf 'ignored\t%s\t%s\n' "$(sb_sum "$f")" "$f" ;;
    esac
  done
}

case "$mode" in
  snapshot)
    if [ -f "$lock" ]; then
      echo "red-guard: a red run already holds the red lock; finish it (red-file.sh, or red-guard.sh verify) or void it with red-guard.sh abort before a new snapshot, or what was written in between would never be checked" >&2
      exit 1
    fi
    dirty=$(sb_changed_files)
    if [ -n "$dirty" ]; then
      printf 'red-guard: commit the gate'"'"'s work first. The red-breaker agent attacks a worktree cut from the last commit, so these uncommitted changes would go unattacked:\n%s\n' "$dirty" >&2
      exit 1
    fi
    quiet=${SB_RED_QUIET_MINUTES:-2}
    if [ "$quiet" -gt 0 ] 2>/dev/null; then
      busy=$(inventory | awk -F '\t' '$1 == "ignored" || $1 == "dir" { print $3 }' | while IFS= read -r f; do
        find "./$f" -type f -mmin "-$quiet" 2>/dev/null | head -n 3
      done | sed 's|^\./||' | head -n 10)
      if [ -n "$busy" ]; then
        printf 'red-guard: something is still writing into the project; stop it first (a dev server, a daemon, a watcher, another session) or wait until nothing has written for that long, then snapshot again. Modified in the last %s minutes:\n%s\n' "$quiet" "$busy" >&2
        exit 1
      fi
    fi
    { head_of; inventory; } > "$snap"
    : > "$marker"
    printf '%s\n' "$(head -n 1 "$snap")" > "$lock"
    echo "red-guard: snapshot at $(head -n 1 "$snap"), $(($(wc -l < "$snap") - 1)) watched files and folders"
    echo "red-guard: the red lock is held; until verify (or abort), only the red-breaker agent may write into the project."
    ;;
  abort)
    rm -f "$lock" "$snap" "$marker"
    echo "red-guard: the red run is void and the red lock is released; take a new snapshot before the next run."
    ;;
  verify)
    [ -f "$snap" ] || { echo "red-guard: no snapshot; run 'red-guard.sh snapshot' before the red-breaker agent" >&2; exit 1; }
    rm -f "$lock"
    problems=
    was=$(head -n 1 "$snap")
    now=$(head_of)
    [ "$was" = "$now" ] || problems="the commit moved from $was to $now; the red-breaker agent must not commit
"
    inventory | LC_ALL=C sort > "$state/red-now"
    tail -n +2 "$snap" | LC_ALL=C sort > "$state/red-was"
    moved=$(LC_ALL=C comm -3 "$state/red-was" "$state/red-now" | sed 's/^	//' | cut -f 1,3 | LC_ALL=C sort -u)
    gitmoved=$(printf '%s\n' "$moved" | awk -F '\t' '$1 == "git" { print ".git/" $2 " changed; every worktree shares it" }' | LC_ALL=C sort -u)
    [ -n "$gitmoved" ] && problems="$problems$gitmoved
"
    changed=$(printf '%s\n' "$moved" | awk -F '\t' '$1 != "git" && $2 != "" { print $2 }')
    newer=$(awk -F '\t' '$1 == "dir" { print $3 }' "$state/red-now" | while IFS= read -r d; do
      [ -n "$(find "./$d" -type f -newer "$marker" 2>/dev/null | head -n 1)" ] && printf '%s\n' "$d"
    done)
    all=$(printf '%s\n%s\n%s\n' "$changed" "$newer" "$(sb_changed_files | shared_out)" | sed '/^$/d' | LC_ALL=C sort -u)
    tests=$(printf '%s\n' "$all" | sb_filter "$SB_CFG" red.test_paths)
    others=$(printf '%s\n' "$all" | grep -vxF -e "$tests" -e '' 2>/dev/null)
    [ -z "$tests" ] && others=$all
    [ -n "$others" ] && problems="$problems$(printf '%s\n' "$others" | sed 's/$/ changed, and it is not a test/')
"
    tests="$tests
"
    rm -f "$state/red-now" "$state/red-was"
    if [ -n "$problems" ]; then
      printf 'red-guard: the red run is void; something other than tests changed while the red-breaker agent ran:\n%s' "$(printf '%s' "$problems" | LC_ALL=C sort -u)" >&2
      echo >&2
      exit 1
    fi
    printf 'red-guard: nothing but tests changed.\ntests:\n%s' "$(printf '%s' "$tests" | LC_ALL=C sort -u)"
    echo
    ;;
  *)
    echo "usage: red-guard.sh snapshot | verify | abort" >&2
    exit 2
    ;;
esac
