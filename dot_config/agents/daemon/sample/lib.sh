# shellcheck shell=bash
# The paths and the helpers of `sample` and its step files. Each step runs in a new bash with this
# file. A role is `hub`, `branch`, `stack`, `review`, or `own`: one check target of the test daemon.

sample_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SAMPLE_ROOT=${SAMPLE_ROOT:-$HOME/.local/share/watchd-sample}
export SAMPLE_STATE=${SAMPLE_STATE:-$HOME/.local/state/watchd-sample}
repo=$SAMPLE_ROOT/repo
origin=$SAMPLE_ROOT/origin.git
watchd=$SAMPLE_ROOT/bin/watchd
engine=$SAMPLE_STATE/engine
review_iid=7

# The global git configuration can sign commits with a key that asks for a password, and can start
# an fsmonitor daemon that fails when a step deletes its repo.
export GIT_CONFIG_COUNT=4
export GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=Sample
export GIT_CONFIG_KEY_2=user.email GIT_CONFIG_VALUE_2=sample@example.com
export GIT_CONFIG_KEY_3=core.fsmonitor GIT_CONFIG_VALUE_3=false

hash12() { printf %s "$1" | shasum | cut -c1-12; }

# The keys of src/key.rs. The worktree of a role is $SAMPLE_ROOT/repo-<role>.
key_of() { # key_of <role>
  local slug
  slug=$(cd "$repo" && "$HOME/.config/agents/bin/repo-slug.sh") || return 1
  case $1 in
    hub) echo "$slug" ;;
    own) echo "$slug-own" ;;
    branch | stack) echo "$slug-$(hash12 "$SAMPLE_ROOT/repo-$1")" ;;
    review) echo "$slug-$(hash12 "$SAMPLE_ROOT/repo-review")-review-$review_iid" ;;
    *) echo "unknown role: $1" >&2; return 1 ;;
  esac
}

# The files of the fake engine (src/engine/fake.rs).
event() { # event <role> <json>: an event for the next check of the role
  local key
  key=$(key_of "$1") && jq -c . <<<"$2" >>"$engine/$key.jsonl"
}

engine_state() { # engine_state <role> <json>: the engine state, with the needs of the sidebar
  local key
  key=$(key_of "$1") && jq . <<<"$2" >"$engine/$key.state"
}

check_fail() { # check_fail <role> <count> <text>: the next <count> checks fail with the text
  local key
  key=$(key_of "$1") || return 1
  seq "$2" | sed 's/.*/1/' >"$engine/$key.exit"
  printf '%s\n' "$3" >"$engine/$key.err"
}

job() { # job <id> <json>...: one job status for each status read, the last one stays
  local id=$1
  shift
  printf '%s\n' "$@" | jq -c . >"$engine/job-$id.json"
}

retry() { # retry <id> <json>: the new job of a retry
  jq -c . <<<"$2" >"$engine/retry-$1.json"
}

spice() { # spice <worktree> <jsonl>: the output of the fake git-spice in the worktree
  printf '%s\n' "$2" >"$SAMPLE_STATE/spice/spice-$(hash12 "$1").jsonl"
}

commit() { # commit <folder> <file> <text>: writes the text to the file and commits it
  printf '%s\n' "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -q -m "$3"
}

