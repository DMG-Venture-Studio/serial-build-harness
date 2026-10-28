#!/bin/sh
# Writes a red-breaker agent's whole brief to a file, generated from the project
# rather than typed, so the session running /serial-build:red briefs the agent
# with one line ("Read <file> and follow it") instead of retyping a pack of
# hundreds of kilobytes, and so the report form the agent is given is always the
# one red-file.sh reads.
#
# The brief holds: the instruction that the agent did not build the gate; the
# gate's acceptance sentence, Proof, and roadmap section; what counts as a
# finding (the project's threat model, the "threat_model" section copied in,
# or, with none declared, the setups any reviewer would call contrived); the
# attack order (the
# surface the demo and acceptance sentence depend on first, the plan's Supporting
# items after); the "Tried to break" minimum; the run's mode (full, delta, or
# partial) and lane; the test paths and single-file test command; the path of the
# context pack (red-pack.sh, written beside it); and the report form, copied from
# agents/red-breaker.md.
#
#   --out DIR        where to write brief[-<lane>].md and pack[-<lane>].md; an
#                    absolute folder outside the project (the red lock refuses
#                    writes inside it)
#   --lane NAME      one lane of red.lanes
#   --delta          the run after fixes: regressions only (the fix commits since
#                    the last Red commit and the findings they close are listed)
#   --partial TEXT   a run on finished slices while the builder waits on
#                    something outside the repository; TEXT names the slices
#   --quarantine DIR a voided run's salvaged tests for the agent to judge
#
# Usage: red-brief.sh --out DIR [--lane NAME] [--delta | --partial TEXT] [--quarantine DIR]
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
refuse() { printf 'red-brief: %s\n' "$1" >&2; exit 1; }
usage='usage: red-brief.sh --out DIR [--lane NAME] [--delta | --partial TEXT] [--quarantine DIR]'
out= lane= mode=full partial= quarantine=
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=${2:-}; shift ;;
    --lane) lane=${2:-}; shift ;;
    --delta) mode=delta ;;
    --partial) mode=partial; partial=${2:-}; [ -n "$partial" ] || refuse "--partial needs the finished slices, in words"; shift ;;
    --quarantine) quarantine=${2:-}; shift ;;
    *) refuse "$usage" ;;
  esac
  shift
done
[ -n "$out" ] || refuse "$usage"
sb_load_config || refuse "no usable .claude/serial-build.json"
cd "$SB_ROOT" || exit 1
sb_outside_project "$out/brief.md" || refuse "--out must be an absolute folder outside the project, its repository, and .git: $out"
plan=docs/plan.md
[ -f "$plan" ] || refuse "no docs/plan.md, so no gate to brief"
gate=$(awk '/^# /{print substr($0, 3); exit}' "$plan")
[ "$(sb_count "$SB_CFG" red.test_paths)" -gt 0 ] || refuse "no red.test_paths in .claude/serial-build.json"
# The threat model, read before anything is written, so a broken one writes nothing.
tmv=$(sb_get "$SB_CFG" threat_model) || tmv=
tmt=
if [ -n "$tmv" ]; then
  tmt=$(sb_threat_model "$tmv") || refuse "$tmt; fix .claude/serial-build.json or that doc (check-config.sh says the same)"
fi
lanekey= first=
if [ -n "$lane" ]; then
  i=0 n=$(sb_count "$SB_CFG" red.lanes)
  while [ "$i" -lt "$n" ]; do
    if [ "$(sb_get "$SB_CFG" "red.lanes.$i.name")" = "$lane" ]; then lanekey="red.lanes.$i"; [ "$i" -eq 0 ] && first=1; fi
    i=$((i + 1))
  done
  [ -n "$lanekey" ] || refuse "no lane named \"$lane\" under red.lanes in .claude/serial-build.json"
fi
mkdir -p "$out" || refuse "cannot make $out"
out=$(cd "$out" && pwd -P)
suffix=${lane:+-$lane}
brief="$out/brief$suffix.md" pack="$out/pack$suffix.md"
if [ -n "$lane" ]; then
  sh "$SB_SCRIPTS/red-pack.sh" "$lane" --out "$pack" >/dev/null || refuse "red-pack.sh could not write $pack"
