#!/bin/sh
# Stop: runs each "checks.on_stop" rule (usually a test suite) when files under
# its paths have uncommitted changes, so a session cannot end its turn on red tests
# it caused. The result is remembered by a checksum of the changed files: an
# unchanged tree never re-runs, whether it last passed or failed. A failure blocks
# (exit 2, keeping the session working, with the failure on stderr) only the first
# time that exact tree fails; ending the turn again on the same tree is allowed,
# because re-running a suite that holds a committed red-lane test would otherwise
# block every turn. Never blocks while stop_hook_active is set, so it cannot loop.
# The failure is kept for the session-start hook, so the next session is told.
# Paths are relative to the project, which may be a subfolder of a larger
# repository. Needs git to see what changed; without it, does nothing.
# No config: exit 0, silent.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/../.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
sb_load_config || exit 0

input=$(sb_read_input "stop_hook_active")
[ "$(sb_get "$input" stop_hook_active)" = true ] && exit 0
n=$(sb_count "$SB_CFG" checks.on_stop)
[ "$n" -gt 0 ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
git -C "$SB_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

changed=$(sb_changed_files)
[ -n "$changed" ] || exit 0

state=$(sb_state_dir)
out=$(mktemp "${TMPDIR:-/tmp}/sb-stop.XXXXXX") || exit 0
trap 'rm -f "$out"' EXIT
status=0
i=0
while [ "$i" -lt "$n" ]; do
  rule="checks.on_stop.$i"
  stamp="$state/stop-$i"
  i=$((i + 1))
  run=$(sb_get "$SB_CFG" "$rule.run") || continue
  name=$(sb_get "$SB_CFG" "$rule.name") || name=$run
  matched=$(printf '%s\n' "$changed" | sb_filter "$SB_CFG" "$rule.paths")
  [ -n "$matched" ] || continue
  fingerprint=$( { printf '%s\n%s\n' "$run" "$matched"
    printf '%s\n' "$matched" | (cd "$SB_ROOT" && tr '\n' '\0' | xargs -0 cksum 2>/dev/null); } | sb_hash)
  last=$(cat "$stamp" 2>/dev/null)
  if [ "$last" = "$fingerprint:pass" ]; then continue; fi
  if [ "$last" = "$fingerprint:fail" ]; then
    printf '%s still fails on these unchanged files; it already said why, so this turn may end.\n' "$name"
    continue
  fi
  if sb_run_rule "$run" "$out"; then
    printf '%s\n' "$fingerprint:pass" > "$stamp"
    rm -f "$stamp.why"
    printf '%s passed on the uncommitted changes.\n' "$name"
  else
    printf '%s\n' "$fingerprint:fail" > "$stamp"
    { printf '%s failed at the last turn end (command: %s):\n' "$name" "$run"; tail -n 10 "$out"; } > "$stamp.why"
    printf '%s failed on the uncommitted changes (command: %s):\n%s\n' "$name" "$run" "$(tail -n 40 "$out")" >&2
    status=2
  fi
done
exit $status
