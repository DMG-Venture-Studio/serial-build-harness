#!/bin/sh
# The driver: runs the loop's unattended steps one after another, each in its own
# headless Claude Code process (so each starts with a fresh context and nobody
# types /clear), and stops as soon as the next step needs the product owner.
# The owner starts it; it never starts itself.
#
#   advance.sh [--dry-run] [--max-steps N]
#
# Before each step it asks next-step.sh what is next. A step that needs no owner
# (writing out the next gate, drafting its plan, building, the red lane, the demo
# brief's refresh, a tooling-fix pass) is run with:
#
#   claude -p "<the step's command>"
#
# It stops, saying why, when: the owner is needed (plan approval, a parked
# question, the demo); nothing is left to run; the step it just ran is still the
# step the ledger calls for (so a step that made no progress is never paid for
# twice); a session exits non-zero; or --max-steps (default 12) is reached.
#
# A build session is told to park a question only the owner can answer, never
# to guess. That is an instruction, so after every build the driver also checks
# what the session wrote: if it changed the approved plan beyond ticking tasks
# (a task, the acceptance, the proof, the attack list), or wrote a decision
# record, an open question, the glossary, the design, or the roadmap, the driver
# stops for the owner and names each file, before the red lane spends anything
# on the result. A choice the session made only in code is not seen by this
# check; the demo brief lists those for the owner (see /serial-build:demo-brief).
#
# Environment:
#   SB_CLAUDE       the Claude Code command (default: claude)
#   SB_CLAUDE_ARGS  extra arguments for every headless run, split on spaces. A
#                   headless run cannot answer a permission prompt, so say here how
#                   they are settled, for example:
#                     --permission-mode acceptEdits --permission-prompts none
#   SB_NOTIFY       a command run with sh when the driver stops for the owner,
#                   with SB_GATE, SB_STEP, and SB_ASK in its environment (for
#                   example, one that posts SB_ASK where the owner will see it).
#                   Unset: the stop is only printed.
#
# Exit 0: nothing is left to run. 2: stopped for the owner. 1: stopped because a
# step made no progress, a session failed, or the step limit was reached.
# Run from the project root. --dry-run prints the first step and runs nothing.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
SB_ROOT=$(sb_project_root)
cd "$SB_ROOT" || exit 1
dry= max=12
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --max-steps) max=${2:-}; shift ;;
    *) printf 'advance: usage: advance.sh [--dry-run] [--max-steps N]\n' >&2; exit 1 ;;
  esac
  shift
done
case "$max" in ''|*[!0-9]*) printf 'advance: --max-steps takes a number\n' >&2; exit 1 ;; esac
claude=${SB_CLAUDE:-claude}
logs="$(sb_state_dir)/advance"
field() { printf '%s\n' "$state" | sed -n "s/^$1: //p" | head -n 1; }
# notify: tells the owner, where SB_NOTIFY says how; a failure there never stops the driver.
notify() {
  [ -n "${SB_NOTIFY:-}" ] || return 0
  SB_GATE=$gate SB_STEP=$step SB_ASK=$1 sh -c "$SB_NOTIFY" >/dev/null 2>&1 || echo "advance: the SB_NOTIFY command failed; the owner was not told by it."
}
# plan_scope: the part of a plan (on stdin) only the owner changes: its top block,
# with ticks and the parked-question lines taken out.
plan_scope() { awk '/^## / { exit } /^(Ask first|Answered:)/ { next } { sub(/^- \[[xX]\]/, "- [ ]"); print }' | sed '/^$/d'; }
# owner_only_changes COMMIT: what changed since COMMIT that only the owner decides.
owner_only_changes() {
  git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1 || return 0
  set -- "$1" docs/decisions docs/open.md docs/glossary.md docs/design.md docs/roadmap.md
  { _c=$1; shift
    git diff --name-only --relative "$_c" -- "$@" 2>/dev/null
    git ls-files --others --exclude-standard -- "$@" 2>/dev/null
    if [ -f docs/plan.md ] && git cat-file -e "$_c:./docs/plan.md" 2>/dev/null \
        && [ "$(git show "$_c:./docs/plan.md" | plan_scope)" != "$(plan_scope < docs/plan.md)" ]; then
      echo "docs/plan.md (a task, the acceptance, the proof, or the attack list, beyond ticking)"
    fi
  } | grep -v '^docs/decisions/sources/' | sed '/^$/d' | LC_ALL=C sort -u
}
# run_step DIR PROMPT: one headless session in DIR; its output goes to a log.
run_step() {
  mkdir -p "$logs"
  log="$logs/$n-$step.log"
  # shellcheck disable=SC2086
  (cd "$1" && set -f && $claude ${SB_CLAUDE_ARGS:-} -p "$2") > "$log" 2>&1 < /dev/null
}