else
  sh "$SB_SCRIPTS/red-pack.sh" --out "$pack" >/dev/null || refuse "red-pack.sh could not write $pack"
fi

top() { awk '/^## / { exit } { print }' "$plan"; }  # the plan's top block
# A bullet that wraps keeps its indented lines, so neither it nor the bullets
# after it are cut.
tried=$(top | awk '/^Tried to break/ { on = 1; next } on && (/^- / || /^[ \t]+[^ \t]/) { print; next } on && NF { exit }')
acceptance=$(top | sed -n 's/^Acceptance: //p' | head -n 1)
# The Supporting block: every line from its own up to the first blank line (the
# task list follows it) or the first task, so a wrapped line or bullet stays
# whole; or nothing when it says none.
supporting=$(top | awk '/^Supporting/ { on = 1 } on && (!NF || /^- \[/) { exit } on && /^- / { list = 1 } on { b = b $0 "\n"; if (!list) h = h $0 "\n" } END { if (h !~ /(:|\|)[[:space:]]*none\.?[[:space:]]*\n$/) printf "%s", b }')
proof=$(top | awk '/^Proof/ { on = 1; next } on && /^(    |\t)/ { print; next } on && NF { exit }')
section=$( [ -f docs/roadmap.md ] && awk -v h="### $gate" '$0 == h { on = 1; next } on && (/^(#|##|###) / || /^Later:/) { exit } on' docs/roadmap.md)
paths=$(k=0; m=$(sb_count "$SB_CFG" red.test_paths); while [ "$k" -lt "$m" ]; do printf '`%s` ' "$(sb_get "$SB_CFG" "red.test_paths.$k")"; k=$((k + 1)); done)
tc=$(sb_get "$SB_CFG" red.test_command) || tc=
form=$(awk '/^## Output/ { on = 1; next } on && /^```/ { fence = !fence } on && !fence && /^## / { exit } on' "$SB_PLUGIN/agents/red-breaker.md")

