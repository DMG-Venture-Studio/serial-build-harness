#!/bin/sh
# Scaffolds a project from the scope skill's templates and the owner's answers,
# and never overwrites a file the owner has not named. Everything renders into a
# staging folder first, so a missing answer fails before anything is written.
#
# Usage: render.sh --answers FILE --config FILE [--dest DIR] [--dry-run] [--overwrite PATH]...
#   --answers    JSON object of placeholder answers (see references/answers.md)
#   --config     the project's .claude/serial-build.json, written as given
#   --dest       the project root, default the working directory
#   --dry-run    print the tree with what would happen to each file, write nothing
#   --overwrite  a path relative to --dest the owner confirmed may be replaced;
#                repeat per file. Without it an existing file is kept as it is.
#
# Templates live under ../templates as <target path>.tmpl. A path segment starting
# "dot-" becomes "."; {{key}} in a path or a file is replaced by the answer. The
# rendered .gitignore is merged: an existing one gains only its missing lines.
# An existing CLAUDE.md without the "<!-- serial-build -->" marker gains the
# rendered one at its end, marker first, once; with the marker it is kept.
# The answers file is saved beside the scoping interview for later re-runs.
# Exit 0 done; 1 bad input; 3 answers missing (named on stderr).
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/../../.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
here=$(cd "$(dirname "$0")" && pwd)
templates="$here/../templates"

answers= config= dest=$(pwd) dry=0 overwrite=
while [ $# -gt 0 ]; do
  case "$1" in
    --answers) answers=$2; shift 2 ;;
    --config) config=$2; shift 2 ;;
    --dest) dest=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --overwrite) overwrite="$overwrite$2
"; shift 2 ;;
    *) echo "render: unknown argument $1" >&2; exit 1 ;;
  esac
done
[ -f "$answers" ] || { echo "render: --answers FILE is required" >&2; exit 1; }
[ -f "$config" ] || { echo "render: --config FILE is required" >&2; exit 1; }
[ -d "$dest" ] || { echo "render: --dest $dest is not a directory" >&2; exit 1; }
dest=$(cd "$dest" && pwd)

stage=$(mktemp -d "${TMPDIR:-/tmp}/sb-render.XXXXXX") || exit 1
trap 'rm -rf "$stage"' EXIT
flat="$stage/.answers" missing="$stage/.missing" out="$stage/out"
mkdir -p "$out"
: > "$missing"
if ! sb_flatten < "$answers" > "$flat" 2> "$stage/.err"; then
  echo "render: $answers is not valid JSON: $(cat "$stage/.err")" >&2; exit 1
fi
if ! report=$(sh "$SB_PLUGIN/scripts/check-config.sh" "$config"); then
  printf 'render: the config would leave the hooks misbehaving:\n%s\n' "$report" >&2; exit 1
fi
inbox=$(sb_get "$(cat "$flat")" inbox) || inbox=
case "$inbox" in ''|/*|*..*|*/*) echo "render: answers need \"inbox\", a single folder name such as claude_outputs" >&2; exit 1 ;; esac

render() { LC_ALL=C awk -v answers="$flat" -v missing="$missing" -f "$SB_SCRIPTS/json-decode.awk" -f "$here/render.awk"; }

(cd "$templates" && find . -type f -name '*.tmpl' | sed 's|^\./||' | sort) > "$stage/.list"
while IFS= read -r tpl; do
  target=$(printf '%s\n' "${tpl%.tmpl}" | awk -F / -v OFS=/ '{ for (i = 1; i <= NF; i++) { if (index($i, "dot-") == 1) $i = "." substr($i, 5) } print }' | render)
  mkdir -p "$out/$(dirname "$target")"
  render < "$templates/$tpl" > "$out/$target"
done < "$stage/.list"
mkdir -p "$out/.claude"
cp "$config" "$out/.claude/serial-build.json"
# The answers themselves join the scoping record, so a later /serial-build:scope
# can fill missing files without asking the whole interview again.
date=$(sb_get "$(cat "$flat")" date) || date=
if [ -n "$date" ]; then
  mkdir -p "$out/docs/decisions/sources"
  cp "$answers" "$out/docs/decisions/sources/scoping-answers-$date.json"
fi

if [ -s "$missing" ]; then
  printf 'render: these answers are missing, so nothing was written:\n' >&2
  sort "$missing" | sed 's/^/  /' >&2
  exit 3
fi
for j in $(cd "$out" && find . -name '*.json' | sed 's|^\./||'); do
  sb_flatten < "$out/$j" > /dev/null 2> "$stage/.err" || { echo "render: $j would not be valid JSON ($(cat "$stage/.err")); check its answers" >&2; exit 1; }
done