n=0 last=
while :; do
  state=$(sh "$SB_PLUGIN/scripts/next-step.sh" "$SB_ROOT" 2>&1); code=$?
  gate=$(field gate) step=$(field step) why=$(field why) ask=$(field ask)
  case $code in
    0) ;;
    2) printf 'advance: stopped for the owner at %s (%s): %s\n%s\n' "$step" "$gate" "$why" "$ask"
       notify "$ask"; exit 2 ;;
    3) printf 'advance: nothing to run now: %s\n' "$why"; exit 0 ;;
    *) printf '%s\n' "$state"; exit 1 ;;
  esac
  if [ "$step:$gate" = "$last" ]; then
    printf 'advance: stopped: %s ran for %s and the ledger still calls for it (%s). Its output is in %s\n' "$step" "$gate" "$why" "$log"
    notify "The $step step for $gate ran and did not finish: $why"; exit 1
  fi
  if [ "$n" -ge "$max" ]; then
    printf 'advance: stopped at the limit of %s steps; the next would be %s for %s.\n' "$max" "$step" "$gate"; exit 1
  fi
  dir=$SB_ROOT
  case "$step" in
    build) prompt="Continue the active gate in docs/plan.md: work through its unticked tasks in order, tick each one when it is done, and commit per the project's commit policy. Do not run /serial-build:red in this session; a separate session attacks the gate. If a task needs a decision only the product owner can make, do not guess: run sh \"$SB_PLUGIN/scripts/next-step.sh\" park \"<the question, its options, and what happens on each>\" and stop." ;;
    draft)
      if [ -z "$dry" ]; then
        started=$(sh "$SB_PLUGIN/scripts/plan-draft.sh" start "$gate" 2>&1) || { printf '%s\n' "$started"; exit 1; }
        dir=$(printf '%s\n' "$started" | sed -n 's/^  cd "\(.*\)" && claude .*/\1/p' | head -n 1)
        [ -d "$dir" ] || { printf 'advance: plan-draft.sh start did not name the draft worktree:\n%s\n' "$started"; exit 1; }
      fi
      prompt="/serial-build:gate --draft $gate" ;;
    *) prompt=$(field run) ;;
  esac
  n=$((n + 1))
  if [ -n "$dry" ]; then
    printf 'advance: would run %s for %s (%s):\n  %s %s -p "%s"\n' "$step" "$gate" "$why" "$claude" "${SB_CLAUDE_ARGS:-}" "$prompt"
    exit 0
  fi
  printf 'advance: step %s: %s for %s (%s)\n' "$n" "$step" "$gate" "$why"
  before=$(git rev-parse -q --verify HEAD 2>/dev/null)
  if ! run_step "$dir" "$prompt"; then
    printf 'advance: stopped: the %s session exited with an error. Its output is in %s\n' "$step" "$log"
    tail -n 5 "$log" 2>/dev/null | sed 's/^/  /'
    notify "The $step step for $gate exited with an error."; exit 1
  fi
  if [ "$step" = build ] && [ -n "$before" ]; then
    decided=$(owner_only_changes "$before")
    if [ -n "$decided" ]; then
      printf 'advance: stopped for the owner: the build session changed what only the owner decides, so nothing more runs until they have read it:\n%s\nSee it with: git diff %s -- docs\n' "$decided" "$(git rev-parse --short "$before")"
      notify "The build for $gate changed what only you decide: $(printf '%s' "$decided" | tr '\n' ';')"; exit 2
    fi
  fi
  last="$step:$gate"
done