settle() { # waits until the daemon takes all event files of the fake engine
  local left file
  for _ in $(seq 30); do
    left=$(for file in "$engine"/*.jsonl; do
      if [ -s "$file" ]; then basename "$file" .jsonl; fi
    done)
    [ -n "$left" ] || return 0
    sleep 0.5
  done
  echo "events not taken: $(tr '\n' ' ' <<<"$left" | sed 's/ $//')" >&2
  return 1
}

# A fake agent session is the agent loop in the root pane of the worktree workspace, or with
# SAMPLE_NO_HERDR=1 a background process. The files $SAMPLE_STATE/agents/<role>.<name> keep the
# herdr workspace and pane, and the PID of the loop.
agents=$SAMPLE_STATE/agents

agent_open() { # agent_open <role>: opens the worktree workspace in herdr
  local branch opened workspace pane
  if [ "${SAMPLE_NO_HERDR:-}" = 1 ] || [ -s "$agents/$1.pane" ]; then return 0; fi
  branch=$(git -C "$SAMPLE_ROOT/repo-$1" symbolic-ref --short HEAD) || return 1
  opened=$("$HOME/.config/agents/skills/work/herdr-worktree.sh" "$branch" --repo "$repo") || return 1
  workspace=$(jq -r .workspace_id <<<"$opened")
  pane=$(jq -r .root_pane_id <<<"$opened")
  # A workspace that was open gives no root pane.
  if [ -z "$pane" ]; then
    pane=$(herdr pane list --workspace "$workspace" | jq -r '.result.panes[0].pane_id // empty')
  fi
  [ -n "$pane" ] || { echo "no pane in the herdr workspace $workspace" >&2; return 1; }
  echo "$workspace" >"$agents/$1.workspace"
  echo "$pane" >"$agents/$1.pane"
}

agent_run() { # agent_run <role> [<watch argument>...]: starts the loop, waits for its agent record
  local role=$1 key pid
  shift
  key=$(key_of "$role") || return 1
  rm -f "$agents/$role.pid"
  if [ "${SAMPLE_NO_HERDR:-}" = 1 ]; then
    nohup "$sample_dir/agent-loop" "$SAMPLE_ROOT/repo-$role" "$agents/$role.pid" "$@" \
      >>"$agents/$role.log" 2>&1 </dev/null &
  else
    herdr pane run "$(cat "$agents/$role.pane")" "$(printf '%q ' env SAMPLE_ROOT="$SAMPLE_ROOT" \
      SAMPLE_STATE="$SAMPLE_STATE" "$sample_dir/agent-loop" "$SAMPLE_ROOT/repo-$role" \
      "$agents/$role.pid" "$@")" >/dev/null
  fi
  for _ in $(seq 75); do
    pid=$(cat "$agents/$role.pid" 2>/dev/null) || pid=
    if [ -n "$pid" ] && [ "$(cd "$repo" && "$watchd" debug state \
      | jq -r --arg key "$key" '.subs[$key].session_pid // empty')" = "$pid" ]; then
      return 0
    fi
    sleep 0.2
  done
  echo "the agent loop of $role has no agent record $key" >&2
  return 1
}

agent_stop() { # agent_stop <role>: ends the agent session, the workspace stays
  local pid
  pid=$(cat "$agents/$1.pid" 2>/dev/null) || return 0
  pkill -P "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  rm -f "$agents/$1.pid"
}

agent_close() { # agent_close <role>: ends the agent session and closes the workspace
  agent_stop "$1"
  if [ -s "$agents/$1.workspace" ]; then
    herdr workspace close "$(cat "$agents/$1.workspace")" >/dev/null || return 1
  fi
  rm -f "$agents/$1.workspace" "$agents/$1.pane"
}

# A review agent watches its MR in review mode.
agent() { # agent open|start|stop|close <role>
  mkdir -p "$agents"
  case $1 in
    open) agent_open "$2" ;;
    start)
      agent_open "$2" || return 1
      case $2 in
        review) agent_run "$2" --review --mr "$review_iid" ;;
        *) agent_run "$2" ;;
      esac
      ;;
    stop) agent_stop "$2" ;;
    close) agent_close "$2" ;;
    *) echo "unknown agent action: $1" >&2; return 1 ;;
  esac
}

close_agents() { # ends all agent sessions and closes their workspaces
  local file
  for file in "$agents"/*.pid "$agents"/*.workspace; do
    [ -e "$file" ] || continue
    agent_close "$(basename "${file%.*}")"
  done
}
