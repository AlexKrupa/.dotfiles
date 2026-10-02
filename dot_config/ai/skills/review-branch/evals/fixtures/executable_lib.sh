# Shared setup for review-branch eval fixtures. Source it from a fixture script.
set -euo pipefail

# Global config enables 1Password commit signing, which fails headless.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test Dev" GIT_AUTHOR_EMAIL=dev@example.com
export GIT_COMMITTER_NAME="Test Dev" GIT_COMMITTER_EMAIL=dev@example.com

# init_repo <dir> - creates an empty repo on `main` and cds into it.
init_repo() {
  [ ! -e "$1" ] || { echo "$1 already exists" >&2; exit 1; }
  mkdir -p "$1"
  cd "$1"
  git init -q -b main
}

# add_origin - creates a sibling bare repo as `origin` and pushes `main` to it.
add_origin() {
  local bare="$PWD.origin.git"
  git init -q --bare -b main "$bare"
  git remote add origin "$bare"
  git push -q -u origin main
  git remote set-head origin main >/dev/null
}

# put <path> - writes stdin to <path>.
put() {
  mkdir -p "$(dirname "$1")"
  cat >"$1"
}

commit() {
  git add -A
  git commit -q -m "$1"
}
