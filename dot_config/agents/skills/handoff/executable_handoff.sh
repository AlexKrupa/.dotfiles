#!/usr/bin/env bash
# Usage: handoff.sh path <topic> [<ticket-id>]
#        handoff.sh refresh <file>
# "path" makes the folder ~/.ai/<repo>/handoffs/ and prints the path of a new handoff file:
# YYYY-MM-DD-HHMM-[<ticket-id>-]<topic slug>.md.
# "refresh" starts bin/herdr-after-turn.sh, which clears this Claude session after the turn and
# submits "Continue from `<file>`." The old conversation gets the file name as its /resume title.
# In a nono sandbox (NONO_CAP_FILE is set), runs the helper in the foreground: nono denies herdr
# calls from a detached process. Claude runs the script as a background task there.
# Exit codes: 0 ok, 1 error, 4 not in herdr (prints the line to paste after /clear)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
bin=$(cd "$here/../../bin" && pwd)
after_turn=${HANDOFF_AFTER_TURN:-$bin/herdr-after-turn.sh}

die() { echo "handoff: $1" >&2; exit 1; }

case ${1:-} in
  path)
    [[ $# -ge 2 ]] || die "usage: handoff.sh path <topic> [<ticket-id>]"
    slug=$(printf '%s' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
      | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    [[ -n $slug ]] || die "topic has no letters or digits: $2"
    dir="$HOME/.ai/$("$bin/repo-slug.sh")/handoffs"
    mkdir -p "$dir"
    echo "$dir/${HANDOFF_DATE:-$(date +%Y-%m-%d-%H%M)}-${3:+$3-}$slug.md"
    ;;
  refresh)
    file=${2:-}
    [[ -s $file ]] || die "no handoff file: $file"
    prompt="Continue from \`$file\`."
    if [[ ${HERDR_ENV:-} != 1 ]]; then echo "$prompt"; exit 4; fi
    pane=$(herdr pane current --current | jq -r '.result.pane.pane_id // empty') || true
    [[ -n $pane ]] || die "cannot find the herdr pane of this session"
    name=$(basename "$file" .md)
    log="${TMPDIR:-/tmp}/handoff-refresh.log"
    if [[ -n ${NONO_CAP_FILE:-} ]]; then
      exec "$after_turn" "$pane" --clear "$name" <<<"$prompt" >>"$log" 2>&1
    fi
    # Detached, so it lives after this turn. It waits until the turn ends.
    nohup "$after_turn" "$pane" --clear "$name" <<<"$prompt" >>"$log" 2>&1 &
    ;;
  *) die "usage: handoff.sh path <topic> [<ticket-id>] | handoff.sh refresh <file>" ;;
esac
