#!/bin/sh
# Stop: a session that touched the inbox must leave it empty, each item moved to
# its home or deleted, so the inbox never becomes a second, unreviewed docs tree.
# Exit 2 with the remaining items on stderr, at most once per distinct listing
# (its checksum lives in the session marker), and never while stop_hook_active
# is set, so the block cannot loop. No config, no inbox, or untouched: exit 0.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/../.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
sb_load_config || exit 0
inbox=$(sb_inbox) || exit 0
[ -n "$inbox" ] || exit 0

input=$(sb_read_input "session_id stop_hook_active")
session=$(sb_get "$input" session_id) || session=unknown
marker="$(sb_state_dir)/inbox-$session"
[ -f "$marker" ] || exit 0
[ "$(sb_get "$input" stop_hook_active)" = true ] && exit 0

items=$(sb_inbox_items "$inbox")
if [ -z "$items" ]; then
  rm -f "$marker"
  exit 0
fi
hash=$(printf '%s' "$items" | sb_hash)
[ "$(cat "$marker")" = "$hash" ] && exit 0
printf '%s\n' "$hash" > "$marker"
printf '%s/ still holds items this session touched; move each to its home or delete it before stopping:\n%s\n' "$inbox" "$items" >&2
exit 2
