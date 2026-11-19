#!/bin/sh
# What is next for this project, and whether the product owner is needed for it,
# read from the ledger so no session has to work it out from prose. The driver
# (advance.sh) asks this before every step; a person or a skill can ask it too.
#
#   next-step.sh [project root]
#     Prints the step as "field: value" lines:
#       gate:  the gate the step is for, or "-"
#       step:  scope | intake | draft | gate | ask | build | red | demo-brief |
#              demo | tooling-fix | wait | none
#       owner: yes when only the product owner can take the step, else no
#       why:   the state that makes this the step, in one line
#       run:   the command or instruction that takes it
#       ask:   what to ask the owner (only when owner is yes)
#     Exit 0: a step that needs no owner. 2: the owner is needed. 3: nothing to
#     run now. 1: this is not a serial-build project.
#
#   next-step.sh park "<the question, its options, and what happens on each>"
#     Records a question only the owner can answer as an "Ask first:" line at the
#     top of docs/plan.md and commits it, so an unattended build stops on it
#     instead of guessing. The step then reads "ask" until it is answered.
#
#   next-step.sh answer "<the owner's words, verbatim>"
#     Turns the first "Ask first:" line into an "Answered:" line carrying their
#     words, and commits it as "serial-build: owner answered". Their answer is
#     their act; pass what they said, never a paraphrase.
#
#   next-step.sh mark-brief
#     Records under "## Demo brief" in docs/plan.md that the brief was refreshed
#     on the current commit, after the red lane cleared. The brief counts as
#     fresh until a file outside docs/ changes. /serial-build:demo-brief runs
#     this at the end of its refresh.
#
# Run from the project root.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
mode=step
case "${1:-}" in park|answer|mark-brief) mode=$1; shift ;; esac
if [ "$mode" = step ]; then root=${1:-$(sb_project_root)}; else root=$(sb_project_root); fi
cd "$root" || exit 1
SB_ROOT=$(pwd)
plan=docs/plan.md roadmap=docs/roadmap.md
refuse() { printf 'next-step: %s\n' "$1" >&2; exit 1; }
in_git() { git rev-parse -q --verify HEAD >/dev/null 2>&1; }
# commit_plan MESSAGE: commits docs/plan.md alone, where there is a history to commit to.
commit_plan() {
  in_git || return 0
  git add -- "$plan" && git commit -q -m "$1" -- "$plan" || refuse "docs/plan.md is changed but could not be committed; commit it yourself"
}

if [ "$mode" = park ]; then
  [ -n "${1:-}" ] || refuse 'usage: next-step.sh park "<the question, its options, and what happens on each>"'
  [ -f "$plan" ] || refuse "no docs/plan.md; with no gate in flight a question is an open question, filed through /serial-build:intake"
  Q=$(printf '%s' "$1" | tr '\n' ' ') awk 'NR == 1 { print; print ""; print "Ask first: " ENVIRON["Q"]; next } { print }' "$plan" > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
  commit_plan "serial-build: ask the owner"
  echo "next-step: the question is parked at the top of docs/plan.md; work on this gate waits for the owner's answer."
  exit 0
fi

if [ "$mode" = answer ]; then
  [ -n "${1:-}" ] || refuse 'usage: next-step.sh answer "<the owner'"'"'s words, verbatim>"'
  [ -f "$plan" ] && grep -q '^Ask first' "$plan" || refuse "docs/plan.md has no \"Ask first:\" line to answer"
  A=$(printf '%s' "$1" | tr '\n' ' ') awk '
    !done && /^Ask first/ { q = $0; sub(/^Ask first:?[ \t]*/, "", q); print "Answered: " q " The owner said: \"" ENVIRON["A"] "\""; done = 1; next }
    { print }' "$plan" > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
  commit_plan "serial-build: owner answered"
  echo "next-step: the owner's answer is recorded in docs/plan.md."
  exit 0
fi

# red_clear: the red lane's record lets the gate ship (red-status.sh remembers
# its verdict for an unchanged tree, so asking twice does not re-run it).
red_clear() { sh "$SB_PLUGIN/scripts/red-status.sh" "$SB_ROOT" >/dev/null 2>&1; }

if [ "$mode" = mark-brief ]; then
  [ -f "$plan" ] && grep -q '^## Demo brief' "$plan" || refuse "docs/plan.md has no \"## Demo brief\" section to mark"
  in_git || refuse "the brief is marked against a commit, and this project has none"
  red_clear || refuse "the red lane's record is not clear, so the brief the owner reads is not the refreshed one yet (red-status.sh says why)"
  [ -z "$(sb_changed_files | grep -v '^docs/')" ] || refuse "files outside docs/ are not committed; commit the gate's work, then refresh and mark the brief"
  awk -v mark="Refreshed: red clear at $(git rev-parse --short HEAD)." '
    /^Refreshed: red clear at / { next }
    { print }
    /^## Demo brief/ { print ""; print mark }' "$plan" > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
  echo "next-step: the demo brief is marked as refreshed at $(git rev-parse --short HEAD); the owner can run the demo."
  exit 0
fi

