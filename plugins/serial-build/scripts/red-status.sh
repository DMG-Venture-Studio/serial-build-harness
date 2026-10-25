#!/bin/sh
# Whether the active gate may hand off, as far as the red lane goes. A gate with
# no credible red run, or with a red finding that is not fixed, does not ship.
# Open or resolved is computed, never declared.
#
# Reads the "## Red" section of docs/plan.md (see red-record.awk for the rows):
#
#   Red run: <date>, <N> attempts, <F> findings. Source: `<raw output's slug>`.
#
#   - red-<slug>: <what breaks>. Test: `<path>@<git blob>`. Reproduce: `<command>`.
#     (a finding may wrap onto indented lines)
#
#   Attempts that found nothing:
#   - <attack>: <what ran, what happened>
#
#   Demoted red-<slug>: "<the owner's words>"            (written only by ship-gate.sh --demote)
#   Re-pinned red-<slug>: Test: `<path>@<blob>`. ...     (written only by red-repin.sh)
#
# A run is credible when: N >= 1; it lists its fruitless attempts; those plus its
# findings add up to at least N; it has exactly F findings; and its raw output is
# filed under docs/decisions/sources/<slug>.md. At least one run must declare at
# least as many attempts as the plan's "Tried to break" list has bullets; a run
# marked "Partial run." counts together with the run after it.
#
# A finding is resolved only when all hold: its test file exists with the content
# recorded (the latest re-pin's blob, else the finding's); its bullet is unchanged
# since the commit that recorded it; and its Reproduce command passes. Demote and
# re-pin lines count only when introduced by a commit their script made. History
# is searched only since the current docs/plan.md was added, so a red slug reused
# from an earlier gate does not collide.
#
# Exit 1 when the record is not credible or any finding is open; 0 otherwise.
#
# The verdict is remembered for the exact tree it was computed on (the commit, the
# plan, and every uncommitted file's content), so asking again on an unchanged tree
# answers at once instead of re-running every reproduce command. --fresh ignores
# what is remembered; ship-gate.sh always passes it, since a remembered verdict is
# a file in the temp folder and the ship must not rest on one. A change outside
# git's view (an ignored dependency folder) needs --fresh to be seen.
# --record checks only that the record is well formed, on the uncommitted plan,
# so a drafted Red run can be fixed before its first commit; after that, any
# change to a run reopens its findings.
# Usage: red-status.sh [--fresh | --record] [project root, default: the working directory]
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
fresh= record=
case "${1:-}" in --fresh) fresh=1; shift ;; --record) record=1; fresh=1; shift ;; esac
root=${1:-$(sb_project_root)}
cd "$root" || exit 1
plan=docs/plan.md
TAB=$(printf '\t')

if [ -z "$fresh" ] && [ -f "$plan" ] && git rev-parse -q --verify HEAD >/dev/null 2>&1; then
  SB_ROOT=$(pwd)
  changed=$(sb_changed_files)
  memo="$(sb_state_dir)/red-status-$( { git rev-parse HEAD; cksum < "$plan"; printf '%s\n' "$changed"
    printf '%s\n' "$changed" | sed '/^$/d' | tr '\n' '\0' | xargs -0 cksum 2>/dev/null; } | sb_hash)"
  if [ -f "$memo" ]; then
    echo "red-status: the tree is unchanged since this verdict was computed, so it is not re-run (--fresh re-runs it)."
    tail -n +2 "$memo"
    exit "$(head -n 1 "$memo")"
  fi
  out=$(sh "$0" --fresh "$root"); code=$?
  { printf '%s\n' "$code"; printf '%s\n' "$out"; } > "$memo"
  printf '%s\n' "$out"
  exit "$code"
fi

[ -f "$plan" ] || { echo "red-status: no docs/plan.md, so no active gate to check"; exit 1; }
gate=$(awk '/^# /{print substr($0, 3); exit}' "$plan")
records=$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$plan")
rows() { printf '%s\n' "$records" | awk -F '\t' -v k="$1" '$1 == k'; }

problems=
tried=$(rows TRIED | cut -f 2)
runs=$(rows RUN | grep -c .)
if [ "$runs" -eq 0 ]; then
  echo "red-status: $gate has no red run recorded in docs/plan.md; run /serial-build:red before handing off"
  exit 1
