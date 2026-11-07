#!/bin/bash
# Usage: rex.sh <operation> [arguments]
# The Rex backend of bin/mux.sh, with the same operations, output and exit codes. A workspace is a
# Rex session. A pane is a Rex block.
set -uo pipefail

die() { echo "mux/rex: $1" >&2; exit 1; }

rex_cli=${REX_BIN_DIR:+$REX_BIN_DIR/}rex

query() {
  local filter=$1 json
  shift
  json=$("$rex_cli" "$@") || exit 1
  jq -r "$filter" <<<"$json" || exit 1
}

call() { "$rex_cli" "$@" >/dev/null || exit 1; }

tsv='map(. // "" | tostring | gsub("[\t\r\n]"; " ")) | join("\t")'

# The reported directory is a file:// URL with a host and percent-encoded bytes, or a plain path.
pane_cwd() {
  local cwd
  cwd=$(query '.foreground.cwd // empty' block call -b "$1" process) || exit 1
  if [[ -z $cwd ]]; then
    cwd=$(query '.pwd // empty' block call -b "$1" pwd) || exit 1
    if [[ $cwd == file://* ]]; then
      cwd=${cwd#file://}
      cwd=/${cwd#*/}
      cwd=$(printf '%b' "${cwd//%/\\x}")
    fi
  fi
  printf '%s\n' "$cwd"
}

# The first record is the root program. Claude Code reports its state with OSC 7501.
agent_state() { query '.records[0].state // empty' block call -b "$1" program_status; }

field() { printf '%s' "${1//[$'\t\r\n']/ }"; }

repo_name() {
  local main
  main=$(git -C "$1" worktree list --porcelain | sed -n '1s/^worktree //p')
  [[ -n $main ]] || die "not a git repo: $1"
  printf '%s\n' "${main##*/}"
}

# Lines: session id, worktree path. The label of a session can change, its id cannot.
worktree_sessions=${XDG_STATE_HOME:-$HOME/.local/state}/mux-rex/worktree-sessions

open_session() {
  local created session block sessions repo_session
  created=$("$rex_cli" new "$1/$3" --cwd "$2" --json) || exit 1
  session=$(jq -r '.session_id' <<<"$created") || exit 1
  mkdir -p "${worktree_sessions%/*}" && printf '%s\t%s\n' "$session" "$2" >>"$worktree_sessions" \
    || exit 1
  block=$(jq -r '.initial_windows[0].block_ids[0]' <<<"$created") || exit 1
  sessions=$("$rex_cli" ls --json) || exit 1
  repo_session=$(jq -r --arg label "$1" \
    'first(.sessions[] | select(.label == $label) | .session_id) // empty' <<<"$sessions")
  if [[ -n $repo_session ]]; then call session move "$session" --after "$repo_session"; fi
  printf '%s\t%s\n' "$session" "$block"
}

# A new shell drops the text typed before its first prompt.
wait_shell() {
  local deadline=$((SECONDS + ${MUX_PANE_READY_SECONDS:-10}))
  while [[ -z $(query '.pwd // empty' block call -b "$1" pwd) ]] && ((SECONDS < deadline)); do
    sleep 0.2
  done
}

operation=${1:-}
shift
case $operation in
  pane-current)
    [[ -n ${REX_BLOCK:-} ]] || die "REX_BLOCK is not set"
    printf '%s\n' "$REX_BLOCK"
    ;;
  pane-cwd) pane_cwd "$1" ;;
  pane-split)
    focus=false
    if [[ ${3:-} == --focus ]]; then focus=true; fi
    query '.block_ids[0]' split -b "$1" --split right --cwd "$2" "--focus=$focus" --json
    ;;
  pane-run)
    wait_shell "$1"
    call send -b "$1" "$2"
    call send-key -b "$1" enter
    ;;
  pane-rename) call block rename "$1" "$2" ;;
  pane-read) "$rex_cli" capture -b "$1" --trim --unwrap | tail -n "$2" ;;
  pane-zoom)
    case $2 in
      on | off) call zoom -b "$1" "--$2" ;;
      *) die "pane-zoom needs on or off, not '$2'" ;;
    esac
    ;;
  pane-labeled)
    session=$(query '.session_id' block inspect "$1" --json) || exit 1
    blocks=$("$rex_cli" block ls -s "$session" --json) || exit 1
    # jq -e exits 4 or 5 for bad input, and 4 means no multiplexer.
    jq -e --arg label "$2" 'any(.blocks[]; .label == $label)' <<<"$blocks" >/dev/null || exit 1
    ;;
  workspace-first-pane)
    query '[.windows[].layers[].blocks[].block_id][0] // empty' session inspect "$1" --json
    ;;
  workspace-label) query '.label' session inspect "$1" --json ;;
  workspace-rename) call session rename "$1" "$2" ;;
  workspace-close) call session kill "$1" ;;
  agent-kind)
    state=$(agent_state "$1") || exit 1
    [[ -n $state ]] || exit 0
    query '.foreground.name // empty' block call -b "$1" process
    ;;
  agent-session) die "agent sessions are not supported" ;;
  agent-start)
    pane=$1 name=$2 kind=$3
    shift 3
    [[ ${1:-} == -- ]] || die "usage: agent-start <pane> <name> <kind> -- <agent arguments>"
    shift
    # Single quotes, with '"'"' for a quote and '"\\"' for a backslash: the same words in POSIX
    # shells and fish. fish reads \' and \\ in single quotes as escapes.
    quote="'\"'\"'"
    backslash="'\"\\\\\"'"
    command="'$kind'"
    for arg in "$@"; do
      arg=${arg//\'/$quote}
      command+=" '${arg//\\/$backslash}'"
    done
    # A resume action finds the agents by this label: the label stays after a server restart.
    call block rename "$pane" "$kind: $name"
    wait_shell "$pane"
    call send -b "$pane" "$command"
    call send-key -b "$pane" enter
    seconds=${MUX_AGENT_START_SECONDS:-60}
    deadline=$((SECONDS + seconds))
    while [[ -z $(agent_state "$pane") ]]; do
      if ((SECONDS >= deadline)); then
        echo "mux/rex: the agent in $pane reported no status in $seconds s" >&2
        exit 6
      fi
      sleep 0.5
    done
    ;;
  agent-wait)
    seconds=${MUX_AGENT_WAIT_SECONDS:-600}
    deadline=$((SECONDS + seconds))
    session=$(query '.session_id' block inspect "$1" --json) || exit 1
    dir=$(mktemp -d) || exit 1
    mkfifo "$dir/events" || exit 1
    # No stderr: the trap kill makes rex print "Error: interrupted".
    "$rex_cli" events -s "$session" --json >"$dir/events" 2>/dev/null &
    events=$!
    # No job message when the trap kills the stream.
    disown "$events"
    trap 'kill "$events" 2>/dev/null; rm -rf "$dir"' EXIT
    exec 3<"$dir/events"
    # After the first line, client_connected, the stream has each change after the state check.
    IFS= read -r -t 5 _ <&3
    case $(agent_state "$1") in idle | done) exit 0 ;; esac
    filter='.payload.event | select(.type == "block_event") | .payload
      | select(.block_id == $pane and .name == "program_status_changed") | .payload.record.state'
    while ((SECONDS < deadline)); do
      if IFS= read -r -t 1 line <&3; then
        state=$(jq -r --arg pane "$1" "$filter" <<<"$line" 2>/dev/null)
        case $state in idle | done) exit 0 ;; esac
      else
        kill -0 "$events" 2>/dev/null || die "the event stream of session $session ended"
      fi
    done
    die "the agent in $1 did not end its turn in $seconds s"
    ;;
  agent-prompt)
    # As in herdr. With no agent, the shell runs the text. In a dialog, Enter selects an answer.
    state=$(agent_state "$1") || exit 1
    case $state in
      "") die "no agent in $1" ;;
      blocked) die "the agent in $1 waits for an answer" ;;
    esac
    # A bracketed paste: a newline in the text does not submit the prompt early. With no ESC,
    # the text cannot end the paste.
    call send -b "$1" $'\e[200~'"${2//$'\e'/}"$'\e[201~'
    call send-key -b "$1" enter
    ;;
  agent-list)
    sessions=$(query '.sessions[].session_id' ls --json) || exit 1
    for session in $sessions; do
      blocks=$(query '.blocks[].block_id' block ls -s "$session" --json) || exit 1
      for block in $blocks; do
        # `block ls` also lists a block whose terminal is gone, and its calls fail.
        state=$(agent_state "$block" 2>/dev/null) || continue
        [[ -n $state ]] || continue
        cwd=$(pane_cwd "$block" 2>/dev/null) || continue
        title=$(query '.title // empty' block call -b "$block" title 2>/dev/null) || continue
        printf '%s\t%s\t%s\t%s\n' "$block" "$(field "$state")" "$(field "$cwd")" "$(field "$title")"
      done
    done
    ;;
  worktree-list)
    name=$(repo_name "$1") || exit 1
    sessions=$("$rex_cli" ls --json) || exit 1
    # TSV path, branch: the branch is last, because a detached worktree has none.
    worktrees=$(git -C "$1" worktree list --porcelain | awk '
      function flush() { if (path != "" && !prunable) print path "\t" branch; path = "" }
      /^worktree / { flush(); path = substr($0, 10); branch = ""; prunable = 0 }
      /^branch / { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
      /^prunable/ { prunable = 1 }
      END { flush() }') || exit 1
    live=$(jq -r '.sessions[].session_id' <<<"$sessions") || exit 1
    # The first worktree is the main checkout. It is in the repo session, with the label <name>.
    main=1
    while IFS=$'\t' read -r path branch; do
      [[ -n $path ]] || continue
      if [[ -n $main ]]; then label=$name; else label=$name/$branch; fi
      main=""
      # The last live session that open_session made for the path, else a session with the label.
      session=$(LIVE=$live WORKTREE=$path awk -F'\t' '
        BEGIN {
          count = split(ENVIRON["LIVE"], ids, "\n")
          for (i = 1; i <= count; i++) alive[ids[i]] = 1
        }
        $2 == ENVIRON["WORKTREE"] && ($1 in alive) { session = $1 }
        END { print session }' "$worktree_sessions" 2>/dev/null)
      [[ -n $session ]] || session=$(jq -r --arg label "$label" \
        'first(.sessions[] | select(.label == $label) | .session_id) // empty' <<<"$sessions")
      printf '%s\t%s\t%s\n' "$(field "$branch")" "$(field "$path")" "$session"
    done <<<"$worktrees"
    ;;
  worktree-open)
    name=$(repo_name "$1") || exit 1
    branch=$(git -C "$2" branch --show-current) || exit 1
    open_session "$name" "$2" "$branch"
    ;;
  worktree-create)
    name=$(repo_name "$1") || exit 1
    # The worktree folder of herdr: both multiplexers find the same worktrees.
    path=${MUX_WORKTREE_ROOT:-$HOME/.herdr/worktrees}/$name/$2
    # With no local branch, the worktree gets a new branch from HEAD, as in herdr.
    if git -C "$1" show-ref --verify --quiet "refs/heads/$2"; then
      add=("$path" "$2")
    else
      add=(-b "$2" "$path")
    fi
    out=$(git -C "$1" worktree add "${add[@]}" 2>&1) || die "git worktree add failed: $out"
    opened=$(open_session "$name" "$path" "$2") || exit 1
    printf '%s\t%s\n' "$(field "$path")" "$opened"
    ;;
  notify)
    # OSC 9 has one text: "<title>: <body>". Control characters would end the sequence.
    text="$1: $2"
    printf '\033]9;%s\a' "${text//[[:cntrl:]]/ }" >/dev/tty || exit 1
    ;;
  *) die "unknown operation: $operation" ;;
esac