{
  printf '# Red brief: %s%s, %s run\n\n' "$gate" "${lane:+, lane $lane}" "$mode"
  printf 'Generated by red-brief.sh at %s. Follow it as written.\n\n' "$(git rev-parse --short HEAD)"
  echo "You did not build this gate. Trust no claim that it works, including anything in the code's comments or the plan's ticks. Your only outputs are failing tests under the test paths below, or \"nothing found\" with every attempt listed. You never write the fix."
  echo
  echo "## The gate"
  echo
  printf 'Acceptance: %s\n\n' "${acceptance:-(the plan states none)}"
  if [ -n "$section" ]; then printf 'From the roadmap:\n\n%s\n\n' "$section"; fi
  if [ -n "$proof" ]; then printf 'Proof (the commands that must pass for it to ship):\n\n%s\n\n' "$proof"; fi
  echo "## What counts as a finding"
  echo
  if [ -n "$tmt" ]; then
    printf 'A failure counts only if it can happen in a setup this project'"'"'s checks defend against. Its threat model, `%s`, says which, copied here:\n\n%s\n\n' "$tmv" "$tmt"
    echo "A failure that needs a setup the threat model excludes, or one it does not name that you would yourself call contrived, is not a finding: write no test for it, and list it under \"## For intake\" with the setup it needs. It is never filed as a red finding."
  else
    echo "This project declares no threat model. A failure that needs a setup you would yourself call contrived (non-default git config, hand-built git objects, a filesystem nobody here uses, an interpreter build missing standard modules, a commit that skipped the hooks) is not a finding: write no test for it, and list it under \"## For intake\" with the setup it needs. It is never filed as a red finding."
  fi
  echo
  echo "## Attack order"
  echo
  echo "1. The acceptance sentence's surface first: everything the demo and the acceptance sentence depend on, taken literally. Look for a case where the sentence is false while every check passes."
  if [ -n "$supporting" ]; then
    echo "2. Then the supporting items the plan builds alongside, which neither the demo nor the acceptance sentence needs. They are secondary: attack them only after the surface above."
    echo
    printf '%s\n' "$supporting"
  fi
  echo
  case "$mode" in
    full)
      echo "## Your minimum"
      echo
      echo "Attempt at least every attack on this list, then go past it: neighbours of each, boundaries, order and repetition, the environment."
      echo
      printf '%s\n\n' "${tried:-- (the plan lists none)}" ;;
    partial)
      echo "## A partial run"
      echo
      printf 'The builder is waiting on something outside the repository, and these slices are finished: %s.\n\n' "$partial"
      echo "Attack only those slices. Of the list below, attempt every attack that falls in them, and list the ones that do not as \"not yet built\" under Attempts that found nothing. The run before handoff covers everything changed after this one."
      echo
      printf '%s\n\n' "${tried:-- (the plan lists none)}" ;;
    delta)
      redc=$(git log -1 --format=%H --grep='^Red: ' -- "$plan" 2>/dev/null)
      lastrun=$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$plan" | awk -F '\t' '$1 == "RUN" { n = $2 } END { print n + 0 }')
      if awk '/^Red run:/ { last = $0 } END { exit !(last ~ / Partial run\./) }' "$plan"; then
        echo "## The run before handoff, after a partial run"
        echo
        echo "The last run was a partial run, on the slices finished then. Everything built or changed since is yours to attack in full, as a first run would: neighbours, boundaries, order and repetition, the environment. Also attack what the fixes of the partial run's findings made newly possible. Attempt every attack on this list that the partial run marked not yet built, and go past it."
        echo
        printf '%s\n\n' "${tried:-- (the plan lists none)}"
      else
        echo "## A delta run: regressions only"
        echo
        echo "The builder fixed the findings below. Attack what the fixes made newly possible, and cases of each fixed kind that the fix's enumerating test misses. Do not hunt fresh neighbours in code the fixes did not touch."
        echo
      fi
      echo "A finding that is only about a message's wording goes under \"## For intake\", not under Findings."
      echo
      if [ -n "$redc" ] && [ -n "$(git log --format=%h "$redc..HEAD" -- . | head -n 1)" ]; then
        printf 'The commits since the last Red commit (%s):\n\n' "$(git rev-parse --short "$redc")"
        git log --format='- %h %s' "$redc..HEAD" -- . | head -n 40
        echo
      fi
      found=$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$plan" | awk -F '\t' -v r="$lastrun" '$1 == "FIND" && $2 == r { print $6 }')
      if [ -n "$found" ]; then
        echo "The last run's findings, which those commits fix:"
        echo
        printf '%s\n\n' "$found"
      fi ;;
  esac
  if [ -n "$lanekey" ]; then
    echo "## Your lane"
    echo
    printf 'You are lane %s of several. Your slice: %s.\n' "$lane" "$(sb_get "$SB_CFG" "$lanekey.focus" || echo "(no focus given)")"
    echo "Go past the list in your slice, and follow a bug anywhere it leads."
    printf 'Name every test file red_%s_<what>, so no other lane writes the same file.\n' "$lane"
    if [ -n "$first" ]; then echo "Every subprocess and timing attack is yours."; else echo "Subprocess and timing attacks belong to the first lane; leave them."; fi
    echo
  fi
  if [ -n "$quarantine" ]; then
    echo "## A voided run's tests"
    echo
    printf 'A voided run left its tests in %s. Judge each: write the ones that still reproduce into your own worktree as your own findings, drop the rest, then go past them.\n\n' "$quarantine"
  fi
  echo "## Tests"
  echo
  printf 'Write tests only under %s, with the Write tool.\n' "$paths"
  if [ -n "$tc" ]; then printf 'Run one test file with: `%s`\n' "$tc"; else echo "Run tests with the commands in CLAUDE.md, one file at a time."; fi
  echo
  echo "## Context"
  echo
  printf 'Read %s first: the files changed since the plan, the changed source in full, and the test fixtures you can reuse. You may still read anything.\n\n' "$pack"
  echo "## Report"
  echo
  echo "Return exactly the form below; red-file.sh reads it mechanically, and refuses a report it cannot read."
  printf '%s\n' "$form"
} > "$brief"
printf 'red-brief: wrote %s and %s.\nBrief the agent with one line: Read %s and follow it.\n' "$brief" "$pack" "$brief"
