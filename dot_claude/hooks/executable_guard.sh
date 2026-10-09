#!/usr/bin/env bash

set -euo pipefail

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

if printf '%s' "$cmd" | grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'; then
  deny "Blocked: piping a remote download into a shell. Download, inspect, then run."
fi

# Put each command on its own line.
segments=$(printf '%s' "$cmd" | tr ';&|' '\n')
b='[^[:alnum:]_-]'

if grep -E "(^|$b)(gh|glab)$b" <<<"$segments" | grep -E "${b}auth$b" | grep -E "${b}status($b|$)" \
  | grep -Eq "$b(--show-token|-t)($b|$)"; then
  deny "Blocked: printing the auth token. Use \`auth status\` without \`-t\`."
fi

if grep -E "(^|$b)gh$b" <<<"$segments" | grep -Eq "${b}auth${b}+token($b|$)"; then
  deny "Blocked: printing the GitHub token."
fi

if grep -E "(^|$b)git$b" <<<"$segments" | grep -Eq "${b}credential${b}+fill($b|$)"; then
  deny "Blocked: printing a git credential."
fi

if grep -Eq '\.ssh/id_[[:alnum:]_-]+([^[:alnum:]_.-]|$)' <<<"$segments"; then
  deny "Blocked: reading an SSH private key."
fi

# gpg accepts shortened long options, e.g. `--export-secret-k`.
if grep -E "(^|$b)gpg2?$b" <<<"$segments" | grep -Eq "${b}--export-secret"; then
  deny "Blocked: exporting a GPG secret key."
fi

if grep -Eq '\.gnupg/private-keys-v1\.d' <<<"$segments"; then
  deny "Blocked: reading GPG private key files."
fi

if grep -E "(^|$b)security$b" <<<"$segments" | grep -E "${b}find-(generic|internet)-password($b|$)" \
  | grep -Eq "$b-[[:alpha:]]*[wg]"; then
  deny "Blocked: printing a Keychain secret. Omit \`-w\` and \`-g\`."
fi

if grep -E "(^|$b)security$b" <<<"$segments" | grep -E "${b}dump-keychain($b|$)" \
  | grep -Eq "$b-[[:alpha:]]*d"; then
  deny "Blocked: printing all Keychain secrets. Omit \`-d\`."
fi

# rm: allow only targets inside the directory where the session started.
# A target that the hook cannot resolve is blocked.
# Return codes: 1 - outside, 2 - `~` or expansion, 3 - `cd` in command, 4 - no parent dir.
rm_target_ok() {
  local t=$1 parent dir
  [[ $t == *['$`']* || $t == '~'* ]] && return 2
  if [[ $t != /* ]]; then
    # A `cd` in the same command changes the base of relative paths.
    [[ -n $has_cd ]] && return 3
    t=$cwd/$t
  fi
  if [[ $t == *['*?[']* ]]; then
    dir=${t%%['*?[']*}
    dir=${dir%/*}
    dir=$(cd "${dir:-/}" 2>/dev/null && pwd -P) || return 4
    [[ $dir == "$project" || $dir == "$project"/* ]]
    return
  fi
  if [[ $t == */ && -d $t ]]; then
    # A trailing slash makes rm follow a symlink.
    dir=$(cd "$t" 2>/dev/null && pwd -P) || return 4
    [[ $dir == "$project"/* ]]
    return
  fi
  while [[ $t == */ && $t != / ]]; do t=${t%/}; done
  case ${t##*/} in
    . | .. | '') dir=$(cd "${t:-/}" 2>/dev/null && pwd -P) || return 4 ;;
    *)
      # Resolve only the parent: `rm` removes a symlink, not its target.
      parent=${t%/*}
      dir=$(cd "${parent:-/}" 2>/dev/null && pwd -P)/${t##*/} || return 4
      ;;
  esac
  [[ $dir == "$project"/* ]]
}

rm_lines=$(grep -E '^[[:space:]]*(sudo[[:space:]]+)?(command[[:space:]]+)?\\?(/usr)?(/bin/)?rm([[:space:]]|$)' \
  <<<"$segments" || true)
if [[ -n $rm_lines ]]; then
  project=$(cd "${CLAUDE_PROJECT_DIR:-/nonexistent}" 2>/dev/null && pwd -P) \
    || deny "Blocked: rm. The session start directory is not known."
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  cwd=${cwd:-$PWD}
  has_cd=$(grep -Eq '^[[:space:]]*(cd|pushd)([[:space:]]|$)' <<<"$segments" && echo 1 || true)
  while read -r line; do
    read -ra words <<<"$line"
    started='' opts=1
    for w in "${words[@]}"; do
      w=${w//[\'\"]/}
      if [[ -z $started ]]; then
        [[ ${w##*[/\\]} == rm ]] && started=1
        continue
      fi
      if [[ -n $opts && $w == -- ]]; then opts=''; continue; fi
      [[ -n $opts && $w == -* ]] && continue
      rc=0
      rm_target_ok "$w" || rc=$?
      case $rc in
        1) deny "Blocked: rm on \`$w\`. The path is not inside $project." ;;
        2) deny "Blocked: rm on \`$w\`. Use a path without \`~\`, variables, or command substitution." ;;
        3) deny "Blocked: rm on \`$w\`. The command also uses \`cd\`. Use an absolute path." ;;
        4) deny "Blocked: rm on \`$w\`. The parent directory does not exist." ;;
      esac
    done
  done <<<"$rm_lines"
fi

exit 0
