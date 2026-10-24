#!/bin/sh
# The red lane's mechanical steps after the red-breaker agents return, in one call,
# so the session running /serial-build:red spends its turns on judgement, not on
# bookkeeping. In order, stopping at the first that fails:
#
#   1. red-guard.sh verify: nothing but tests changed in the project. This
#      releases the red lock.
#   2. red-import.sh WORKTREE... --remove: only tests come home, and two lanes
#      did not write the same test file.
#   3. Files the agents' responses verbatim as one decision source,
#      docs/decisions/sources/red-<gate>-<date>[-n].md, one section per lane.
#   4. Reads each response's findings and fruitless attempts, renames a finding
#      whose slug is already taken, and re-runs each finding's Reproduce command
#      from the project root. A finding whose command passes now, or whose test did
#      not come back, is recorded as an attempt that found nothing, saying why.
#   5. Appends the Red run to docs/plan.md's "## Red" section: the run line (with
#      --cost, if given), each finding with its test's git blob hash, and the
#      fruitless attempts. Runs voided since the last filing are recorded above
#      it as "Voided red run:" lines, so the done entry states the true cost.
#
# A void (step 1 or 2) records nothing in the project, remembers the void for the
# next filing, and prints the command that salvages the agents' tests.
# Nothing is committed: read the drafted section against the raw output (a
# finding counts only if it fails for the reason the agent gave), then commit.
#
# Usage: red-file.sh --output FILE [--output FILE]... [--worktree DIR]... [--cost "<text>"]
#   --output    a file holding one red-breaker agent's response, verbatim; one per lane
#   --worktree  an agent's worktree, when its result named one (it changed something)
#   --cost      what the run cost, as the harness reported it ("26 min, 1.4M tokens")
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
refuse() { printf 'red-file: %s\n' "$1" >&2; exit 1; }
outputs= wts= cost=
while [ $# -gt 0 ]; do
  case "$1" in
    --output) [ -f "${2:-}" ] || refuse "--output needs a file holding the agent's response"; outputs="$outputs$2
"; shift ;;
    --worktree) [ -d "${2:-}" ] || refuse "--worktree needs the agent's worktree folder"; wts="$wts$2
"; shift ;;
    --cost) cost=${2:-}; shift ;;
    *) refuse "usage: red-file.sh --output FILE [--output FILE]... [--worktree DIR]... [--cost \"<text>\"]" ;;
  esac
  shift
done
[ -n "$outputs" ] || refuse "usage: red-file.sh --output FILE [--output FILE]... [--worktree DIR]... [--cost \"<text>\"]"
sb_load_config || refuse "no usable .claude/serial-build.json"
cd "$SB_ROOT" || exit 1
plan=docs/plan.md
[ -f "$plan" ] || refuse "no docs/plan.md, so no gate to record a red run for"
gate=$(awk '/^# /{print substr($0, 3); exit}' "$plan")
today=$(date +%Y-%m-%d)
state=$(sb_state_dir)
voids="$state/red-voids"
TAB=$(printf '\t')

void() { # void REASON
  _why=$(printf '%s\n' "$1" | awk 'NR == 1 { f = $0 } NR == 2 { print; done = 1; exit } END { if (!done) print f }' | sed 's/^red-[a-z]*: //; s/\.$//')
  printf 'Voided red run: %s, %s. Why: %s.\n' "$today" "${cost:-cost not given}" "$_why" >> "$voids"
  printf '%s\n' "$1" >&2
  if [ -n "$wts" ]; then
    printf 'red-file: the run is void and nothing was recorded. Salvage its tests for the next run with:\n  sh "%s/scripts/red-import.sh"' "$SB_PLUGIN" >&2
    printf '%s' "$wts" | while IFS= read -r w; do printf ' "%s"' "$w" >&2; done
    printf ' --quarantine "$(mktemp -d)" --remove\n' >&2
  else
    echo "red-file: the run is void and nothing was recorded." >&2
  fi
  exit 1
}

# 1 and 2: the run is clean.
v=$(sh "$SB_SCRIPTS/red-guard.sh" verify 2>&1) || void "$v"
if [ -n "$wts" ]; then
  set --
  while IFS= read -r w; do [ -n "$w" ] && set -- "$@" "$w"; done <<EOF
$wts
EOF
  im=$(sh "$SB_SCRIPTS/red-import.sh" "$@" --remove 2>&1) || void "$im"
  printf '%s\n' "$im"
fi

# 3: the raw output, verbatim.
mkdir -p docs/decisions/sources
src="red-$gate-$today" k=1
while [ -e "docs/decisions/sources/$src.md" ]; do k=$((k + 1)); src="red-$gate-$today-$k"; done
lanes=$(printf '%s' "$outputs" | grep -c .)
{
  printf '# Source: the red-breaker agent'"'"'s output for %s, %s\n\n' "$gate" "$today"
  printf 'The red lane'"'"'s raw output, unedited, from %s agent(s) in one run. The "## Red" section of the plan for %s cites it.\n' "$lanes" "$gate"
  n=0
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    n=$((n + 1))
    printf '\n---\n\n'
    [ "$lanes" -gt 1 ] && printf '## Lane %s\n\n' "$n"
    cat "$o"
  done <<EOF
$outputs
EOF
} > "docs/decisions/sources/$src.md"

