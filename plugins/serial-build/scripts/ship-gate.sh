#!/bin/sh
# The only writer of docs/done.md, so "done" is decided by code: models propose,
# code decides. A hook refuses Edit and Write calls on that file, and every entry
# this script writes ends with a checksum the canon check verifies, so an entry
# changed any other way is reported.
#
#   ship-gate.sh <gate-slug> --accepted "<the owner's words, verbatim>"
#     Refuses, writing nothing, unless: docs/plan.md is this gate's plan; the red
#     lane's record is credible and every finding resolved or demoted
#     (red-status.sh); the plan has a Proof block or a Manual: line; every proof
#     command passes now; and the owner's words are given. Then it appends the
#     done entry (date, proof commands plus each red finding's reproduce command,
#     what the red lane tried, the owner's words), removes the gate from
#     docs/roadmap.md, lists the plan's unticked tasks, and deletes docs/plan.md.
#
#   ship-gate.sh --demote <red-slug> --owner-said "<the owner's words, verbatim>"
#     Records that the owner judged a red finding not to be a real failure (the
#     test asserts something the product should not do), and commits the plan as
#     "serial-build: demote <red-slug>", the only form red-status.sh accepts.
#
#   ship-gate.sh --regress <gate-slug> --failed "<the failing proof output>"
#     Moves a shipped gate whose proof no longer passes back to the top of the
#     roadmap as a regression gate, files the failing output and the old entry
#     under the decision sources, and only then removes its done entry.
#
# The owner's acceptance and demotions are their acts; this script only records
# them. Pass words they actually said, never a paraphrase. Run from the project root.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
SB_ROOT=$(sb_project_root)
cd "$SB_ROOT" || exit 1
plan=docs/plan.md done=docs/done.md roadmap=docs/roadmap.md
today=$(date +%Y-%m-%d)
TAB=$(printf '\t')
refuse() { printf 'ship-gate: %s\n' "$1" >&2; exit 1; }

