#!/usr/bin/env bash
# Usage: install-skills.sh <agent> [android]
# Installs the selected third-party skills for <agent>, a `skills` CLI agent name.
# With no set, installs the global skills. It also removes the global copies of the skills of the
# sets, because a set installs them into a repo.
# With a set, installs the skills of the set into the repo of the current directory. Run it in the
# main checkout. The herdr worktree-links plugin links `.claude/` into the worktrees.
# The skills CLI has no manifest file, so this script is the manifest.
# Re-run it to reinstall on a new machine. Use `skills update` for upstream changes.
# Exit codes: 0 ok, or no `skills` on PATH. 2 no <agent>, an unknown set, or not in a main checkout.
set -euo pipefail

usage() {
  echo "usage: install-skills.sh <agent> [android]" >&2
  exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
agent=$1
set_name=${2:-global}

command -v skills >/dev/null || exit 0

# Calls "$@" <source> <skill>... once for each source of the android set.
android_set() {
  # https://github.com/chrisbanes/skills
  "$@" chrisbanes/skills \
    kotlin-api-design \
    kotlin-concurrency-and-flow \
    kotlin-control-flow \
    compose-animations \
    compose-component-design \
    compose-focus-navigation \
    compose-performance \
    compose-state-and-effects \
    compose-ui-testing-patterns

  # https://github.com/android/skills
  "$@" android/skills \
    android-cli \
    navigation-3 \
    navigation-event \
    r8-analyzer \
    android-intent-security \
    android-permissions-security \
    testing-setup \
    jetpack-compose-performance \
    edge-to-edge \
    anr-audit-and-fix \
    android-profiler

  # https://github.com/gradle/gradle-skills
  "$@" gradle/gradle-skills \
    gradle-best-practices \
    gradle-wrapper-upgrade
}

# Installs <skill>... of <source> with the `skills add` scope flags in `scope`.
install() {
  local source=$1 skill
  shift
  local flags=()
  for skill in "$@"; do
    flags+=(--skill "$skill")
  done
  skills add "$source" "${scope[@]}" --agent "$agent" --yes "${flags[@]}"
}

# Removes the global copies of <skill>... that come from <source>. A skill with the same name from
# a different source stays.
remove_global() {
  local source=$1 skill
  shift
  local flags=()
  for skill in "$@"; do
    if grep -qxF "$source:$skill" <<<"$global_skills"; then
      flags+=(--skill "$skill")
    fi
  done
  [ ${#flags[@]} -gt 0 ] || return 0
  skills remove --global --yes "${flags[@]}"
}

case $set_name in
  global)
    scope=(--global)
    global_skills=$(skills ls --global --json | jq -r '.[] | "\(.source):\(.name)"')
    android_set remove_global

    # https://github.com/mattpocock/skills
    # grill-me only calls grilling.
    install mattpocock/skills grilling grill-me
    ;;
  android)
    git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || {
      echo "install-skills.sh: not in a git repo: $PWD" >&2
      exit 2
    }
    if [ "$git_dir" != "$(git rev-parse --path-format=absolute --git-common-dir)" ]; then
      echo "install-skills.sh: $PWD is a worktree, run in the main checkout" >&2
      exit 2
    fi
    cd "$(git rev-parse --show-toplevel)"

    scope=()
    android_set install

    exclude=$(git rev-parse --git-path info/exclude)
    mkdir -p "$(dirname "$exclude")"
    for path in .claude/skills/ skills-lock.json; do
      grep -qxsF "$path" "$exclude" || echo "$path" >>"$exclude"
    done
    ;;
  *)
    usage
    ;;
esac
