#!/bin/sh
# PreToolUse on Edit|Write|MultiEdit|NotebookEdit: refuses a hand edit to a file
# the project lists under "generated" in .claude/serial-build.json and names the
# command that regenerates it. A hand edit to a generated file is lost on the next
# regeneration, silently. Also refuses a hand edit to docs/done.md, the record of
# shipped gates: only scripts/ship-gate.sh writes it, after the red lane is clear,
# every proof passes, and the owner's acceptance words are given, so "done" is
# decided by code, not by whichever session holds the pen. Exit 2 blocks the call
# and shows stderr to the session. No config: exit 0, silent.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/../.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
sb_load_config || exit 0

input=$(sb_read_input "tool_input.file_path tool_input.notebook_path")
path=$(sb_get "$input" tool_input.file_path) || path=$(sb_get "$input" tool_input.notebook_path) || exit 0
[ -n "$path" ] || exit 0
rel=$(sb_rel_project "$path")

if [ "$rel" = docs/done.md ]; then
  printf 'Refusing a hand edit to docs/done.md, the record of shipped gates.\nShip a gate with: sh "%s/scripts/ship-gate.sh" <gate-slug> --accepted "<the owner'"'"'s words, verbatim>"\nMove a gate whose proof fails back to the roadmap with: sh "%s/scripts/ship-gate.sh" --regress <gate-slug> --failed "<the failing output>"\nAny other change to a done entry is the product owner'"'"'s call; ask them.\n' "$SB_PLUGIN" "$SB_PLUGIN" >&2
  exit 2
fi

n=$(sb_count "$SB_CFG" generated)
i=0
while [ "$i" -lt "$n" ]; do
  pattern=$(sb_get "$SB_CFG" "generated.$i.path") || pattern=
  if [ -n "$pattern" ] && sb_match "$rel" "$pattern"; then
    regenerate=$(sb_get "$SB_CFG" "generated.$i.regenerate") || regenerate="the generator named in docs/tech/architecture.md#toolchain"
    printf 'Refusing to edit a generated file: %s\nIt matches "%s" in .claude/serial-build.json; a hand edit is lost on the next regeneration.\nEdit the source instead, then run: %s\n' "$rel" "$pattern" "$regenerate" >&2
    exit 2
  fi
  i=$((i + 1))
done
exit 0
