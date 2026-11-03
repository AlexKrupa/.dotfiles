#!/usr/bin/env bash
# Usage: exec.sh [--fresh] <subagent|native> <effort> <review-effort> <plan-path>
#        exec.sh review <effort> <plan-path>
# Starts bin/herdr-after-turn.sh detached. After this agent turn, it sets the effort and submits a
# command with the absolute plan path:
# - Execution: the superpowers execution command, with a sentence that starts the review handoff
#   after the last task. With --fresh, it first clears the session, with the plan file name as the
#   old title.
# - Review: `/exec review <plan>`. It always clears the session first.
# In a nono sandbox (NONO_CAP_FILE is set), prints the result line, then runs the helper in the
# foreground. The agent runs the script as a background task there.
# Exit codes: 0 ok, 1 error
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
AFTER_TURN=${HERDR_AFTER_TURN:-$here/../../bin/herdr-after-turn.sh}

die() { echo "exec: $1" >&2; exit 1; }
usage="usage: exec.sh [--fresh] <subagent|native> <effort> <review-effort> <plan-path>
       exec.sh review <effort> <plan-path>"

check_effort() {
  case $1 in
    low | medium | high | xhigh | max) ;;
    *) die "effort must be low, medium, high, xhigh, or max, not '$1'" ;;
  esac
}

phase=execution
if [[ ${1:-} == review ]]; then
  phase=review
  [[ $# -eq 3 ]] || die "$usage"
  effort=$2 plan=$3
  check_effort "$effort"
else
  fresh=
  if [[ ${1:-} == --fresh ]]; then fresh=1; shift; fi
  [[ $# -eq 4 ]] || die "$usage"
  mode=$1 effort=$2 review_effort=$3 plan=$4
  case $mode in
    subagent) skill=subagent-driven-development ;;
    native) skill=executing-plans ;;
    *) die "mode must be subagent or native, not '$mode'" ;;
  esac
  check_effort "$effort"
  check_effort "$review_effort"
fi
[[ ${HERDR_ENV:-} == 1 ]] || die "this session does not run in a herdr pane"
[[ -f $plan ]] || die "no plan file at $plan"
plan="$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")"
name=$(basename "$plan" .md)

if [[ $phase == review ]]; then
  label="exec review"
  clear=(--clear "$name execution")
  prompt="/exec review $plan"
else
  label=$skill
  clear=()
  [[ -z $fresh ]] || clear=(--clear "$name")
  prompt="/superpowers:$skill $plan After the last task, read $here/SKILL.md, section \"Review handoff\", and follow it with review effort $review_effort."
fi

pane=$(herdr pane current --current | jq -r '.result.pane.pane_id // empty') || true
[[ -n $pane ]] || die "cannot find the herdr pane of this session"

if [[ -n ${NONO_CAP_FILE:-} ]]; then
  # nono denies herdr calls from a detached process: its ancestry does not reach the sandbox
  # session. A background task of the agent keeps that ancestry.
  echo "$label - $effort - $plan"
  exec "$AFTER_TURN" "$pane" "${clear[@]}" "effort $effort" \
    <<<"$prompt" >>"${TMPDIR:-/tmp}/exec.log" 2>&1
fi
# Detached, so it lives after this turn. It waits until the turn ends.
nohup "$AFTER_TURN" "$pane" "${clear[@]}" "effort $effort" \
  <<<"$prompt" >>"${TMPDIR:-/tmp}/exec.log" 2>&1 &
echo "$label - $effort - $plan"
