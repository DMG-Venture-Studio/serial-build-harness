#!/bin/sh
# The red lane's mechanical steps after the red-breaker agents return, in one call,
# so the session running /serial-build:red spends its turns on judgement, not on
# bookkeeping. It stops at the first step that fails:
#
#   1. Reads every response. A line in a Findings section that names a red
#      finding but is not in the agent's output form stops everything, with
#      nothing done: a finding it could not read must not vanish.
#   2. Refuses, with nothing done, while an agent worktree holds changes but was
#      not passed with --worktree, since its tests would be lost.
#   3. red-guard.sh verify: nothing but tests changed in the project. This
#      releases the red lock.
#   4. red-import.sh WORKTREE... --remove: only tests come home, and two lanes
#      did not write the same test file.
#   5. Refuses, recording nothing, when a finding's test is not in the project.
#   6. Re-runs each finding's Reproduce command from the project root, renaming a
#      finding whose slug is taken. One whose command passes now is recorded as an
#      attempt that found nothing, saying why. A command that changes any file
#      outside the test paths stops it, recording nothing.
#   7. Files the responses verbatim as one decision source,
#      docs/decisions/sources/red-<gate>-<date>[-n].md, one section per lane.
#   8. Appends the Red run to docs/plan.md's "## Red" section: the run line (with
#      --cost, if given), each finding with its test's git blob hash, and the
#      fruitless attempts. Runs voided since the last filing are recorded above
#      it as "Voided red run:" lines, so the done entry states the true cost.
#
# A void (3 or 4) records nothing in the project, remembers the void for the
# next filing, and prints the command that salvages the agents' tests. After a
# refusal in 5 or 6, run it again once fixed: verify passes again while only
# tests changed.
# Nothing is committed: judge the drafted section against the raw output (a
# finding counts only if it fails for the reason the agent gave), check it with
# red-status.sh --record, then commit.
#
# Usage: red-file.sh --output FILE [--output FILE]... [--worktree DIR]... [--cost "<text>"]
#   --output    a file holding one red-breaker agent's response, verbatim; one per lane
#   --worktree  an agent's worktree, when its result named one (it changed something)
#   --cost      what the run cost, as the harness reported it ("26 min, 1.4M tokens")
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
refuse() { printf 'red-file: %s\n' "$1" >&2; exit 1; }
outputs= wts= cost= runkind=
usage='usage: red-file.sh --output FILE [--output FILE]... [--worktree DIR]... [--cost "<text>"] [--delta | --partial]'
while [ $# -gt 0 ]; do
  case "$1" in
    --delta) runkind=" Delta run." ;;
    --partial) runkind=" Partial run." ;;
    --output) [ -f "${2:-}" ] || refuse "--output needs a file holding the agent's response"; outputs="$outputs$2
"; shift ;;
    --worktree) [ -d "${2:-}" ] || refuse "--worktree needs the agent's worktree folder"; wts="$wts$2
"; shift ;;
    --cost) cost=${2:-}; shift ;;
    *) refuse "$usage" ;;
  esac
  shift
done
[ -n "$outputs" ] || refuse "$usage"
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

