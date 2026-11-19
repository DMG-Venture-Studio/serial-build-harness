#!/bin/sh
# The driver: runs the loop's unattended steps one after another, each in its own
# headless Claude Code process (so each starts with a fresh context and nobody
# types /clear), and stops as soon as the next step needs the product owner.
# The owner starts it; it never starts itself.
#
#   advance.sh [--dry-run] [--max-steps N] [--reviewed]
#
# Before each step it asks next-step.sh what is next. A step that needs no owner
# (writing out the next gate, drafting its plan, building, committing the build,
# the red lane, the demo brief's refresh, a tooling-fix pass) is run with:
#
#   claude -p "<the step's command>"
#
# It stops, saying why, when: the owner is needed (a plan to approve, a parked
# question, a red-lane choice, the demo); nothing is left to run; the ledger
# calls for a step this run has already run (so no step is paid for twice in one
# run, whatever ran between); a session exits non-zero; a draft session ends
# without saving its plan; or --max-steps (default 12) is reached.
#
# A build session is told to park a question only the owner can answer, never
# to guess. That is an instruction, so the driver also checks what a build or
# commit session wrote, against what was on disk when the session started and
# whether or not the session ended well. If it changed the approved plan beyond
# ticking tasks and parking a question (a task, the acceptance, the proof, the
# attack list, a recorded answer), the red lane's record, a decision record, an
# open question, the glossary, the design, or the roadmap, the driver stops for
# the owner and names each one, before the red lane spends anything on the
# result. It then refuses to run anything until it is started with --reviewed,
# which says the owner has read the change. A choice the session made only in
# code is not seen by this check; the demo brief lists those for the owner (see
# /serial-build:demo-brief).
#
# Environment:
#   SB_CLAUDE       the path of the Claude Code command (default: claude)
#   SB_CLAUDE_ARGS  extra arguments for every headless run, split on spaces. A
#                   headless run cannot answer a permission prompt, so say here how
#                   they are settled, for example:
#                     --permission-mode acceptEdits --permission-prompts none
#   SB_NOTIFY       a command run with sh when the driver stops for the owner,
#                   with SB_GATE, SB_STEP, and SB_ASK in its environment (for
#                   example, one that posts SB_ASK where the owner will see it).
#                   Unset: the stop is only printed.
#
# Exit 0: nothing is left to run. 2: stopped for the owner. 1: stopped for any
# other reason (a repeated step, a failed session, an unsaved draft, the limit).
# Run from the project root. --dry-run prints the first step and runs nothing.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
SB_ROOT=$(sb_project_root)
cd "$SB_ROOT" || exit 1
usage() { printf 'advance: usage: advance.sh [--dry-run] [--max-steps N] [--reviewed]\n' >&2; exit 1; }
dry= max=12 reviewed=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --reviewed) reviewed=1 ;;
    --max-steps) [ $# -ge 2 ] || usage; max=$2; shift ;;
    *) usage ;;
  esac
  shift
done
case "$max" in ''|*[!0-9]*) usage ;; esac
claude=${SB_CLAUDE:-claude}
statedir=$(sb_state_dir)
logs="$statedir/advance"
hold="$statedir/advance-unreviewed"
stamp=$(date +%Y%m%d-%H%M%S)
TAB=$(printf '\t')
gate=- step=- log=
field() { printf '%s\n' "$state" | sed -n "s/^$1: //p" | head -n 1; }
# notify: tells the owner, where SB_NOTIFY says how; a failure there never stops the driver.
notify() {
  [ -n "${SB_NOTIFY:-}" ] || return 0
  SB_GATE=$gate SB_STEP=$step SB_ASK=$1 sh -c "$SB_NOTIFY" >/dev/null 2>&1 || echo "advance: the SB_NOTIFY command failed; the owner was not told by it."
}
# plan_scope: the part of a plan (on stdin) only the owner changes: its top block.
# Ticks (nested ones too), trailing spaces, and parked questions are not changes;
# a recorded answer is, since only next-step.sh answer writes one, on their words.
plan_scope() {
  awk '/^## / { exit }
    { s = tolower($0); gsub(/^[ \t*]+/, "", s); if (index(s, "ask first") == 1) next }
    { if (match($0, /^[ \t]*- \[[xX]\]/)) $0 = substr($0, 1, RLENGTH - 2) " ]" substr($0, RLENGTH + 1)
      sub(/[ \t]+$/, ""); print }' | sed '/^$/d'
}
# owner_state: one "name<TAB>checksum" line per thing only the owner (or, for the
# red record, only the red lane) changes, as it stands on disk now, committed or not.
owner_state() {
  { [ -d docs/decisions ] && find docs/decisions -maxdepth 1 -type f -name '*.md' 2>/dev/null
    for _f in docs/open.md docs/glossary.md docs/design.md docs/roadmap.md; do [ -f "$_f" ] && printf '%s\n' "$_f"; done
  } | LC_ALL=C sort | while IFS= read -r _f; do printf '%s\t%s\n' "$_f" "$(sb_sum "$_f")"; done
  if [ -f docs/plan.md ]; then
    printf 'docs/plan.md (a task, the acceptance, the proof, the attack list, or a recorded answer; ticking and parking a question are not changes)\t%s\n' "$(plan_scope < docs/plan.md | sb_hash)"
    printf 'docs/plan.md (the red lane'"'"'s record, which only /serial-build:red writes)\t%s\n' "$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" docs/plan.md | grep -v "^TRIED$TAB" | sb_hash)"
  else
    printf 'docs/plan.md (the plan itself)\tgone\n'
  fi
}
# owner_changes BEFORE AFTER: the names whose line differs, was added, or is gone.
owner_changes() {
  { printf '%s\n' "$1" | sed '/^$/d' | sed "s/^/B$TAB/"; printf '%s\n' "$2" | sed '/^$/d' | sed "s/^/A$TAB/"; } | awk -F '\t' '
    $1 == "B" { b[$2] = $3 } $1 == "A" { a[$2] = $3 }
    END { for (k in b) if (!(k in a) || a[k] != b[k]) print k; for (k in a) if (!(k in b)) print k }' | LC_ALL=C sort -u
}
# run_step DIR PROMPT: one headless session in DIR; its output goes to a log.
run_step() {
  mkdir -p "$logs"
  log="$logs/$stamp-$n-$step.log"
  # shellcheck disable=SC2086
  (cd "$1" && set -f && "$claude" ${SB_CLAUDE_ARGS:-} -p "$2") > "$log" 2>&1 < /dev/null
}

