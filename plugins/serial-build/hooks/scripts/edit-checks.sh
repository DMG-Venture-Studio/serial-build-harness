#!/bin/sh
# PostToolUse on Edit|Write|MultiEdit: runs each "checks.on_edit" rule whose
# paths match the edited file (lint, format check, a generator's drift check), so
# a violation is reported in the session that wrote it rather than in review.
# The rule's command runs with sh from the project root, with SB_FILE set to the
# edited path. Any failure: exit 2 with the output's tail on stderr, which the
# session reads and acts on. No config: exit 0, silent.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/../.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
sb_load_config || exit 0

input=$(sb_read_input "tool_input.file_path tool_input.notebook_path")
path=$(sb_get "$input" tool_input.file_path) || path=$(sb_get "$input" tool_input.notebook_path) || exit 0
rel=$(sb_rel "$path")
case "$rel" in /*|.claude/worktrees/*) exit 0 ;; esac

n=$(sb_count "$SB_CFG" checks.on_edit)
[ "$n" -gt 0 ] || exit 0
out=$(mktemp "${TMPDIR:-/tmp}/sb-edit.XXXXXX") || exit 0
trap 'rm -f "$out"' EXIT
status=0
i=0
while [ "$i" -lt "$n" ]; do
  rule="checks.on_edit.$i"
  i=$((i + 1))
  run=$(sb_get "$SB_CFG" "$rule.run") || continue
  sb_match_any "$rel" "$SB_CFG" "$rule.paths" || continue
  name=$(sb_get "$SB_CFG" "$rule.name") || name=$run
  if ! SB_FILE=$rel sb_run_rule "$run" "$out"; then
    printf '%s failed after the edit to %s (command: %s):\n%s\n' "$name" "$rel" "$run" "$(tail -n 40 "$out")" >&2
    status=2
  fi
done
exit $status