# Read the responses first, so a response the script cannot read whole stops
# everything before anything is checked, moved, or recorded. Rows:
# F<TAB>slug<TAB>what<TAB>test<TAB>command<TAB>kind, A<TAB>attempt,
# I<TAB>an item for intake, U<TAB>a line that looks like a finding but is not one.
all=$(mktemp "${TMPDIR:-/tmp}/sb-file-all.XXXXXX") || exit 1
while IFS= read -r o; do [ -n "$o" ] && cat "$o" && printf '\n## End\n'; done > "$all" <<EOF
$outputs
EOF
rows=$(LC_ALL=C awk '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function flush(   slug, what, test, cmd, k) {
    if (cur == "") return
    if (kind == "F") {
      slug = cur; sub(/^([-*]|[0-9]+[.)]) +/, "", slug); sub(/:.*/, "", slug); slug = tolower(slug); gsub(/[_.]/, "-", slug)
      what = cur; sub(/^([-*]|[0-9]+[.)]) +[Rr][Ee][Dd]-[A-Za-z0-9_.-]*:[ ]*/, "", what); sub(/[ ]*(Kind|Test|Reproduce|Seen):.*/, "", what); sub(/[ .]*$/, "", what)
      k = "-"; if (index(cur, "Kind: ")) { k = cur; sub(/.*Kind: */, "", k); sub(/ *(Test|Reproduce|Seen):.*/, "", k); gsub(/`/, "", k); sub(/[ .]*$/, "", k) }
      test = "-"; if (match(cur, /Test: `?[^ `]+/)) { test = substr(cur, RSTART + 6, RLENGTH - 6); gsub(/`/, "", test); sub(/[.,;]$/, "", test) }
      cmd = "-"; if (match(cur, /Reproduce: `[^`]*`/)) cmd = substr(cur, RSTART + 12, RLENGTH - 13)
      printf "F\t%s\t%s\t%s\t%s\t%s\n", slug, what, test, cmd, k
    } else { a = cur; sub(/^([-*]|[0-9]+[.)]) +/, "", a); printf "%s\t%s\n", kind, a }
    cur = ""
  }
  /^#+ / { flush(); sec = tolower($0); if (sec !~ /attempt|intake/ && $0 ~ /[Rr][Ee][Dd]-[A-Za-z0-9]/) printf "U\t%s\n", trim($0); next }
  cur != "" && /^[ \t]+[^ \t]/ { cur = cur " " trim($0); next }
  { flush() }
  sec ~ /finding/ && /^([-*]|[0-9]+[.)]) +[Rr][Ee][Dd]-[A-Za-z0-9_.-]+:/ { kind = "F"; cur = trim($0); next }
  sec ~ /finding/ && /[Rr][Ee][Dd]-[A-Za-z0-9]/ { printf "U\t%s\n", trim($0); next }
  sec ~ /attempt/ && /^([-*]|[0-9]+[.)]) / && !/^- none\.?$/ { kind = "A"; cur = trim($0); next }
  sec ~ /intake/ && /^([-*]|[0-9]+[.)]) / && !/^- none\.?$/ { kind = "I"; cur = trim($0); next }
  sec !~ /attempt|intake/ && /Reproduce: `/ { printf "U\t%s\n", trim($0); next }
  END { flush() }' "$all")
rm -f "$all"
unread=$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "U" { print "  " $2 }')
if [ -n "$unread" ]; then
  printf 'red-file: these lines look like findings (a heading or line naming red-<slug>, or a Reproduce: command) but are not in the form "- red-<slug>: <what>. Kind: <class>. Test: <path>. Reproduce: `<command>`." directly under "## Findings", so nothing was done (the red lock is still held):\n%s\nAsk the agent to restate its findings in the form agents/red-breaker.md gives, save that response, and run red-file.sh again with it.\n' "$unread" >&2
  exit 1
fi

# A worktree an agent changed that is not passed in would be dropped unseen.
named=$(printf '%s' "$wts" | while IFS= read -r w; do [ -n "$w" ] && (cd "$w" && pwd -P); done)
prefix=$(git rev-parse --show-prefix)
left=$(for d in .claude/worktrees/*; do
  [ -e "$d/.git" ] || continue
  d=$(cd "$d" && pwd -P)
  printf '%s\n' "$named" | grep -qxF -- "$d" && continue
  home=$SB_ROOT; SB_ROOT="$d/${prefix%/}"; SB_ROOT=${SB_ROOT%/}
  [ -n "$(sb_changed_files)" ] && printf '  %s\n' "$d"
  SB_ROOT=$home
done)
if [ -n "$left" ]; then
  printf 'red-file: these agent worktrees hold changes but were not passed with --worktree, so their tests would be lost; nothing was done (the red lock is still held):\n%s\nPass each with --worktree (every lane'"'"'s), or remove one that is not this run'"'"'s.\n' "$left" >&2
  exit 1
fi

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

# Tests came back but the report names no finding: a report the script could
# not read is never filed as a clean run.
imported=$(printf '%s\n' "${im:-}" | sed -n '/^imported:$/,$p' | sed '1d; /^red-import:/d; /^$/d')
if [ -n "$imported" ] && ! printf '%s\n' "$rows" | grep -q '^F'; then
  printf 'red-file: the agents brought back these test files, but their reports hold no finding in the form "- red-<slug>: ..." under "## Findings", so nothing was recorded:\n%s\nThe tests are in the project, uncommitted. Ask the agent to restate its findings in the form agents/red-breaker.md gives, save that response, and run red-file.sh again with it (verify passes again while only tests changed).\n' "$(printf '%s\n' "$imported" | sed 's/^/  /')" >&2
  exit 1
fi

# Every finding with a command must have its test here now; a missing one is a
# mistake in filing, never a fruitless attempt.
missing=$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "F" && $5 != "-" { print $4 }' | while IFS= read -r t; do
  t=${t%%::*}; [ "$t" != - ] && [ -f "$t" ] || printf '  %s\n' "$t"
done)
if [ -n "$missing" ]; then
  printf 'red-file: these findings'"'"' tests are not in the project, so nothing was recorded:\n%s\nIf a worktree was not passed, bring its tests home with red-import.sh; if the agent named a wrong path, ask it to restate. Then run red-file.sh again (verify passes again while only tests changed).\n' "$missing" >&2
  exit 1
fi

# 4: re-run each finding, watching that no command changes anything but tests.
taken=$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$plan" | awk -F '\t' '$1 == "FIND" { print $3 }')
out=$(mktemp "${TMPDIR:-/tmp}/sb-file.XXXXXX") || exit 1
trap 'rm -f "$out" "$out.find" "$out.att" "$plan.sb-add" "$plan.sb-tmp"' EXIT
: > "$out.find"; : > "$out.att"
nontest() { # each changed file outside the test paths, with its checksum
  _all=$(sb_changed_files)
  _t=$(printf '%s\n' "$_all" | sb_filter "$SB_CFG" red.test_paths)
  printf '%s\n' "$_all" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$_t" | grep -qxF -- "$f" && continue
    printf '%s %s\n' "$f" "$(sb_sum "$f")"
  done
}
before=$(nontest)
printf '%s\n' "$rows" | awk -F '\t' '$1 == "A" { print "- " $2 }' >> "$out.att"
printf '%s\n' "$rows" | awk -F '\t' '$1 == "F"' | while IFS="$TAB" read -r _ slug what test cmd kind; do
  base=$slug k=1
  while printf '%s\n' "$taken" | grep -qx "$slug"; do k=$((k + 1)); slug="$base-$k"; done
  taken="$taken
$slug"
  path=${test%%::*}
  if [ "$cmd" = - ]; then
    printf -- '- %s: reported with no Reproduce command, so it is not a finding (%s)\n' "$what" "$base" >> "$out.att"
  elif (sh -c "$cmd") > "$out" 2>&1; then
    printf -- '- %s: re-run by red-file.sh, `%s` passed, so it is not a finding (%s)\n' "$what" "$cmd" "$base" >> "$out.att"
  else
    if [ "$kind" != - ] && [ -n "$kind" ]; then
      printf -- '- %s: %s. Kind: `%s`. Test: `%s@%s`. Reproduce: `%s`.\n' "$slug" "$what" "$kind" "$path" "$(git hash-object "$path")" "$cmd" >> "$out.find"
    else
      printf -- '- %s: %s. Test: `%s@%s`. Reproduce: `%s`.\n' "$slug" "$what" "$path" "$(git hash-object "$path")" "$cmd" >> "$out.find"
    fi
  fi
done
after=$(nontest)
if [ "$before" != "$after" ]; then
  printf 'red-file: a reproduce command changed files that are not tests, so nothing was recorded. Restore them, and ask the agent for commands that only run its tests:\n%s\n' "$(printf '%s\n%s\n' "$before" "$after" | LC_ALL=C sort | uniq -u | cut -d ' ' -f 1 | LC_ALL=C sort -u | sed 's/^/  /')" >&2
  exit 1
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

# 5: the Red run, appended to the plan's Red section.
nf=$(grep -c . "$out.find")
na=$(grep -c . "$out.att")
{
  if [ -s "$voids" ]; then cat "$voids"; echo; fi
  printf 'Red run: %s, %s attempts, %s findings. Source: `%s`.%s' "$today" "$((nf + na))" "$nf" "$src" "$runkind"
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
kinds=$(sed -n 's/.* Kind: `\([^`]*\)`.*/\1/p' "$out.find" | LC_ALL=C sort | uniq -c | sed 's/^ *\([0-9]*\) /\1 x /')
if [ -n "$kinds" ]; then
  printf '\nred-file: the findings fall into these kinds; fix each kind once, with one test that enumerates the class, not one fix per case:\n%s\n' "$(printf '%s\n' "$kinds" | sed 's/^/  /')"
fi
intake=$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "I" { print "  - " $2 }')
if [ -n "$intake" ]; then
  printf '\nred-file: these are for /serial-build:intake, not the plan (message wording, or outside this gate):\n%s\n' "$intake"
fi
if [ -n "$runkind" ] && [ "$runkind" = " Delta run." ] && [ "$nf" -gt 0 ]; then
  deltas=$(awk '/^Red run:.* Delta run\./ && !/ 0 findings\./' "$plan" | grep -c .)
  if [ "$deltas" -ge 2 ]; then
    printf '\nred-file: STOP. This is the second delta run with findings. Another round would patch the next neighbour; ask the owner whether the gate'"'"'s scope or the fix approach is wrong before any more fixing.\n'
  fi
fi
printf '\nred-file: read each finding against the raw output (it counts only if it fails for the reason the agent gave), then commit the tests, the source, and the plan.\n'
exit 0
