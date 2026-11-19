#!/bin/sh
# What is next for this project, and whether the product owner is needed for it,
# read from the ledger so no session has to work it out from prose. The driver
# (advance.sh) asks this before every step; a person or a skill can ask it too.
#
#   next-step.sh [project root]
#     Prints the step as "field: value" lines:
#       gate:  the gate the step is for, or "-"
#       step:  scope | intake | draft | gate | ask | blocked | build | commit |
#              red | red-commit | red-stop | red-lock | untracked | demo-brief |
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
#     fresh until a file outside docs/ changes or appears. /serial-build:demo-brief
#     runs this at the end of its refresh.
#
# Only the plan's top block, before its first "## " section, holds its tasks and
# its parked questions: a checklist or a sentence in the demo brief is neither.
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
# The plan's top block. ASKED is an awk test for a parked question's line, read
# loosely: "Ask first", "ask first:", "**Ask first:**", or indented.
top() { awk '/^## / { exit } { print }' "$plan"; }
ASKED='function asked(s) { s = tolower(s); gsub(/^[ \t*]+/, "", s); return s ~ /^ask first([:*]|$)/ }'

if [ "$mode" = park ]; then
  [ -n "${1:-}" ] || refuse 'usage: next-step.sh park "<the question, its options, and what happens on each>"'
  [ -s "$plan" ] || refuse "no docs/plan.md; with no gate in flight a question is an open question, filed through /serial-build:intake"
  Q=$(printf '%s' "$1" | tr '\n' ' ') awk 'NR == 1 { print; print ""; print "Ask first: " ENVIRON["Q"]; next } { print }' "$plan" > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
  commit_plan "serial-build: ask the owner"
  echo "next-step: the question is parked at the top of docs/plan.md; work on this gate waits for the owner's answer."
  exit 0
fi

if [ "$mode" = answer ]; then
  [ -n "${1:-}" ] || refuse 'usage: next-step.sh answer "<the owner'"'"'s words, verbatim>"'
  [ -f "$plan" ] && [ -n "$(top | awk "$ASKED"' asked($0) { print; exit }')" ] || refuse "docs/plan.md has no \"Ask first:\" line to answer"
  A=$(printf '%s' "$1" | tr '\n' ' ') awk "$ASKED"'
    /^## / { body = 1 }
    !done && !body && asked($0) { q = $0; sub(/^[ \t*]*[Aa]sk first[*:]*[ \t]*/, "", q); print "Answered: " q " The owner said: \"" ENVIRON["A"] "\""; done = 1; next }
    { print }' "$plan" > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
  commit_plan "serial-build: owner answered"
  echo "next-step: the owner's answer is recorded in docs/plan.md."
  exit 0
fi

