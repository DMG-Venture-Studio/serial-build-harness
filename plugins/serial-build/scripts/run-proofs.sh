#!/bin/sh
# The handoff's audit: re-runs every command in every Proof block of
# docs/done.md, from the project root, and reports each result; a Manual: entry
# is reported as "manual, not re-run". It holds the proof marker while it runs,
# because a proof may change the tree on purpose and undo the change at its end
# (a planted-violation check), and the stop hook must not run the tests on the
# half-changed tree, however many turns the run spans. A proof that leaves the
# tree changed is named, since the next stop check would test what it left.
#
#   run-proofs.sh           exit 0 when every proof passes, 1 when one fails
#                           (its output's tail is printed for ship-gate.sh
#                           --regress), 3 while another proof run is live.
#   run-proofs.sh --clear   removes a marker a run left when it died. Refuses
#                           while the run that holds it is alive.
#
# Run from the project root. Let it finish: run it in the background when it
# may outlast the tool's timeout, rather than running proofs one by one.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
SB_ROOT=$(sb_project_root)
cd "$SB_ROOT" || exit 1
done=docs/done.md
TAB=$(printf '\t')

if [ "${1:-}" = --clear ]; then
  pid=$(sb_proof_running); st=$?
  case $st in
    0) echo "run-proofs: a proof run (pid $pid) is still running; let it finish" >&2; exit 3 ;;
    1) echo "run-proofs: no proof marker is held"; exit 0 ;;
  esac
  rm -f "$(sb_proof_marker)"
  echo "run-proofs: cleared the marker left by proof run $pid"
  exit 0
fi

[ -f "$done" ] || { echo "run-proofs: no $done, so nothing has shipped and there is nothing to re-run"; exit 0; }
# One row per command: gate, then the command or MANUAL. A gate with neither is
# listed with NONE, so a done entry with nothing to re-run is not passed over.
rows=$(awk -v tab="$TAB" '
  function flush() { if (gate != "" && !any) print gate tab "NONE" }
  /^## / { flush(); gate = substr($0, 4); any = 0; on = 0; next }
  gate == "" { next }
  /^Proof:/ { on = 1; next }
  /^Manual:/ { print gate tab "MANUAL"; any = 1; on = 0; next }
  on && /^    / { print gate tab substr($0, 5); any = 1; next }
  on && NF { on = 0 }
  END { flush() }' "$done")
[ -n "$rows" ] || { echo "run-proofs: $done holds no shipped gate"; exit 0; }

if ! sb_proof_hold run-proofs.sh; then
  echo "run-proofs: another proof run (pid $(sb_proof_running)) is live; two at once would change the tree under each other" >&2
  exit 3
fi
out=$(mktemp "${TMPDIR:-/tmp}/sb-proofs.XXXXXX") || exit 1
trap 'sb_proof_release; rm -f "$out"' EXIT
trap 'exit 130' INT TERM HUP

# tree: the uncommitted files and their checksums, to see what a proof left.
tree() { sb_changed_files | while IFS= read -r f; do printf '%s %s\n' "$(sb_sum "$f")" "$f"; done; }

failed= left= status=0
while IFS="$TAB" read -r gate cmd; do
  case "$cmd" in
    MANUAL) echo "manual, not re-run: $gate"; continue ;;
    NONE) echo "no proof to re-run: $gate"; continue ;;
  esac
  before=$(tree)
  if (sh -c "$cmd") > "$out" 2>&1 < /dev/null; then
    echo "pass: $gate: $cmd"
  else
    echo "FAIL: $gate: $cmd"
    tail -n 20 "$out" | sed 's/^/    /'
    failed="$failed $gate"
    status=1
  fi
  after=$(tree)
  if [ "$before" != "$after" ]; then
    changed=$( { printf '%s\n' "$before"; printf '%s\n' "$after"; } | sort | uniq -u | cut -d ' ' -f 2- | sort -u | tr '\n' ' ')
    echo "    warning: it left the tree changed: $changed"
    left="$left $gate"
  fi
done <<EOF
$rows
EOF

if [ -n "$left" ]; then
  echo "run-proofs: a proof left changes in the tree (${left# }). A proof that changes the tree must undo it before it exits, even when it fails; undo what it left, and file the fix to the proof through /serial-build:intake."
fi
if [ -n "$failed" ]; then
  for g in $(printf '%s\n' $failed | sort -u); do
    echo "run-proofs: $g fails its proof; move it back with: ship-gate.sh --regress $g --failed \"<the failing output above>\""
  done
fi
exit $status