fi
most=0 prev=0
while IFS="$TAB" read -r kind r n d src has att found runline; do
  [ "$kind" = RUN ] || continue
  [ "$n" = - ] && n=0
  [ "$src" = - ] && src=
  [ "$n" -gt "$most" ] && most=$n
  # A partial run (finished slices only, while the builder waited) and the run
  # after it cover the list together.
  [ $((prev + n)) -gt "$most" ] && [ "$prev" -gt 0 ] && most=$((prev + n))
  case "$runline" in *" Partial run."*) prev=$n ;; *) prev=0 ;; esac
  [ "$n" -ge 1 ] || problems="${problems}run $r declares no attempts; a red run with nothing tried is not a red run
"
  [ "$has" = 1 ] || problems="${problems}run $r has no \"Attempts that found nothing:\" list
"
  [ $((att + found)) -ge "$n" ] || problems="${problems}run $r declares $n attempts but lists only $att fruitless attempts and $found findings
"
  [ "$d" = "$found" ] || problems="${problems}run $r declares $d findings but lists $found
"
  if [ -z "$src" ]; then
    problems="${problems}run $r names no Source: the red-breaker agent's raw output, filed under the decision sources
"
  elif [ ! -f "docs/decisions/sources/$src.md" ]; then
    problems="${problems}run $r cites Source: \`$src\`, but docs/decisions/sources/$src.md does not exist
"
  fi
done <<EOF
$(rows RUN)
EOF
[ "$most" -ge "${tried:-0}" ] || problems="${problems}no run (or partial run with the run after it) declares at least the $tried attempts on the plan's Tried to break list (the most is $most)
"
[ -n "$(rows ORPHAN)" ] && problems="${problems}a red finding sits above the first \"Red run:\" line
"
if [ -n "$problems" ]; then
  printf 'red-status: the red record for %s is not credible, so it does not hand off:\n%s' "$gate" "$(printf '%s' "$problems" | sed 's/^/  /')"
  echo
  exit 1
fi
if [ -n "$record" ]; then
  echo "red-status: the red record for $gate is well formed; commit it. (A run's line and findings cannot change once committed, so fix them before.)"
  exit 0
fi

# History since the current plan was added: the commits that may have recorded
# its findings, oldest first.
since=
if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
  since=$(git log --diff-filter=A --format=%H -1 -- "$plan" 2>/dev/null)
fi
# first_commit STRING: the oldest commit since the plan was added whose change
# to the plan adds STRING; empty when none (not yet committed).
first_commit() {
  [ -n "$since" ] || return 0
  git log --reverse --format=%H -S"$1" -- "$plan" 2>/dev/null | while IFS= read -r c; do
    if git merge-base --is-ancestor "$since" "$c" 2>/dev/null; then printf '%s\n' "$c"; break; fi
  done
}
# made_by LINE SUBJECT: the commit that added LINE says SUBJECT. A re-pin commit
# may name several findings ("serial-build: re-pin red-a red-b"); SUBJECT names one.
made_by() {
  _c=$(first_commit "$1")
  [ -n "$_c" ] || return 1
  _s=$(git log -1 --format=%s "$_c")
  [ "$_s" = "$2" ] && return 0
  case "$2" in "serial-build: re-pin "*) ;; *) return 1 ;; esac
  case "$_s" in "serial-build: re-pin "*) ;; *) return 1 ;; esac
  case " ${_s#serial-build: re-pin } " in *" ${2#serial-build: re-pin } "*) return 0 ;; esac
  return 1
}

out=$(mktemp "${TMPDIR:-/tmp}/sb-red.XXXXXX") || exit 1
old=$(mktemp "${TMPDIR:-/tmp}/sb-red-old.XXXXXX") || exit 1
trap 'rm -f "$out" "$old"' EXIT

# The record counts only as committed: an uncommitted edit could say anything.
if [ -n "$since" ]; then
  git show "HEAD:./$plan" > "$old" 2>/dev/null || : > "$old"
  if [ "$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$old")" != "$records" ]; then
    echo "red-status: $gate: the red record in docs/plan.md has uncommitted changes; it counts once committed (the /serial-build:red skill and the scripts that change it commit it)."
    exit 1
  fi
elif git rev-parse -q --verify HEAD >/dev/null 2>&1; then
  echo "red-status: $gate: docs/plan.md has never been committed; its red record counts once committed, so it can be checked against what the red lane recorded."
  exit 1