# .claude/settings.json belongs to Claude Code and often exists already (a
# project-scope plugin install writes one). Its worktree settings are merged in:
# added when it has none, left alone when it has its own.
settings_action() {
  _cur=$(sb_flatten < "$dest/.claude/settings.json" 2>/dev/null) || { echo "exists, kept: not valid JSON, add the worktree settings by hand"; return; }
  if [ -z "$_cur" ]; then echo "merge worktree settings"; return; fi
  if printf '%s\n' "$_cur" | grep -q '^worktree\.'; then
    if [ "$(sb_get "$_cur" worktree.baseRef)" = head ] && sb_get "$_cur" worktree.symlinkDirectories.# >/dev/null; then echo same
    else echo "exists, kept: add worktree.baseRef \"head\" and worktree.symlinkDirectories by hand"; fi
    return
  fi
  echo "merge worktree settings"
}
merge_settings() {
  _f="$dest/.claude/settings.json"
  if [ -z "$(sb_flatten < "$_f" 2>/dev/null)" ]; then cp "$out/.claude/settings.json" "$_f"; return 0; fi
  _links=$(sb_get "$(cat "$flat")" worktree_symlinks)
  awk -v links="$_links" '!done && sub(/^[ \t]*\{/, "&\n  \"worktree\": { \"baseRef\": \"head\", \"symlinkDirectories\": " links " },") { done = 1 } { print }' "$_f" > "$_f.sb-tmp"
  if sb_flatten < "$_f.sb-tmp" > /dev/null 2>&1; then mv "$_f.sb-tmp" "$_f"; else rm -f "$_f.sb-tmp"; echo "render: could not merge the worktree settings into .claude/settings.json; add them by hand" >&2; return 1; fi
}

# Decide what happens to each file, then print it as a tree.
(cd "$out" && find . -type f | sed 's|^\./||' | sort) > "$stage/.targets"
printf '%s' "$overwrite" > "$stage/.overwrite"
while IFS= read -r o; do
  [ -n "$o" ] || continue
  grep -qxF "$o" "$stage/.targets" || { echo "render: --overwrite $o is not a file this scaffold writes" >&2; exit 1; }
done < "$stage/.overwrite"
plan="$stage/.plan"
: > "$plan"
while IFS= read -r t; do
  if [ ! -e "$dest/$t" ]; then action=new
  elif cmp -s "$out/$t" "$dest/$t"; then action=same
  elif [ "$t" = .claude/settings.json ]; then action=$(settings_action)
  elif [ "$t" = .gitignore ]; then
    add=$(grep -vxF -f "$dest/.gitignore" "$out/.gitignore" | grep -c .)
    if [ "$add" -gt 0 ]; then action="append $add lines"; else action=same; fi
  elif grep -qxF "$t" "$stage/.overwrite"; then action=overwrite
  elif [ "$t" = CLAUDE.md ] && ! grep -qF '<!-- serial-build -->' "$dest/CLAUDE.md"; then
    action="append marked section"
  else action="exists, kept"
  fi
  printf '%s\t%s\n' "$t" "$action" >> "$plan"
done < "$stage/.targets"

echo "$dest"
awk -F '\t' '
function pad(k,   s) { s = ""; while (length(s) < k) s = s " "; return s }
{
  n = split($1, part, "/")
  path = ""
  for (i = 1; i < n; i++) {
    path = path part[i] "/"
    if (!(path in shown)) { shown[path] = 1; print pad(2 * i) part[i] "/" }
  }
  name = pad(2 * n) part[n]
  print name pad(48 - length(name)) " (" $2 ")"
}' "$plan"

[ "$dry" -eq 1 ] && exit 0

wrote=0 kept=0
while IFS="$(printf '\t')" read -r t action; do
  case "$action" in
    new|overwrite)
      mkdir -p "$dest/$(dirname "$t")"
      cp "$out/$t" "$dest/$t"
      wrote=$((wrote + 1)) ;;
    "merge worktree settings")
      merge_settings && wrote=$((wrote + 1)) ;;
    "append marked section")
      { [ -n "$(tail -c 1 "$dest/CLAUDE.md")" ] && echo; echo; cat "$out/CLAUDE.md"; } >> "$dest/CLAUDE.md"
      wrote=$((wrote + 1)) ;;
    append*)
      [ -n "$(tail -c 1 "$dest/.gitignore")" ] && echo >> "$dest/.gitignore"
      grep -vxF -f "$dest/.gitignore" "$out/.gitignore" | grep . >> "$dest/.gitignore"
      wrote=$((wrote + 1)) ;;
    "exists, kept"*) kept=$((kept + 1)) ;;
  esac
done < "$plan"
echo "render: wrote or merged $wrote files; kept $kept existing files unchanged."