if [ -f "$hold" ]; then
  if [ -n "$reviewed" ]; then
    rm -f "$hold"
  else
    printf 'advance: nothing runs yet: a build session changed what only the owner decides, and nobody has said the owner read it:\n%s\nWhen they have, start the driver again with --reviewed.\n' "$(cat "$hold")"
    notify "A build changed what only you decide, and the driver waits until you have read it: $(tr '\n' ';' < "$hold")"
    exit 2
  fi
fi

n=0 seen='|'
while :; do
  state=$(sh "$SB_PLUGIN/scripts/next-step.sh" "$SB_ROOT" 2>&1); code=$?
  gate=$(field gate) step=$(field step) why=$(field why) ask=$(field ask)
  case $code in
    0) ;;
    2) printf 'advance: stopped for the owner at %s (%s): %s\n%s\n' "$step" "$gate" "$why" "$ask"
       notify "$ask"; exit 2 ;;
    3) if [ "$step" = wait ]; then
         printf 'advance: stopped: %s\n%s\n' "$why" "$(field run)"; exit 1
       fi
       printf 'advance: nothing to run now: %s\n' "$why"; exit 0 ;;
    *) printf '%s\n' "$state"; exit 1 ;;
  esac
  case "$seen" in *"|$step:$gate|"*)
    printf 'advance: stopped: %s already ran for %s in this run, and the ledger calls for it again (%s). No step is paid for twice in one run; read the logs in %s\n' "$step" "$gate" "$why" "$logs"
    notify "The $step step for $gate ran and the ledger calls for it again: $why"; exit 1 ;;
  esac
  if [ "$n" -ge "$max" ]; then
    printf 'advance: stopped at the limit of %s steps; the next would be %s for %s.\n' "$max" "$step" "$gate"; exit 1
  fi
  dir=$SB_ROOT
  case "$step" in
    build) prompt="Continue the active gate in docs/plan.md: work through its unticked tasks in order, tick each one when it is done, and commit per the project's commit policy. Do not run /serial-build:red or /serial-build:handoff in this session; a separate session attacks the gate, and only the owner's acceptance ships it. If a task needs a decision only the product owner can make, do not guess: run sh \"$SB_PLUGIN/scripts/next-step.sh\" park \"<the question, its options, and what happens on each>\" and stop." ;;
    commit) prompt="Every task of the active gate in docs/plan.md is ticked, but files are not committed, and the red lane attacks only committed work. Commit the gate's work per the project's commit policy. Change nothing else, and do not run /serial-build:red or /serial-build:handoff in this session." ;;
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
  before=
  case "$step" in build|commit) before=$(owner_state) ;; esac
  run_step "$dir" "$prompt"; rc=$?
  if [ -n "$before" ]; then
    decided=$(owner_changes "$before" "$(owner_state)")
    if [ -n "$decided" ]; then
      printf '%s\n' "$decided" > "$hold"
      printf 'advance: stopped for the owner: the %s session changed what only the owner decides, so nothing more runs until they have read it:\n%s\n' "$step" "$decided"
      [ "$rc" -eq 0 ] || printf 'advance: that session also exited with an error; its output is in %s\n' "$log"
      printf 'See the change with git diff and git status on docs/. When the owner has read it, start the driver again with --reviewed.\n'
      notify "The $step session for $gate changed what only you decide: $(printf '%s' "$decided" | tr '\n' ';')"; exit 2
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'advance: stopped: the %s session exited with an error. Its output is in %s\n' "$step" "$log"
    tail -n 5 "$log" 2>/dev/null | sed 's/^/  /'
    notify "The $step step for $gate exited with an error."; exit 1
  fi
  if [ "$step" = draft ] && ! sh "$SB_PLUGIN/scripts/plan-draft.sh" status "$gate" >/dev/null 2>&1; then
    printf 'advance: stopped: the draft session for %s ended without saving a plan. Its output is in %s\nDrop the unsaved draft before drafting again: sh "%s/scripts/plan-draft.sh" drop %s\n' "$gate" "$log" "$SB_PLUGIN" "$gate"
    notify "The draft session for $gate ended without saving a plan."; exit 1
  fi
  seen="$seen$step:$gate|"
done
