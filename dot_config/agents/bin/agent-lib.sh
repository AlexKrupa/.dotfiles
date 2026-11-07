# shellcheck shell=bash
# Sourced. Finds the agent integration of a multiplexer pane, or the only integration. Writes
# nothing.
# - agent_kind <pane>: prints the agent kind of the agent in <pane>. If the pane has no
#   agent, prints an error and returns 1.
# - agent_adapter <kind>: prints the path of the <integrations>/*/agent.sh whose `kind` output is
#   <kind>. <integrations> is $AGENT_INTEGRATIONS, else integrations/ of the core. If no adapter
#   matches, prints an error and returns 1.
# - agent_default_kind: prints the kind of the only <integrations>/*/agent.sh. With 0 or 2 or more
#   adapters, prints an error that asks for --kind and returns 1.
# Errors go to stderr, with the name of the caller script.

agent_lib_error() {
  local caller=${0##*/}
  echo "${caller%.sh}: $1" >&2
}

agent_kind() {
  local kind
  kind=$("$(dirname "${BASH_SOURCE[0]}")/mux.sh" agent-kind "$1") || return 1
  if [[ -n $kind ]]; then
    printf '%s\n' "$kind"
  else
    agent_lib_error "no agent in pane $1"
    return 1
  fi
}

agent_integrations() {
  local core
  core=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  printf '%s\n' "${AGENT_INTEGRATIONS:-$core/integrations}"
}

agent_adapter() {
  local integrations adapter
  integrations=$(agent_integrations)
  for adapter in "$integrations"/*/agent.sh; do
    if [[ -x $adapter && $("$adapter" kind) == "$1" ]]; then
      printf '%s\n' "$adapter"
      return 0
    fi
  done
  agent_lib_error "no agent integration for agent kind '$1'"
  return 1
}

agent_default_kind() {
  local integrations adapter adapters=()
  integrations=$(agent_integrations)
  for adapter in "$integrations"/*/agent.sh; do
    if [[ -x $adapter ]]; then adapters+=("$adapter"); fi
  done
  if ((${#adapters[@]} == 1)); then
    "${adapters[0]}" kind
  else
    agent_lib_error "${#adapters[@]} agent integrations in $integrations: give the kind with --kind"
    return 1
  fi
}
