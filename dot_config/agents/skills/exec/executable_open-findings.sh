#!/usr/bin/env bash
# Usage: open-findings.sh <plan-path>
# Finds the Superpowers workspace of the plan (.superpowers/sdd/<dir>/ with a plan-path marker
# that names the plan) and copies the deferred findings and the rulings of its ledger to
# <workspace>/open-findings.md. Prints the workspace path, then the file path. Prints nothing if
# the plan has no workspace, and only the workspace path if the ledger has no such lines.
# Exit codes: 0 ok, 1 error
set -euo pipefail

die() { echo "open-findings: $1" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: open-findings.sh <plan-path>"
plan=$1
[[ -f $plan ]] || die "no plan file at $plan"
root=$(git rev-parse --show-toplevel) || die "not in a git repo: $PWD"

# The same plan id as superpowers sdd-workspace: repo-relative in the repo, else absolute.
plan_dir=$(cd "$(dirname "$plan")" && pwd -P)
plan_abs="$plan_dir/$(basename "$plan")"
case $plan_abs in
  "$root"/*) plan_id=${plan_abs#"$root"/} ;;
  *) plan_id=$plan_abs ;;
esac

workspace=
for marker in "$root"/.superpowers/sdd/*/plan-path; do
  [[ -f $marker && $(cat "$marker") == "$plan_id" ]] || continue
  workspace=$(dirname "$marker")
  break
done
[[ -n $workspace ]] || exit 0
echo "$workspace"

ledger=$workspace/progress.md
findings=$workspace/open-findings.md
[[ -f $ledger ]] || exit 0
grep -E 'minor \(deferred\)|Ruling:' "$ledger" >"$findings" || { rm -f "$findings"; exit 0; }
echo "$findings"
