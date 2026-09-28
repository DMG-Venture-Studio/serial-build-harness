#!/bin/sh
# Tells /serial-build:scope what kind of repository it is standing in, so it
# never scaffolds over someone's work by assumption.
#   greenfield  nothing but a licence, a readme, a .gitignore, editor litter, or
#               Claude Code's own .claude/settings.json (a project-scope plugin
#               install writes one)
#   existing    other files are present: ask before scaffolding, never overwrite
#   scoped      .claude/serial-build.json exists: the project is already set up
# Also prints the harness files already present and the git author name, which
# /serial-build:scope offers as the product owner's name.
# Usage: detect-state.sh [dir, default: the working directory]
set -u
dir=${1:-$(pwd)}
cd "$dir" || exit 1

others=$(find . -mindepth 1 \( -name .git -o -name node_modules -o -name .venv \) -prune -o -type f -print 2>/dev/null \
  | sed 's|^\./||' \
  | grep -v -i -E '^(license|licence|copying)([.-].*)?$|^readme(\..*)?$|^\.gitignore$|(^|/)\.DS_Store$|^\.claude/settings(\.local)?\.json$' \
  | sort)
count=$(printf '%s' "$others" | grep -c .)

if [ -f .claude/serial-build.json ]; then state=scoped
elif [ "$count" -eq 0 ]; then state=greenfield
else state=existing
fi
echo "state: $state"
echo "other files: $count"
[ "$count" -gt 0 ] && printf '%s\n' "$others" | head -n 30 | sed 's/^/  /'
[ "$count" -gt 30 ] && echo "  ... and $((count - 30)) more"

echo "harness files present:"
for f in CLAUDE.md .claude/serial-build.json .claude/rules docs/design.md docs/tech/architecture.md docs/glossary.md docs/roadmap.md docs/done.md docs/open.md docs/plan.md docs/decisions claude_outputs .gitignore; do
  [ -e "$f" ] && echo "  $f"
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "git: yes, $(git rev-list --count HEAD 2>/dev/null || echo 0) commits"
  echo "git author: $(git config user.name 2>/dev/null || echo unknown)"
else
  echo "git: no"
fi
