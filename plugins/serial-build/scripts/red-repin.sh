#!/bin/sh
# Re-records a red finding's test after a fix had to change the test itself (an
# import that moved, a renamed function). Without this, the changed test no longer
# matches the fingerprint the red lane recorded, and the finding can only stay open
# or be demoted, which drops its proof from done.
#
# Refuses unless the changed test still catches the bug: it checks out the commit
# that recorded the finding (from before the fix) into a temporary worktree, puts
# the changed test there, and requires the finding's Reproduce command to FAIL.
# It also requires the red-breaker agent's confirmation that the changed test
# asserts the same behaviour, filed under the decision sources (the /serial-build:red
# skill's re-pin run). Then it adds "Re-pinned red-<slug>: ..." to the plan's Red
# section and commits the test and the plan as "serial-build: re-pin red-<slug>",
# the only form red-status.sh accepts. Several findings judged by one confirmation
# are re-pinned together, all or none, in one commit naming each of them.
#
# Caveat: a test that fails on the old commit for an unrelated reason (it imports
# something only the fix created) passes this check; the breaker's confirmation is
# what covers that. Directories listed in worktree.symlinkDirectories in
# .claude/settings.json are linked into the temporary worktree so tests can run.
# Usage: red-repin.sh <red-slug>... --source <slug of the filed confirmation>   (from the project root)
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
SB_ROOT=$(sb_project_root)
cd "$SB_ROOT" || exit 1
plan=docs/plan.md
refuse() { printf 'red-repin: %s\n' "$1" >&2; exit 1; }

slugs=
while [ $# -gt 0 ] && [ "$1" != --source ]; do slugs="$slugs $1"; shift; done
[ -n "$slugs" ] && [ "${1:-}" = --source ] && [ -n "${2:-}" ] || refuse "usage: red-repin.sh <red-slug>... --source <slug of the red-breaker agent's confirmation>"
src=$2
[ -f "docs/decisions/sources/$src.md" ] || refuse "docs/decisions/sources/$src.md does not exist; file the red-breaker agent's confirmation there first"
[ -f "$plan" ] || refuse "no docs/plan.md"
since=$(git log --diff-filter=A --format=%H -1 -- "$plan" 2>/dev/null)
prefix=$(git rev-parse --show-prefix)
links=
[ -f .claude/settings.json ] && links=$(sb_flatten < .claude/settings.json 2>/dev/null)
tmps=
trap 'for t in $tmps; do git worktree remove --force "$t" >/dev/null 2>&1; rm -f "$t.out"; done' EXIT

lines= paths=
for slug in $slugs; do
  row=$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$plan" | awk -F '\t' -v s="$slug" '$1 == "FIND" && $3 == s { t = $4; c = $5 } END { if (t != "") print t "\t" c }')
  [ -n "$row" ] || refuse "docs/plan.md records no finding $slug"
  test=$(printf '%s' "$row" | cut -f 1)
  cmd=$(printf '%s' "$row" | cut -f 2)
  path=${test%@*}
  [ -f "$path" ] || refuse "the test $path does not exist"
  [ "$cmd" != - ] || refuse "$slug has no Reproduce command"
  red=$(git log --reverse --format=%H -S"- $slug:" -- "$plan" 2>/dev/null | while IFS= read -r c; do
    if git merge-base --is-ancestor "$since" "$c" 2>/dev/null; then printf '%s\n' "$c"; break; fi
  done)
  [ -n "$red" ] || refuse "no commit recorded $slug; commit the red run first"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sb-repin.XXXXXX") || exit 1
  rmdir "$tmp"
  git worktree add -q --detach "$tmp" "$red" || refuse "could not check out $red"
  tmps="$tmps $tmp"
  there="$tmp/${prefix%/}"; there=${there%/}
  k=0 m=$(sb_count "$links" worktree.symlinkDirectories)
  while [ "$k" -lt "$m" ]; do
    d=$(sb_get "$links" "worktree.symlinkDirectories.$k")
    [ -e "$SB_ROOT/$d" ] && [ ! -e "$there/$d" ] && ln -s "$SB_ROOT/$d" "$there/$d"
    k=$((k + 1))
  done
  mkdir -p "$there/$(dirname "$path")"
  cp "$path" "$there/$path"
  if (cd "$there" && sh -c "$cmd") > "$tmp.out" 2>&1; then
    refuse "the changed test for $slug passes on $red, from before the fix, so it no longer catches the bug; nothing is re-pinned"
  fi
  blob=$(git hash-object "$path")
  lines="${lines}Re-pinned $slug: Test: \`$path@$blob\`. Still fails on $red, from before the fix. Source: \`$src\`.
"
  paths="$paths$path
"
done

printf '%s' "$lines" > "$plan.sb-add"
awk -v f="$plan.sb-add" '
  function add(   l) { while ((getline l < f) > 0) print l }
  /^## Red[[:space:]]*$/ { inred = 1 }
  inred && /^## / && !/^## Red/ { add(); print ""; inred = 0; done = 1 }
  { print }
  END { if (!done) { print ""; add() } }' "$plan" > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
rm -f "$plan.sb-add"
names=$(printf '%s' "$slugs" | sed 's/^ //')
set -- "$plan"
while IFS= read -r p; do [ -n "$p" ] && set -- "$@" "$p"; done <<EOF
$(printf '%s' "$paths" | sort -u)
EOF
git add -- "$@" && git commit -q -m "serial-build: re-pin $names" -- "$@" || refuse "could not commit the re-pin"
printf '%s' "$lines" | sed 's/^Re-pinned \(red-[^:]*\): Test: `\([^`]*\)`.*/red-repin: \1 re-pinned to \2; it still fails before the fix./'