# remove_section FILE HEADING_PREFIX SLUG: drops the "<prefix> <slug>" section, up
# to the next heading of the same or a higher level or a stage's "Later:" list,
# which belongs to the stage. Lines inside fenced code blocks never end it.
remove_section() {
  awk -v h="$2 $3" -v level="$2" '
    $0 == h { skip = 1; fence = 0; next }
    skip && /^(```|~~~)/ { fence = !fence; next }
    skip && !fence && /^#+ / { split($0, parts, " "); if (length(parts[1]) <= length(level)) skip = 0 }
    skip && !fence && /^Later:/ { skip = 0 }
    !skip' "$1" > "$1.sb-tmp" && mv "$1.sb-tmp" "$1"
}

if [ "${1:-}" = --demote ]; then
  slug=${2:-}
  [ "${3:-}" = --owner-said ] && [ -n "${4:-}" ] || refuse 'usage: ship-gate.sh --demote <red-slug> --owner-said "<the owner'"'"'s words>"'
  [ -f "$plan" ] || refuse "no docs/plan.md"
  LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$plan" | awk -F '\t' -v s="$slug" '$1 == "FIND" && $3 == s { f = 1 } END { exit !f }' \
    || refuse "docs/plan.md records no finding $slug"
  line="Demoted $slug: \"$4\""
  awk -v add="$line" '
    /^## Red[[:space:]]*$/ { inred = 1 }
    inred && /^## / && !/^## Red/ { print add; print ""; inred = 0; done = 1 }
    { print }
    END { if (!done) { print ""; print add } }' "$plan" > "$plan.sb-tmp" && mv "$plan.sb-tmp" "$plan"
  git add -- "$plan" && git commit -q -m "serial-build: demote $slug" -- "$plan" || refuse "could not commit the demotion"
  echo "ship-gate: $slug demoted on the owner's word and committed; it no longer blocks the gate, and its test is not part of the proof."
  exit 0
fi

if [ "${1:-}" = --regress ]; then
  slug=${2:-}
  [ "${3:-}" = --failed ] && [ -n "${4:-}" ] || refuse 'usage: ship-gate.sh --regress <gate-slug> --failed "<the failing output>"'
  failed=$4
  [ -f "$done" ] && grep -qx "## $slug" "$done" || refuse "docs/done.md has no entry \"## $slug\""
  [ -f "$roadmap" ] || refuse "no docs/roadmap.md to move $slug back to"
  entry=$(awk -v h="## $slug" '$0 == h { on = 1; next } on && /^## / { exit } on' "$done")
  accepted=$(printf '%s\n' "$entry" | sed -n 's/^Accepted: //p' | head -n 1)
  src="regression-$slug"
  k=1
  while [ -e "docs/decisions/sources/$src.md" ]; do k=$((k + 1)); src="regression-$slug-$k"; done
  cat > "$roadmap.sb-gate" <<EOF
### $slug

Builds: the behaviour the shipped gate of the same name proved, restored. Its proof stopped passing; the failing output and the old proof commands are filed as the decision source $src.

Demo: the owner runs the gate's original demo again. Break it: the owner repeats the break step they used when they first accepted it.

Depends on: none.

Decided: the gate's original acceptance stands.

Decide by proof: none.

Open: none.

QA: every proof command in the decision source $src passes again.

Tried to break: the attacks recorded in the done entry filed in the decision source $src, and whatever change broke it, attacked again.

Acceptance: the owner can again say ${accepted:-the sentence they said when it first shipped}.
EOF
  cp "$roadmap" "$roadmap.sb-before"
  if grep -qx '## Stage: regressions' "$roadmap"; then
    awk -v f="$roadmap.sb-gate" -v goal="Goal: every shipped gate's proof passes again." '
      function put() { if (!hadgoal) { print goal; print "" } while ((getline l < f) > 0) print l; print ""; instage = 0 }
      $0 == "## Stage: regressions" { print; instage = 1; next }
      instage && /^Goal:/ { hadgoal = 1 }
      instage && /^#/ { put() }
      { print }
      END { if (instage) { print ""; put() } }' "$roadmap" > "$roadmap.sb-tmp"
  elif grep -q '^## ' "$roadmap"; then
    awk -v f="$roadmap.sb-gate" '!done && /^## / { print "## Stage: regressions\n\nGoal: every shipped gate'"'"'s proof passes again.\n"; while ((getline l < f) > 0) print l; print ""; done = 1 } { print }' "$roadmap" > "$roadmap.sb-tmp"
  else
    { cat "$roadmap"; printf '\n## Stage: regressions\n\nGoal: every shipped gate'"'"'s proof passes again.\n\n'; cat "$roadmap.sb-gate"; } > "$roadmap.sb-tmp"
  fi
  mv "$roadmap.sb-tmp" "$roadmap"
  rm -f "$roadmap.sb-gate"
  if ! grep -qx "### $slug" "$roadmap"; then
    mv "$roadmap.sb-before" "$roadmap"
    refuse "could not place $slug in docs/roadmap.md, so its done entry is left as it was"
  fi
  rm -f "$roadmap.sb-before"
  mkdir -p docs/decisions/sources
  {
    printf '# Source: %s stopped passing its proof\n\nRecorded %s by the handoff. The done entry as it stood, then the failing output, verbatim.\n\n---\n\n## The done entry\n\n%s\n\n## The failing output\n\n' "$slug" "$today" "$entry"
    printf '%s\n' "$failed" | sed 's/^/    /'
  } > "docs/decisions/sources/$src.md"
  remove_section "$done" "##" "$slug"
  echo "ship-gate: $slug is back at the top of the roadmap as a regression gate; its failing output is filed as the decision source $src."
  exit 0
fi

slug=${1:-}
[ "${2:-}" = --accepted ] && [ -n "${3:-}" ] || refuse 'usage: ship-gate.sh <gate-slug> --accepted "<the owner'"'"'s words, verbatim>"'
accepted=$3
[ -f "$plan" ] || refuse "no docs/plan.md, so no gate in flight"
active=$(awk '/^# /{print substr($0, 3); exit}' "$plan")
[ "$active" = "$slug" ] || refuse "docs/plan.md is the plan for $active, not $slug"

if ! red=$(sh "$SB_PLUGIN/scripts/red-status.sh" "$SB_ROOT"); then
  printf '%s\n' "$red" >&2
  refuse "$slug does not ship while the red lane's record is not clear (above)."
fi
printf '%s\n' "$red"

proofs=$(awk '/^Proof/ { on = 1; next } on && /^(    |\t)/ { sub(/^(    |\t)/, ""); print; next } on && NF { on = 0 }' "$plan")
manual=$(awk '/^Manual:/ { on = 1 } on && !NF { exit } on' "$plan")
[ -n "$proofs$manual" ] || refuse "docs/plan.md has no Proof block (indented commands under a line starting \"Proof\") and no Manual: line; done needs a proof that can be re-run"

records=$(LC_ALL=C awk -f "$SB_SCRIPTS/red-record.awk" "$plan")
rows() { printf '%s\n' "$records" | awk -F '\t' -v k="$1" '$1 == k'; }
demoted_slugs=$(rows DEMOTE | cut -f 2)
is_demoted() { printf '%s\n' "$demoted_slugs" | grep -qx "$1"; }
repro=$(rows FIND | awk -F '\t' '{ c[$3] = $5; if (!($3 in seen)) { seen[$3] = 1; order[++n] = $3 } } END { for (i = 1; i <= n; i++) print order[i] "\t" c[order[i]] }' \
  | while IFS="$TAB" read -r s c; do is_demoted "$s" || printf '%s\n' "$c"; done)

all=$(printf '%s\n%s\n' "$proofs" "$repro" | sed '/^$/d; /^-$/d')
out=$(mktemp "${TMPDIR:-/tmp}/sb-ship.XXXXXX") || exit 1
entryf=$(mktemp "${TMPDIR:-/tmp}/sb-entry.XXXXXX") || exit 1
trap 'rm -f "$out" "$entryf"' EXIT
if [ -n "$all" ]; then
  while IFS= read -r cmd; do
    if ! (sh -c "$cmd") > "$out" 2>&1; then
      tail -n 20 "$out" >&2
      refuse "a proof fails now, so $slug does not ship: $cmd"
    fi
    echo "proof passes: $cmd"
  done <<EOF
$all
EOF
fi

attempts=$(rows RUN | awk -F '\t' '{ t += $3 } END { print t + 0 }')
runs=$(rows RUN | grep -c .)
sources=$(rows RUN | cut -f 5 | grep -v '^-$' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
join() { awk 'NF { printf "%s%s", (n++ ? "; " : ""), $0 }'; }
guarded=$(rows FIND | awk -F '\t' '!seen[$3]++ { b = $6; sub(/^- red-[a-z0-9-]*: /, "", b); sub(/[. ]*Test: `.*/, "", b); print $3 " (" b ")" }' \
  | while IFS= read -r g; do is_demoted "${g%% *}" || printf '%s\n' "$g"; done | join)
