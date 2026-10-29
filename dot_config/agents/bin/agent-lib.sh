# Sourced. Finds the agent integration of a herdr pane. Writes nothing.
# - agent_kind <pane>: prints the herdr agent kind of the agent in <pane>. If the pane has no
#   agent, prints an error and returns 1.
# - agent_adapter <kind>: prints the path of the <integrations>/*/agent.sh whose `kind` output is
#   <kind>. <integrations> is $AGENT_INTEGRATIONS, else integrations/ of the core. If no adapter
#   matches, prints an error and returns 1.
# Errors go to stderr, with the name of the caller script.

agent_lib_error() {
  local caller=${0##*/}
  echo "${caller%.sh}: $1" >&2
}

agent_kind() {
  local kind
  kind=$(herdr agent get "$1" | jq -r '.result.agent.agent // empty') || return 1
  if [[ -n $kind ]]; then
    printf '%s\n' "$kind"
  else
    agent_lib_error "no agent in pane $1"
    return 1
  fi
}

agent_adapter() {
  local core integrations adapter
  core=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  integrations=${AGENT_INTEGRATIONS:-$core/integrations}
  for adapter in "$integrations"/*/agent.sh; do
    if [[ -x $adapter && $("$adapter" kind) == "$1" ]]; then
      printf '%s\n' "$adapter"
      return 0
    fi
  done
  agent_lib_error "no agent integration for herdr kind '$1'"
  return 1
}
