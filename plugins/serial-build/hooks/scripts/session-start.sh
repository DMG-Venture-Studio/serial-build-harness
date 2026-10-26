#!/bin/sh
# SessionStart: tells the new session where the work stands, so it picks up the
# gate ledger instead of re-deriving it: the active plan's gate, or the next
# roadmap gate to plan; the inbox items waiting to be moved home; and a broken
# config, which otherwise switches every hook off without a word. Stdout becomes
# session context. No config: exit 0, silent.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/../.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
if ! sb_load_config; then
  if [ -n "$SB_CONFIG_ERROR" ]; then
    printf 'serial-build: .claude/serial-build.json is not valid JSON (%s), so every serial-build hook is off until it parses. Check it with: sh "%s/scripts/check-config.sh"\n' "$SB_CONFIG_ERROR" "$SB_PLUGIN"
  fi
  exit 0
fi

# A worktree that holds a plan drafted ahead: its plan is the active gate's, not
# this session's work.
case "$(git -C "$SB_ROOT" symbolic-ref -q --short HEAD 2>/dev/null)" in serial-build/draft-*)
  _g=$(git -C "$SB_ROOT" symbolic-ref -q --short HEAD); _g=${_g#serial-build/draft-}
  printf 'serial-build: this is the worktree where the plan for %s is drafted ahead, outside the project. Its docs/plan.md is the active gate'"'"'s; the work here is /serial-build:gate --draft %s, nothing else.\n' "$_g" "$_g"
  exit 0 ;;
esac
plan="$SB_ROOT/docs/plan.md"
roadmap="$SB_ROOT/docs/roadmap.md"
if [ -f "$plan" ]; then
  gate=$(awk '/^# /{print substr($0, 3); exit}' "$plan")
  open=$(grep -c '^- \[ \]' "$plan" 2>/dev/null)
  printf 'serial-build: the active gate is %s; docs/plan.md holds its tasks (%s unticked). Continue it; findings go through /serial-build:intake, never into the plan.\n' "${gate:-unnamed}" "${open:-0}"
  if grep -q '^Ask first' "$plan" 2>/dev/null; then
    printf 'serial-build: docs/plan.md opens with an "Ask first" line; ask the product owner before any other work.\n'
  fi
elif [ -f "$roadmap" ]; then
  gate=$(awk '/^### /{print substr($0, 5); exit}' "$roadmap")
  later=$(awk '/^- [a-z0-9][a-z0-9-]*: / { sub(/^- /, ""); sub(/:.*/, ""); print; exit }' "$roadmap")
  if [ -n "$gate" ]; then
    printf 'serial-build: no active plan. The next roadmap gate is %s; plan it with /serial-build:gate.\n' "$gate"
  elif [ -n "$later" ]; then
    printf 'serial-build: no active plan, and no roadmap gate is written out. The next one-line gate is %s; write it out in full with /serial-build:intake, then plan it with /serial-build:gate.\n' "$later"
  fi
fi

# A stop check that failed and has not passed since: the next session must know.
state=$(sb_state_dir)
if lock=$(sb_red_lock) && [ -f "$lock" ]; then
  printf 'serial-build: the red lock is held: a red run is in progress, or a session died holding it. Until it is released only the red-breaker agent may write into the project. If no red run is in progress, release it (this voids that run) with: sh "%s/scripts/red-guard.sh" abort\n' "$SB_PLUGIN"
fi
pid=$(sb_proof_running); case $? in
  0) printf 'serial-build: proofs are running (pid %s), and the stop checks wait until they finish.\n' "$pid" ;;
  2) printf 'serial-build: a proof run (pid %s) died before it finished, so a proof that changes the tree on purpose may have left its change in it. Check git status and undo what the proof changed, then clear its marker with: sh "%s/scripts/run-proofs.sh" --clear\n' "$pid" "$SB_PLUGIN" ;;
esac
for why in "$state"/stop-*.why; do
  [ -f "$why" ] || continue
  stamp=${why%.why}
  case "$(cat "$stamp" 2>/dev/null)" in *:fail)
    printf 'serial-build: warning: a stop check was failing when the last session ended:\n%s\n' "$(cat "$why")" ;;
  esac
done

inbox=$(sb_inbox) || inbox=
if [ -n "$inbox" ]; then
  items=$(sb_inbox_items "$inbox")
  if [ -n "$items" ]; then
    printf 'serial-build: the %s/ inbox holds items to move to their home or delete:\n%s\n' "$inbox" "$items"
  fi
fi
exit 0
