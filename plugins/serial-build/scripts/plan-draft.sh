#!/bin/sh
# Drafts the next gate's plan while the current gate is still in red, demo, or
# handoff, so planning leaves the critical path. There is still only ever one
# active plan (docs/plan.md); a draft is not one. It lives on its own branch,
# serial-build/draft-<gate>, in a worktree outside the project, so nothing the
# draft session writes reaches the project, the red guard, or the red lock. The
# owner approves it, as any plan, when /serial-build:gate takes it.
#
#   start <gate>          cuts the branch at HEAD and its worktree, and prints the
#                         command that launches the draft session there
#   save <gate> [file]    commits the draft (default: docs/plan.md in the draft
#                         worktree) on the branch, recording the commit it was
#                         reviewed against
#   status <gate>         exit 0 and the base commit when a draft is saved; 1 when
#                         there is none; 2 when one is started but not saved
#   delta <gate>          what changed in the project since the draft's base that
#                         the draft depends on: the gate's own roadmap section, the
#                         files the draft names, and the standing docs, open
#                         questions, and decision records. Exit 0 when nothing
#                         did; 3, with the list and a diff summary, when something
#                         did and the draft needs one review pass on the change
#   take <gate>           prints the saved draft
#   drop <gate>           removes the worktree and the branch
#
# Usage: plan-draft.sh start|save|status|delta|take|drop <gate> [file]   (from the project root)
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
refuse() { printf 'plan-draft: %s\n' "$1" >&2; exit 1; }
mode=${1:-} gate=${2:-}
case "$mode" in start|save|status|delta|take|drop) ;; *) refuse "usage: plan-draft.sh start|save|status|delta|take|drop <gate> [file]" ;; esac
[ -n "$gate" ] || refuse "usage: plan-draft.sh $mode <gate>"
case "$gate" in *[!a-z0-9-]*) refuse "a gate slug is lowercase letters, digits, and hyphens: $gate" ;; esac
SB_ROOT=$(sb_project_root)
git -C "$SB_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || refuse "$SB_ROOT is not in a git work tree"
cd "$SB_ROOT" || exit 1
# Run from the draft worktree itself, act for the project it was cut from.
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
prefix=$(git rev-parse --show-prefix)
main=$(git worktree list --porcelain | awk '/^worktree /{ print substr($0, 10); exit }')
SB_ROOT="$main/${prefix%/}"; SB_ROOT=${SB_ROOT%/}
cd "$SB_ROOT" || exit 1
branch="serial-build/draft-$gate"
wt="$(sb_state_dir)/draft-$gate"
draftpath="${prefix}docs/plan.md"
has_branch() { git show-ref -q --verify "refs/heads/$branch"; }
base_of() { git log -1 --format=%B "$branch" 2>/dev/null | sed -n 's/^Draft-base: //p' | head -n 1; }

case "$mode" in
  start)
    [ -f docs/roadmap.md ] && grep -qx "### $gate" docs/roadmap.md || refuse "docs/roadmap.md has no written-out gate \"### $gate\"; write it out through /serial-build:intake first"
    [ -f docs/plan.md ] && [ "$(awk '/^# /{print substr($0, 3); exit}' docs/plan.md)" = "$gate" ] && refuse "$gate is the active plan already"
    has_branch && refuse "a draft of $gate already exists (plan-draft.sh status $gate); drop it first to start over"
    git worktree add -q -b "$branch" "$wt" HEAD || refuse "could not make the draft worktree"
    there="$wt/${prefix%/}"; there=${there%/}
    printf 'plan-draft: the draft of %s will be written in %s, on the branch %s, cut at %s.\nLaunch the draft session there:\n  cd "%s" && claude --bg --name "draft plan: %s" "/serial-build:gate --draft %s"\n' "$gate" "$there" "$branch" "$(git rev-parse --short HEAD)" "$there" "$gate" "$gate"
    ;;
  save)
    has_branch || refuse "no draft of $gate was started (plan-draft.sh start $gate)"
    file=${3:-"$wt/$draftpath"}
    [ -f "$file" ] || refuse "no draft at $file"
    [ "$(awk '/^# /{print substr($0, 3); exit}' "$file")" = "$gate" ] || refuse "$file is not a plan for $gate (its first line must be \"# $gate\")"
    base=$(base_of); [ -n "$base" ] || base=$(git rev-parse "$branch")
    [ "$file" = "$wt/$draftpath" ] || cp "$file" "$wt/$draftpath" || refuse "could not copy $file into the draft worktree"
    git -C "$wt" add -- "$draftpath" && git -C "$wt" commit -q -m "Draft plan: $gate

Draft-base: $base" -- "$draftpath" || refuse "could not commit the draft"
    echo "plan-draft: the draft of $gate is saved on $branch, reviewed against $(git rev-parse --short "$base"). /serial-build:gate takes it once $gate is next."
    ;;
  status)
    has_branch || { echo "plan-draft: no draft of $gate"; exit 1; }
    base=$(base_of)
    [ -n "$base" ] || { echo "plan-draft: a draft of $gate is in progress in $wt, not yet saved"; exit 2; }
    echo "plan-draft: a draft of $gate is saved, reviewed against $(git rev-parse --short "$base")"
    ;;
  delta)
    base=$(base_of); [ -n "$base" ] || refuse "no saved draft of $gate"
    section() { awk -v h="### $gate" '$0 == h { on = 1; print; next } on && /^(#|##|###) / { exit } on'; }
    problems=
    if [ "$(git show "$base:./docs/roadmap.md" 2>/dev/null | section)" != "$(section < docs/roadmap.md)" ]; then
      problems="docs/roadmap.md: the $gate section changed
"
    fi
    named=$(git show "$branch:$draftpath" | grep -o '`[^` ]*[/.][^` ]*`' | tr -d '`' | sed 's/[:#].*//' | LC_ALL=C sort -u)
    watched=$( { printf '%s\n' "$named"; echo docs/design.md; echo docs/tech/architecture.md; echo docs/open.md
      git diff --name-only --relative "$base" -- docs/decisions | grep -v '^docs/decisions/sources/'; } | sed '/^$/d' | LC_ALL=C sort -u)
    files=$(printf '%s\n' "$watched" | while IFS= read -r f; do
      [ -e "$f" ] || git cat-file -e "$base:./$f" 2>/dev/null || continue
      git diff --quiet "$base" -- "$f" 2>/dev/null || printf '%s\n' "$f"
    done)
    [ -n "$files" ] && problems="$problems$files
"
    if [ -z "$problems" ]; then
      echo "plan-draft: nothing the draft of $gate depends on changed since $(git rev-parse --short "$base"); it can go to the owner as reviewed."
      exit 0
    fi
    printf 'plan-draft: since %s these changed, so the draft of %s needs one review pass on the change:\n%s' "$(git rev-parse --short "$base")" "$gate" "$problems"
    [ -n "$files" ] && { printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 git diff --stat "$base" --; }
    exit 3
    ;;
  take)
    base=$(base_of); [ -n "$base" ] || refuse "no saved draft of $gate"
    git show "$branch:$draftpath"
    ;;
  drop)
    [ -d "$wt" ] && git worktree remove --force "$wt"
    has_branch && git branch -D -q "$branch"
    echo "plan-draft: the draft of $gate is dropped."
    ;;
esac