[ -f .claude/serial-build.json ] || refuse "no .claude/serial-build.json here, so this is not a serial-build project; /serial-build:scope sets one up"
gate=
# say STEP OWNER WHY RUN [ASK]: prints the step and exits with its status.
say() {
  printf 'gate: %s\nstep: %s\nowner: %s\nwhy: %s\nrun: %s\n' "${gate:--}" "$1" "$2" "$3" "$4"
  [ -n "${5:-}" ] && printf 'ask: %s\n' "$5"
  case "$1" in none|wait) exit 3 ;; esac
  [ "$2" = yes ] && exit 2
  exit 0
}

if lock=$(sb_red_lock) && [ -f "$lock" ]; then
  [ -f "$plan" ] && gate=$(awk '/^# /{print substr($0, 3); exit}' "$plan")
  say red-lock yes "the red lock is held: a red run is in progress, or a session died holding it" \
    "wait for the run; if none is live, release the lock (this voids that run): sh \"$SB_PLUGIN/scripts/red-guard.sh\" abort" \
    "Is a red run still going? If not, the lock it left has to be released before anything else can write."
fi

if [ -f "$plan" ]; then
  gate=$(awk '/^# /{print substr($0, 3); exit}' "$plan")
  asked=$(sed -n 's/^Ask first:*[[:space:]]*//p' "$plan" | head -n 1)
  if grep -q '^Ask first' "$plan"; then
    say ask yes "docs/plan.md opens with a question only the owner can answer" \
      "sh \"$SB_PLUGIN/scripts/next-step.sh\" answer \"<the owner's words, verbatim>\"" "${asked:-see the Ask first line in docs/plan.md}"
  fi
  # The red task is the red lane's to finish, not the builder's.
  left=$(grep '^- \[ \]' "$plan" | grep -c -v 'serial-build:red')
  if [ "$left" -gt 0 ]; then
    say build no "$left task(s) in docs/plan.md are not ticked" "build: work through the unticked tasks in docs/plan.md, ticking each as it is done"
  fi
  if in_git; then
    dirty=$(sb_changed_files | grep -c .)
    if [ "$dirty" -gt 0 ] && ! red_clear; then
      say build no "every task is ticked but $dirty file(s) are not committed, and the red lane attacks only committed work" "build: commit the gate's work per the project's commit policy"
    fi
  fi
  if ! red_clear; then
    say red no "the gate is built and the red lane's record is not clear" "/serial-build:red"
  fi
  ref=$(sed -n 's/^Refreshed: red clear at \([0-9a-f]\{7,40\}\)\.$/\1/p' "$plan" | tail -n 1)
  if [ -z "$ref" ] || ! in_git || ! git cat-file -e "$ref^{commit}" 2>/dev/null || ! git diff --quiet "$ref" -- . ':(exclude)docs' 2>/dev/null; then
    say demo-brief no "the red lane is clear and the demo brief has not been refreshed on this code" "/serial-build:demo-brief"
  fi
  acc=$(sed -n 's/^Acceptance:[[:space:]]*//p' "$plan" | head -n 1)
  say demo yes "the gate is built, attacked and briefed; only the owner accepts it" \
    "the owner runs the Demo brief in docs/plan.md, break step included; on their acceptance sentence, /serial-build:handoff in that same session ships it" \
    "Run the demo in the Demo brief of docs/plan.md, try to break it, and say whether this is true: ${acc:-the acceptance sentence in the plan}"
fi

[ -f "$roadmap" ] || say scope yes "there is no docs/roadmap.md" "/serial-build:scope" "The project has a config but no roadmap; scope it?"
first=$(awk '/^### /{print substr($0, 5); exit}' "$roadmap")
later=$(awk '/^- [a-z0-9][a-z0-9-]*: / { sub(/^- /, ""); sub(/:.*/, ""); print; exit }' "$roadmap")
if [ -n "$first" ]; then
  gate=$first
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git; then
    sh "$SB_PLUGIN/scripts/plan-draft.sh" status "$first" >/dev/null 2>&1
    case $? in
      0) say gate yes "a reviewed draft of the plan for $first is saved; only the owner approves a plan" "/serial-build:gate" \
           "Approve the plan for $first: /serial-build:gate shows the reviewed draft." ;;
      2) say wait no "a session is still drafting the plan for $first" "wait for it: sh \"$SB_PLUGIN/scripts/plan-draft.sh\" status $first" ;;
      *) say draft no "the next roadmap gate, $first, has no plan and no draft" "/serial-build:gate --draft $first, in the worktree that plan-draft.sh start $first names" ;;
    esac
  fi
  say gate yes "the next roadmap gate, $first, has no plan; only the owner approves one" "/serial-build:gate" "Plan $first: /serial-build:gate drafts it, has it reviewed, and shows it for approval."
fi
if [ -n "$later" ]; then
  gate=$later
  say intake no "no roadmap gate is written out; the next one-line gate is $later" "/serial-build:intake Write out the next one-line roadmap gate, $later, in full, with every section."
fi
fixes=$(awk '/^## Tooling fixes/ { on = 1; next } on && /^## / { on = 0 } on && /^- / { n++ } END { print n + 0 }' "$roadmap")
if [ "$fixes" -gt 0 ]; then
  say tooling-fix no "no gate is active and $fixes tooling fix(es) are queued" "/serial-build:tooling-fix"
fi
say none no "the roadmap has no pending gate" "-"