demoted=$(rows DEMOTE | cut -f 3 | sed 's/^Demoted //' | join)

{
  printf '## %s\n\nDate: %s\n\n' "$slug" "$today"
  if [ -n "$all" ]; then
    printf 'Proof:\n\n'
    printf '%s\n' "$all" | sed 's/^/    /'
    echo
  fi
  [ -n "$manual" ] && printf '%s\n\n' "$manual"
  printf 'Tried to break: %s attempts by the red lane over %s run(s), raw output filed as %s; ' "$attempts" "$runs" "${sources:-no source}"
  if [ -n "$guarded" ]; then printf 'findings now guarded by the proof above: %s' "$guarded"; else printf 'none found'; fi
  [ -n "$demoted" ] && printf '; demoted by the owner: %s' "$demoted"
  printf '.\n\nAccepted: "%s"\n' "$accepted"
} > "$entryf"
sum=$(cksum < "$entryf" | awk '{print $1 "-" $2}')
{
  [ -s "$done" ] && [ -n "$(tail -c 1 "$done")" ] && echo
  echo
  cat "$entryf"
  printf '\n<!-- ship-gate %s -->\n' "$sum"
} >> "$done"

remove_section "$roadmap" "###" "$slug"
unticked=$(grep '^- \[ \]' "$plan")
rm -f "$plan"
echo "ship-gate: $slug moved to docs/done.md; docs/plan.md deleted."
if [ -n "$unticked" ]; then
  printf 'ship-gate: these tasks were not ticked; file each still-relevant one as a roadmap gate through /serial-build:intake:\n%s\n' "$unticked"
fi
if ! canon=$(sh "$SB_PLUGIN/scripts/check-canon.sh" "$SB_ROOT"); then
  printf '%s\n' "$canon"
  echo "ship-gate: warning: the gate shipped, but the canon check above fails; fix the docs it names (the ship itself is done and must not be repeated)."
fi
exit 0