fi
# Each run as first committed. Run i is judged against the oldest commit, since
# the plan was added, whose plan held at least i runs: its "Red run:" line and
# its findings, in order, must be exactly as they are now. Position, not text,
# picks the commit, so rewriting a run in one later commit (its run line and its
# Reproduce commands together) cannot make that commit look like the original.
signature() { # signature ROWS RUN: the run line and its finding bullets, in order
  printf '%s\n' "$1" | awk -F '\t' -v r="$2" '$1 == "RUN" && $2 == r { print $9 } $1 == "FIND" && $2 == r { print $6 }'
}
doctored=
if [ -n "$since" ]; then
  history=$(git log --reverse --format=%H -- "$plan" 2>/dev/null | while IFS= read -r c; do
    git merge-base --is-ancestor "$since" "$c" 2>/dev/null && printf '%s\n' "$c"
  done)
  r=1
  while [ "$r" -le "$runs" ]; do
    orig=
    for c in $history; do
      git show "$c:./$plan" > "$old" 2>/dev/null || continue
      then_rows=$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$old")
      if [ "$(printf '%s\n' "$then_rows" | grep -c '^RUN')" -ge "$r" ]; then orig=$(signature "$then_rows" "$r"); break; fi
    done
    [ "$orig" = "$(signature "$records" "$r")" ] || doctored="$doctored$r
"
    r=$((r + 1))
  done
fi
open=0 total=0 demoted=0
for slug in $(rows FIND | cut -f 3 | awk '!seen[$0]++'); do
  total=$((total + 1))
  demote=$(rows DEMOTE | awk -F '\t' -v s="$slug" '$2 == s { l = $3 } END { print l }')
  if [ -n "$demote" ]; then
    if made_by "$demote" "serial-build: demote $slug"; then
      echo "DEMOTED   $slug: ${demote#*: }"
      demoted=$((demoted + 1))
      continue
    fi
    echo "OPEN      $slug: its Demoted line was not recorded by ship-gate.sh --demote, so it does not count"
    open=$((open + 1))
    continue
  fi
  why=
  # A finding in a run whose record changed after it was first committed is open.
  for r in $(rows FIND | awk -F '\t' -v s="$slug" '$3 == s { print $2 }'); do
    if printf '%s\n' "$doctored" | grep -qx "$r"; then
      why="the red run that recorded it (run $r) changed after it was first committed; the recorded test and command stand"
    fi
  done
  last=$(rows FIND | awk -F '\t' -v s="$slug" '$3 == s { t = $4; c = $5 } END { print t "\t" c }')
  test=${last%%"$TAB"*} cmd=${last#*"$TAB"}
  repin=$(rows REPIN | awk -F '\t' -v s="$slug" '$2 == s { t = $3; l = $4 } END { if (l != "") print t "\t" l }')
  if [ -n "$repin" ] && [ -z "$why" ]; then
    if made_by "${repin#*"$TAB"}" "serial-build: re-pin $slug"; then
      test=${repin%%"$TAB"*}
    else
      why="its Re-pinned line was not recorded by red-repin.sh, so it does not count"
    fi
  fi
  [ "$test" = - ] && test=
  [ "$cmd" = - ] && cmd=
  path=${test%@*} blob=${test##*@}
  if [ -n "$why" ]; then :
  elif [ -z "$test" ] || [ "$path" = "$test" ] || [ -z "$blob" ]; then
    why="no Test: \`path@blob\` recorded, so nothing shows the test is the one the red lane wrote"
  elif [ ! -f "$path" ]; then
    why="its test $path is gone; deleting a red test does not fix the bug"
  elif [ "$(git hash-object "$path" 2>/dev/null)" != "$blob" ]; then
    why="its test $path changed since it was recorded; fix the code, not the test (a test that must change is re-pinned with red-repin.sh)"
  elif [ -z "$cmd" ]; then
    why="no Reproduce: \`command\`, so nothing can show it fixed"
  fi
  if [ -n "$why" ]; then
    echo "OPEN      $slug: $why"
    open=$((open + 1))
  elif (sh -c "$cmd") > "$out" 2>&1; then
    echo "RESOLVED  $slug: \`$cmd\` passes on the recorded test"
  else
    echo "OPEN      $slug: \`$cmd\` still fails:"
    tail -n 5 "$out" | sed 's/^/            /'
    open=$((open + 1))
  fi
done

if [ "$open" -gt 0 ]; then
  echo "red-status: $gate: $open of $total red findings are open. It does not hand off until each is fixed."
  exit 1
fi
if [ "$total" -eq 0 ]; then
  echo "red-status: $gate: $runs credible red run(s), no findings. Clear to hand off."
else
  echo "red-status: $gate: $((total - demoted)) of $total red findings resolved, $demoted demoted by the owner. Clear to hand off."
fi
exit 0