# 4: findings and attempts, as rows: F<TAB>slug<TAB>what<TAB>test<TAB>command, or A<TAB>attempt.
all=$(mktemp "${TMPDIR:-/tmp}/sb-file-all.XXXXXX") || exit 1
while IFS= read -r o; do [ -n "$o" ] && cat "$o" && printf '\n## End\n'; done > "$all" <<EOF
$outputs
EOF
rows=$(LC_ALL=C awk '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function flush(   slug, what, test, cmd) {
    if (cur == "") return
    if (kind == "F") {
      slug = cur; sub(/^- /, "", slug); sub(/:.*/, "", slug)
      what = cur; sub(/^- red-[a-z0-9-]*:[ ]*/, "", what); sub(/[ ]*Test:.*/, "", what); sub(/[ .]*$/, "", what)
      test = "-"; if (match(cur, /Test: `?[^ `]+/)) { test = substr(cur, RSTART + 6, RLENGTH - 6); gsub(/`/, "", test); sub(/[.,;]$/, "", test) }
      cmd = "-"; if (match(cur, /Reproduce: `[^`]*`/)) cmd = substr(cur, RSTART + 12, RLENGTH - 13)
      printf "F\t%s\t%s\t%s\t%s\n", slug, what, test, cmd
    } else printf "A\t%s\n", substr(cur, 3)
    cur = ""
  }
  /^#+ / { flush(); sec = tolower($0); next }
  cur != "" && /^[ \t]+[^ \t]/ { cur = cur " " trim($0); next }
  { flush() }
  sec ~ /finding/ && /^- red-[a-z0-9-]+:/ { kind = "F"; cur = trim($0); next }
  sec ~ /attempt/ && /^- / && !/^- none\.?$/ { kind = "A"; cur = trim($0); next }
  END { flush() }' "$all")
rm -f "$all"
taken=$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$plan" | awk -F '\t' '$1 == "FIND" { print $3 }')
out=$(mktemp "${TMPDIR:-/tmp}/sb-file.XXXXXX") || exit 1
trap 'rm -f "$out" "$out.find" "$out.att" "$plan.sb-add" "$plan.sb-tmp"' EXIT
: > "$out.find"; : > "$out.att"
printf '%s\n' "$rows" | awk -F '\t' '$1 == "A" { print "- " $2 }' >> "$out.att"
printf '%s\n' "$rows" | awk -F '\t' '$1 == "F"' | while IFS="$TAB" read -r _ slug what test cmd; do
  base=$slug k=1
  while printf '%s\n' "$taken" | grep -qx "$slug"; do k=$((k + 1)); slug="$base-$k"; done
  taken="$taken
$slug"
  path=${test%%::*}
  if [ "$cmd" = - ]; then
    printf -- '- %s: reported with no Reproduce command, so it is not a finding (%s)\n' "$what" "$base" >> "$out.att"
  elif [ "$path" = - ] || [ ! -f "$path" ]; then
    printf -- '- %s: its test %s did not come back from the worktree, so it is not a finding (%s)\n' "$what" "$path" "$base" >> "$out.att"
  elif (sh -c "$cmd") > "$out" 2>&1; then
    printf -- '- %s: re-run by red-file.sh, `%s` passed, so it is not a finding (%s)\n' "$what" "$cmd" "$base" >> "$out.att"
  else
    printf -- '- %s: %s. Test: `%s@%s`. Reproduce: `%s`.\n' "$slug" "$what" "$path" "$(git hash-object "$path")" "$cmd" >> "$out.find"
  fi
done

# 5: the Red run, appended to the plan's Red section.
nf=$(grep -c . "$out.find")
na=$(grep -c . "$out.att")
{
  if [ -s "$voids" ]; then cat "$voids"; echo; fi
  printf 'Red run: %s, %s attempts, %s findings. Source: `%s`.' "$today" "$((nf + na))" "$nf" "$src"
  [ -n "$cost" ] && printf ' Cost: %s.' "$cost"
  printf '\n\n'
  if [ "$nf" -gt 0 ]; then cat "$out.find"; echo; fi
  echo "Attempts that found nothing:"
  if [ "$na" -gt 0 ]; then cat "$out.att"; else echo "- none"; fi
} > "$plan.sb-add"
if grep -q '^## Red[[:space:]]*$' "$plan"; then
  awk -v f="$plan.sb-add" '
    function add(   l) { while ((getline l < f) > 0) print l }
    /^## Red[[:space:]]*$/ { inred = 1; print; next }
    inred && /^## / { print ""; add(); print ""; inred = 0; done = 1 }
    { print }
    END { if (!done) { print ""; add() } }' "$plan" > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
else
  { cat "$plan"; printf '\n## Red\n\n'; cat "$plan.sb-add"; } > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
fi
rm -f "$voids"
printf 'red-file: filed the raw output as `%s` and recorded this run in docs/plan.md (not committed):\n\n' "$src"
cat "$plan.sb-add"
tried=$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$plan" | awk -F '\t' '$1 == "TRIED" { print $2 }')
[ "$((nf + na))" -lt "${tried:-0}" ] && printf '\nred-file: warning: %s attempts is fewer than the %s on the plan'"'"'s Tried to break list; red-status counts only a run that covers the list (a delta run may be fewer if an earlier run covered it).\n' "$((nf + na))" "$tried"
printf '\nred-file: read each finding against the raw output (it counts only if it fails for the reason the agent gave), then commit the tests, the source, and the plan.\n'
exit 0
