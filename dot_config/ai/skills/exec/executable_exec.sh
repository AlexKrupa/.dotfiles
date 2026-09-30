#!/usr/bin/env bash
# Usage: exec.sh [--fresh] <subagent|native> <effort> <plan-path>
# Starts bin/herdr-after-turn.sh detached. After this Claude turn, it sets the effort and submits
# the superpowers execution command with the absolute plan path. With --fresh, it first clears the
# session, with the plan file name as the old title.
# Exit codes: 0 ok, 1 error
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
AFTER_TURN=${HERDR_AFTER_TURN:-$here/../../bin/herdr-after-turn.sh}

die() { echo "exec: $1" >&2; exit 1; }

fresh=
if [[ ${1:-} == --fresh ]]; then fresh=1; shift; fi
[[ $# -eq 3 ]] || die "usage: exec.sh [--fresh] <subagent|native> <effort> <plan-path>"
mode=$1 effort=$2 plan=$3
[[ ${HERDR_ENV:-} == 1 ]] || die "this session does not run in a herdr pane"
case $mode in
  subagent) skill=subagent-driven-development ;;
  native) skill=executing-plans ;;
  *) die "mode must be subagent or native, not '$mode'" ;;
esac
case $effort in
  low | medium | high | xhigh | max) ;;
  *) die "effort must be low, medium, high, xhigh, or max, not '$effort'" ;;
esac
[[ -f $plan ]] || die "no plan file at $plan"
plan="$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")"

pane=$(herdr pane current --current | jq -r '.result.pane.pane_id // empty') || true
[[ -n $pane ]] || die "cannot find the herdr pane of this session"

clear=()
[[ -z $fresh ]] || clear=(--clear "$(basename "$plan" .md)")
# Detached, so it lives after this turn. It waits until the turn ends.
nohup "$AFTER_TURN" "$pane" ${clear[@]+"${clear[@]}"} "/effort $effort" \
  <<<"/superpowers:$skill $plan" >>"${TMPDIR:-/tmp}/exec.log" 2>&1 &
echo "$skill - $effort - $plan"