# red_clear: the red lane's record lets the gate ship (red-status.sh remembers
# its verdict for an unchanged tree, so asking twice does not re-run it).
red_clear() { sh "$SB_PLUGIN/scripts/red-status.sh" "$SB_ROOT" >/dev/null 2>&1; }
# Files changed or new outside docs/, which the red lane and the brief have not
# seen. The folder litter a file browser leaves is not the project's work.
code_changes() { sb_changed_files | grep -v -e '^docs/' -e '^\.DS_Store$' -e '/\.DS_Store$'; }
# The red lane's record in a plan on stdin, as one checksum.
red_record() { LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" | grep -v "^TRIED" | sb_hash; }

if [ "$mode" = mark-brief ]; then
  [ -f "$plan" ] && grep -q '^## Demo brief' "$plan" || refuse "docs/plan.md has no \"## Demo brief\" section to mark"
  red_clear || refuse "the red lane's record is not clear, so the brief the owner reads is not the refreshed one yet (red-status.sh says why)"
  if in_git; then
    [ -z "$(code_changes)" ] || refuse "files outside docs/ are not committed; commit the gate's work, then refresh and mark the brief"
    at=$(git rev-parse HEAD)
  else
    at=no-commit
  fi
  # The mark sits under the heading with one blank line each side, however often it is renewed.
  awk -v mark="Refreshed: red clear at $at." '
    /^Refreshed: red clear at / { next }
    held && !NF { next }
    held { print ""; held = 0 }
    { print }
    /^## Demo brief/ { print ""; print mark; held = 1 }' "$plan" > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
  echo "next-step: the demo brief is marked as refreshed at $at; the owner can run the demo."
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
  asked=$(top | awk "$ASKED"' asked($0) { sub(/^[ \t*]*[Aa]sk first[*:]*[ \t]*/, ""); print; exit }')
  if [ -n "$(top | awk "$ASKED"' asked($0) { print "y"; exit }')" ]; then
    say ask yes "docs/plan.md opens with a question only the owner can answer" \
      "sh \"$SB_PLUGIN/scripts/next-step.sh\" answer \"<the owner's words, verbatim>\"" "${asked:-see the Ask first line in docs/plan.md}"
  fi
  # A blocking open question the plan names, still open: the build waits on the owner.
  # The line reads "Blocking open questions: <slug, what it is>, <slug, ...> | none"
  # and may wrap onto indented lines; each item's first word is its slug.
  if [ -f docs/open.md ]; then
    still=$(top | awk -v openf=docs/open.md '
      BEGIN { while ((getline l < openf) > 0) if (l ~ /^## /) open[substr(l, 4)] = 1 }
      /^Blocking open questions:/ { v = $0; sub(/^Blocking open questions:[ \t]*/, "", v); on = 1; next }
      on && /^[ \t]+[^ \t]/ { v = v " " $0; next }
      on { on = 0 }
      END {
        first = v; sub(/^[ \t`*]+/, "", first)
        if (tolower(first) ~ /^none([^a-z0-9-]|$)/) exit
        n = split(v, item, /[,;]/)
        for (i = 1; i <= n; i++) {
          s = item[i]; sub(/^[ \t`*]+/, "", s)
          if (match(s, /^[a-z0-9][a-z0-9-]*/)) { s = substr(s, 1, RLENGTH); if (s in open) printf "%s ", s }
        }
      }')
    if [ -n "$still" ]; then
      say blocked yes "the plan names blocking open questions that are still open: ${still% }" \
        "answer each through /serial-build:intake, which records the decision and closes the question" \
        "The plan for $gate is blocked on: ${still% }. Each is an open question with a recommendation; what do you decide?"
    fi
  fi
  # The red task is the red lane's to finish, not the builder's.
  left=$(top | grep '^- \[ \]' | grep -c -v 'serial-build:red')
  if [ "$left" -gt 0 ]; then
    say build no "$left task(s) in docs/plan.md are not ticked" "build: work through the unticked tasks in docs/plan.md, ticking each as it is done"
  fi
  if in_git; then
    dirty=$(sb_changed_files | grep -c .)
    if [ "$dirty" -gt 0 ] && ! red_clear; then
      # The red lane's own uncommitted work: its record in the plan, a test under
      # red.test_paths, or the raw output it filed. Anything else is the builder's.
      reds=
      [ "$(red_record < "$plan")" = "$(git show "HEAD:./$plan" 2>/dev/null | red_record)" ] || reds=1
      sb_changed_files | grep -q '^docs/decisions/sources/' && reds=1
      cfg=$(sb_flatten < .claude/serial-build.json 2>/dev/null)
      if sb_get "$cfg" 'red.test_paths.#' >/dev/null 2>&1 && sb_changed_files | sb_filter "$cfg" red.test_paths | grep -q .; then reds=1; fi
      if [ -n "$reds" ] && grep -q '^Red run:' "$plan"; then
        say red-commit yes "the red lane recorded a run and $dirty file(s) are not committed; it asks the owner before committing failing tests where they would fail the default branch" \
          "commit the red lane's tests, raw output and plan where the owner says, then /serial-build:red goes on to the fix" \
          "The red lane's findings for $gate are recorded but not committed, and its failing tests will fail the checks until the fixes land. Commit them on this branch, or on a new branch for the gate?"
      fi
      say commit no "every task is ticked but $dirty file(s) are not committed, and the red lane attacks only committed work" "commit the gate's work per the project's commit policy"
    fi
  fi
  if ! red_clear; then
    # The red lane's own stopping rule: two fix rounds that still found failures
    # are the owner's choice, never a third round (the count red-file.sh makes).
    deltas=$(awk '/^Red run:/ {
        if ($0 ~ / Partial run\./) { n = 0; afterpartial = 1; next }
        if ($0 !~ / Delta run\./) { n = 0; afterpartial = 0; next }
        if ($0 !~ / 0 findings\./ && !afterpartial) n++
        afterpartial = 0 } END { print n + 0 }' "$plan")
    if [ "$deltas" -ge 2 ]; then
      say red-stop yes "two fix rounds on $gate still found failures, and a third would only patch the next neighbour" \
        "/serial-build:red, once the owner has chosen" \
        "Two fix rounds on $gate still found failures. Choose one: a structural change that removes the whole class (a narrower gate, or refusing the class outright), or accepting the risk (each open finding demoted on your words)."
    fi
    say red no "the gate is built and the red lane's record is not clear" "/serial-build:red"
  fi
  # Work outside docs/ that is not committed: the brief cannot be refreshed on
  # it, so it is committed first; files that are only new are the owner's to
  # commit, ignore, or delete (a demo's own output, say).
  if in_git && [ -n "$(code_changes)" ]; then
    new=$(git ls-files --others --exclude-standard -- . ':(exclude)docs' 2>/dev/null | grep -v -e '^\.DS_Store$' -e '/\.DS_Store$')
    if [ "$(code_changes | grep -c .)" -gt "$(printf '%s\n' "$new" | grep -c .)" ]; then
      say commit no "the red lane is clear, and files outside docs/ changed since and are not committed" "commit the gate's work per the project's commit policy"
    fi
    say untracked yes "the gate is built and attacked, and new files outside docs/ are not committed: $(printf '%s' "$new" | tr '\n' ' ')" \
      "commit, ignore (in .gitignore), or delete each one; the demo brief is refreshed only on committed work" \
      "These new files are not committed: $(printf '%s' "$new" | tr '\n' ' '). Should each be committed, ignored, or deleted?"
  fi
  ref=$(sed -n 's/^Refreshed: red clear at \([0-9a-f]\{7,40\}\)\.$/\1/p' "$plan" | tail -n 1)
  if in_git; then
    [ -n "$ref" ] && git cat-file -e "$ref^{commit}" 2>/dev/null && git diff --quiet "$ref" -- . ':(exclude)docs' 2>/dev/null && [ -z "$(code_changes)" ] || ref=
  else
    grep -q '^Refreshed: red clear at no-commit\.$' "$plan" && ref=no-commit
  fi
  if [ -z "$ref" ]; then
    say demo-brief no "the red lane is clear and the demo brief has not been refreshed on this code" "/serial-build:demo-brief"
  fi
  acc=$(top | sed -n 's/^Acceptance:[[:space:]]*//p' | head -n 1)
  say demo yes "the gate is built, attacked and briefed; only the owner accepts it" \
    "the owner runs the Demo brief in docs/plan.md, break step included; on their acceptance sentence, /serial-build:handoff in that same session ships it" \
    "Run the demo in the Demo brief of docs/plan.md, try to break it, and say whether this is true: ${acc:-the acceptance sentence in the plan}"
fi

[ -f "$roadmap" ] || say scope yes "there is no docs/roadmap.md" "/serial-build:scope" "The project has a config but no roadmap; scope it?"
# Gates end where the tooling fixes begin, and a one-line gate is a bullet of a
# stage's "Later:" list: a tooling fix is written as the same kind of bullet.
# The tooling-fixes section is skipped, not taken as the end: a stage may follow it.
# A "Later" heading is read loosely ("Later:", "**Later:**", "Later (in order):").
first=$(awk '/^## Tooling fixes/ { skip = 1; next } /^## / { skip = 0 } !skip && /^### / { print substr($0, 5); exit }' "$roadmap")
later=$(awk '/^## Tooling fixes/ { skip = 1; next } /^## / { skip = 0 } skip { next }
  { t = tolower($0); gsub(/^[ \t*]+/, "", t) }
  t ~ /^later[ \t]*(\([^)]*\))?[ \t]*:/ { on = 1; next } /^#/ { on = 0 }
  on && /^- [a-z0-9][a-z0-9-]*: / { sub(/^- /, ""); sub(/:.*/, ""); print; exit }' "$roadmap")
if [ -n "$first" ]; then
  gate=$first
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git; then
    # A plan is drafted from the last commit, so a gate not committed yet cannot be drafted.
    if ! git show "HEAD:./$roadmap" 2>/dev/null | grep -qx "### $first"; then
      say intake yes "the gate $first is in the roadmap but that change is not committed, and a plan is drafted from the last commit" \
        "commit docs/roadmap.md once the owner has approved the change (intake holds a commit for a new glossary entry or a contradiction of what they stated; a gate moved back by ship-gate.sh --regress is committed with the handoff)" \
        "The gate $first is written out in the roadmap, but that change is not committed. Is it right as written, so it can be committed and planned?"
    fi
    sh "$SB_PLUGIN/scripts/plan-draft.sh" status "$first" >/dev/null 2>&1
    case $? in
      0) say gate yes "a reviewed draft of the plan for $first is saved; only the owner approves a plan" "/serial-build:gate" \
           "Approve the plan for $first: /serial-build:gate shows the reviewed draft." ;;
      2) say wait no "a draft of the plan for $first was started and is not saved: a session is still writing it, or one died before saving" \
           "wait for it, or drop it so it can be drafted again: sh \"$SB_PLUGIN/scripts/plan-draft.sh\" drop $first" ;;
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
  say tooling-fix no "no gate is active and $fixes tooling fixes are queued" "/serial-build:tooling-fix"
fi
say none no "the roadmap has no pending gate" "-"
