#!/bin/sh
# PostToolUse on Read|Edit|Write|MultiEdit|Bash|Glob|Grep: when a tool names a
# path in the project's inbox (the folder other sessions drop files into, named by
# "inbox" in .claude/serial-build.json), leave a per-session marker so the stop
# hook checks this session left the inbox empty. No config or no inbox: exit 0.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/../.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
sb_load_config || exit 0
inbox=$(sb_inbox) || exit 0
[ -n "$inbox" ] || exit 0

input=$(sb_read_input "session_id tool_input.file_path tool_input.command tool_input.path tool_input.notebook_path tool_input.pattern")
named=
for key in tool_input.file_path tool_input.command tool_input.path tool_input.notebook_path tool_input.pattern; do
  named="$named $(sb_get "$input" "$key")"
done
case "$named" in *"$inbox"*) ;; *) exit 0 ;; esac
session=$(sb_get "$input" session_id) || session=unknown
marker="$(sb_state_dir)/inbox-$session"
[ -f "$marker" ] || : > "$marker"
exit 0
