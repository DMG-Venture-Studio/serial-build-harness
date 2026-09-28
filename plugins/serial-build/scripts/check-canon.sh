#!/bin/sh
# The mechanical checks /serial-build:intake, /serial-build:gate, and
# /serial-build:handoff run before asking the product owner for anything, so a
# broken ledger is caught by a command rather than by the owner reading prose.
# Prints PASS or FAIL per check with file:line for each problem; exit 1 on any FAIL.
# Usage: check-canon.sh [project root, default: the working directory]
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
root=${1:-$(sb_project_root)}
cd "$root" || exit 1
docs=docs
failed=0

report() { # report NAME PROBLEMS
  if [ -z "$2" ]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n' "$1"
    printf '%s\n' "$2" | sed 's/^/        /'
    failed=1
  fi
}

for f in design.md roadmap.md done.md open.md glossary.md tech/architecture.md; do
  [ -f "$docs/$f" ] || missing="${missing:-}$docs/$f is missing
"
done
report "every standing doc exists" "$(printf '%s' "${missing:-}" | sed '/^$/d')"

# Roadmap gates carry the full section set, and every demo has the owner's break step.
problems=$([ -f "$docs/roadmap.md" ] && awk -v file="$docs/roadmap.md" '
  function flush(   i) {
    if (gate == "") return
    for (i = 1; i <= nlab; i++) if (!(lab[i] in seen)) printf "%s:%d gate %s has no \"%s:\" section\n", file, line, gate, lab[i]
    if (!brk) printf "%s:%d gate %s: its Demo has no \"Break it:\" step, where the owner tries to break it\n", file, line, gate
  }
  BEGIN { nlab = split("Builds|Demo|Depends on|Decided|Decide by proof|Open|QA|Tried to break|Acceptance", lab, "|") }
  /^### / { flush(); gate = substr($0, 5); line = NR; delete seen; brk = 0; next }
  /^## / { flush(); gate = ""; next }
  gate != "" {
    for (i = 1; i <= nlab; i++) if (index($0, lab[i] ":") == 1) seen[lab[i]] = 1
    if (index($0, "Break it:") > 0) brk = 1
  }
  END { flush() }' "$docs/roadmap.md")
report "every roadmap gate has Builds, Demo (with a Break it: step), Depends on, Decided, Decide by proof, Open, QA, Tried to break, Acceptance" "$problems"

# Done entries carry their proof, the red lane's record, and the owner's words.
problems=$([ -f "$docs/done.md" ] && awk -v file="$docs/done.md" '
  function flush(   i) {
    if (gate == "") return
    if (!(("Proof") in seen) && !(("Manual") in seen)) printf "%s:%d %s has neither Proof: nor Manual:\n", file, line, gate
    for (i = 1; i <= nlab; i++) if (!(lab[i] in seen)) printf "%s:%d %s has no \"%s:\" line\n", file, line, gate, lab[i]
  }
  BEGIN { nlab = split("Date|Tried to break|Accepted", lab, "|") }
  /^## / { flush(); gate = substr($0, 4); line = NR; delete seen; next }
  gate != "" { if (match($0, /^[A-Z][A-Za-z ]*:/)) seen[substr($0, 1, RLENGTH - 1)] = 1 }
  END { flush() }' "$docs/done.md")
report "every done entry has Date, Proof or Manual, Tried to break, Accepted" "$problems"

# Every done entry was written by ship-gate.sh: its closing checksum matches.
if [ -f "$docs/done.md" ]; then
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/sb-canon.XXXXXX")
  awk -v dir="$tmpd" '
    function close_entry() { if (slug != "") printf "%d\t%s\t%s\n", n, slug, (sum == "" ? "none" : sum); slug = ""; sum = ""; held = "" }
    /^## / { close_entry(); n++; slug = substr($0, 4); f = dir "/" n; printf "%s\n", $0 > f; on = 1; next }
    on && /^<!-- ship-gate [0-9-]+ -->$/ { sum = $3; on = 0; close(f); next }
    on && !NF { held = held "\n"; next }
    on { printf "%s%s\n", held, $0 > f; held = ""; next }
    END { close_entry() }' "$docs/done.md" > "$tmpd/index"
  problems=$(while IFS="$(printf '\t')" read -r k slug sum; do
    if [ "$sum" = none ]; then
      printf '%s: entry %s has no ship-gate checksum; only scripts/ship-gate.sh writes done entries\n' "$docs/done.md" "$slug"
    elif [ "$(cksum < "$tmpd/$k" | awk '{print $1 "-" $2}')" != "$sum" ]; then
      printf '%s: entry %s changed after ship-gate.sh wrote it\n' "$docs/done.md" "$slug"
    fi
  done < "$tmpd/index")
  rm -rf "$tmpd"
  report "every done entry is as ship-gate.sh wrote it" "$problems"
fi

# One slug, one thing: no gate both pending and done, no duplicate headings.
problems=$( {
  [ -f "$docs/roadmap.md" ] && awk '/^### /{print substr($0, 5) "\troadmap"}' "$docs/roadmap.md"
  [ -f "$docs/done.md" ] && awk '/^## /{print substr($0, 4) "\tdone"}' "$docs/done.md"
  [ -f "$docs/open.md" ] && awk '/^## /{print substr($0, 4) "\topen"}' "$docs/open.md"
} | awk -F '\t' '{ if ($1 in at) printf "slug %s appears in %s and in %s\n", $1, at[$1], $2; else at[$1] = $2 }')
report "every gate and open-question slug is unique" "$problems"

# Every "See `slug`" resolves to a decision record, an open question, or a gate.
slugs=$( {
  for f in "$docs"/decisions/*.md; do [ -f "$f" ] && basename "$f" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//'; done
  [ -f "$docs/open.md" ] && awk '/^## /{print substr($0, 4)}' "$docs/open.md"
  [ -f "$docs/roadmap.md" ] && awk '/^### /{print substr($0, 5)}' "$docs/roadmap.md"
  [ -f "$docs/done.md" ] && awk '/^## /{print substr($0, 4)}' "$docs/done.md"
  [ -f "$docs/plan.md" ] && awk '/^# /{print substr($0, 3); exit}' "$docs/plan.md"
} | sort -u)
files=$(find "$docs" -name '*.md' ! -path '*/decisions/sources/*' 2>/dev/null | sort)
problems=$(for f in $files; do
  awk -v file="$f" '{
    line = $0
    while (match(line, /[Ss]ee `[a-z0-9][a-z0-9-]*`/)) {
      ref = substr(line, RSTART, RLENGTH); sub(/^[Ss]ee `/, "", ref); sub(/`$/, "", ref)
      print file ":" NR "\t" ref
      line = substr(line, RSTART + RLENGTH)
    }
  }' "$f"
done | while IFS="$(printf '\t')" read -r at ref; do
  printf '%s\n' "$slugs" | grep -qx "$ref" || printf '%s See `%s` names no decision record, open question, or gate\n' "$at" "$ref"
done)
report "every See \`slug\` reference resolves" "$problems"

# Standing docs are plain prose: no file paths, and no dates outside the history.
problems=$(for f in design.md roadmap.md open.md glossary.md; do
  [ -f "$docs/$f" ] && awk -v file="$docs/$f" '/docs\/|[A-Za-z0-9_-]+\.md([^A-Za-z]|$)/ { printf "%s:%d names a file path; cite a slug and say what it is\n", file, NR }' "$docs/$f"
done)
report "no file paths in design, roadmap, open, glossary" "$problems"
problems=$(for f in design.md roadmap.md open.md glossary.md tech/architecture.md; do
  [ -f "$docs/$f" ] && awk -v file="$docs/$f" '/[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]/ { printf "%s:%d carries a date; dates live only in decision records and done entries\n", file, NR }' "$docs/$f"
done)
report "no dates in the standing docs" "$problems"

# Decision records are dated, named by slug, and carry their three sections.
check_record() { # a function, not inline: bash 3.2 misparses case inside $( )
  case "$(basename "$1")" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md) ;;
    *) printf '%s is not named YYYY-MM-DD-slug.md\n' "$1" ;;
  esac
  for h in '^Date: ' '^## Decided' '^## Rejected' '^## Reopens if'; do
    grep -q "$h" "$1" || printf '%s has no "%s" line\n' "$1" "$(printf '%s' "$h" | sed 's/^\^//')"
  done
}
problems=$(for f in "$docs"/decisions/*.md; do [ -f "$f" ] && check_record "$f"; done)
report "every decision record has Date, Decided, Rejected, Reopens if" "$problems"

# The glossary is alphabetical; entries added since the last commit need the owner's approval by name.
if [ -f "$docs/glossary.md" ]; then
  problems=$(awk -v file="$docs/glossary.md" '/^- \*\*/ { t = $0; sub(/^- \*\*/, "", t); sub(/\*\*.*/, "", t); t = tolower(t)
    if (prev != "" && t < prev) printf "%s:%d \"%s\" is out of alphabetical order\n", file, NR, t; prev = t }' "$docs/glossary.md")
  report "glossary entries are alphabetical" "$problems"
  if command -v git >/dev/null 2>&1 && git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    added=$(git diff HEAD -- "$docs/glossary.md" 2>/dev/null | awk '/^\+- \*\*/ { t = $0; sub(/^\+- \*\*/, "", t); sub(/\*\*.*/, "", t); print t }')
  else
    added=$(awk '/^- \*\*/ { t = $0; sub(/^- \*\*/, "", t); sub(/\*\*.*/, "", t); print t }' "$docs/glossary.md")
  fi
  if [ -n "$added" ]; then
    printf 'NOTE  glossary entries new since the last commit; name each for the owner'"'"'s approval: %s\n' "$(printf '%s' "$added" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  fi
fi

# The active plan names its gate, its acceptance, and what the red lane must try.
if [ -f "$docs/plan.md" ]; then
  problems=$(awk -v file="$docs/plan.md" '
    NR == 1 && !/^# [a-z0-9][a-z0-9-]*$/ { printf "%s:1 the first line must be \"# <gate-slug>\"\n", file }
    /^Acceptance:/ { acc = 1 } /^Tried to break/ { tried = 1 } /^Proof/ || /^Manual:/ { proof = 1 }
    END { if (!acc) printf "%s has no Acceptance: line\n", file; if (!tried) printf "%s has no \"Tried to break\" list for the red lane\n", file
          if (!proof) printf "%s has no Proof block (indented commands) or Manual: line for done to re-run\n", file }' "$docs/plan.md")
  report "the active plan names its gate, acceptance, proof, and tried-to-break list" "$problems"
fi

exit $failed
