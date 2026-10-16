#!/usr/bin/env bash
# Checks prs.sh against the fake glab and the review history of evals/fixtures. No LLM.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/prs.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export REAL_HOME="$HOME" HOME="$tmp/home"
mkdir -p "$HOME/.config"
ln -s "$REAL_HOME/.config/agents" "$HOME/.config/agents"
export PATH="$here/evals/shims:$PATH"

repo="$tmp/notes-app"
"$here/evals/fixtures/review-history.sh" "$repo"
cd "$repo"
mined="$HOME/.ai/$("$HOME/.config/agents/bin/repo-slug.sh")/mined"
cands="$mined/.candidates-prs.jsonl"

out=$("$script" extract)
check "summary" "MRs read: 8, more MRs over the limit: no" "$(tail -1 <<<"$out")"
check "drops system notes, bots, and MR author threads" 10 "$(wc -l < "$cands" | tr -d ' ')"
check "changed per thread" \
  "101 unknown|101 yes|102 yes|103 unknown|103 yes|104 yes|105 no|106 unknown|107 no|108 yes" \
  "$(jq -r '"\(.mr) \(.changed)"' "$cands" | sort | paste -sd '|' -)"
check "mine marks the MRs of the current user" "101 103 108" \
  "$(jq -r 'select(.mine) | .mr' "$cands" | sort -u | paste -sd ' ' -)"
check "replies of the author stay" "Good point, moved it to the screen." \
  "$(jq -r 'select(.mr == 102) | .replies[0].body' "$cands")"
check "multiline comment keeps the start line" 17 "$(jq -r 'select(.mr == 108) | .line' "$cands")"

"$script" save-state >/dev/null
check "state has the read MRs" 8 "$(wc -l < "$mined/state-prs.tsv" | tr -d ' ')"
out=$("$script" extract)
check "second run skips mined MRs" "MRs read: 0, more MRs over the limit: no" "$(tail -1 <<<"$out")"

out=$("$script" extract --all --limit 3)
check "limit" "MRs read: 3, more MRs over the limit: yes" "$(tail -1 <<<"$out")"
check "limit reads the newest MRs" "106 107 108" \
  "$(jq -r .mr "$cands" | sort -u | paste -sd ' ' -)"

out=$("$script" extract --all --since 2026-09-20)
check "since" "MRs read: 4, more MRs over the limit: no" "$(tail -1 <<<"$out")"

exit $fail
