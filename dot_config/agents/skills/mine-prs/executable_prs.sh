#!/usr/bin/env bash
# Usage:
#   prs.sh extract [--limit N] [--since YYYY-MM-DD] [--all]
#   prs.sh save-state
#
# extract: reads the merged GitLab MRs of the current repo, newest merge first, and writes the
# reviewer threads to <mined dir>/.candidates-prs.jsonl, one JSON per line:
#   {"mr","url","title","mr_author","mine","merged_at","author","path","line","body","replies",
#    "resolved","changed"}
# It drops system notes, bots, and threads that the MR author started. "changed" is "yes" when a
# suggestion was applied or a later push changed the commented lines, "no" when it did not, and
# "unknown" for comments that are not on a line or when the compare fails. Without --all, it skips
# the MRs in the state file. It writes the read MRs to a pending file.
# save-state: merges the pending file into the state file and deletes the candidates file. Run it
# after the findings file is saved.
# Exit codes: 0 ok, 1 usage/other, 4 missing dep / auth, 5 network
set -euo pipefail

limit=50
since=""
all=0

die() { echo "prs.sh: $1" >&2; exit "${2:-1}"; }

repo_slug="$("$HOME/.config/agents/bin/repo-slug.sh")"
[ "$repo_slug" != "_no-repo" ] || die "not in a git repo"
dir="$HOME/.ai/$repo_slug/mined"
state="$dir/state-prs.tsv"
pending="$dir/.state-prs.pending.tsv"
candidates_file="$dir/.candidates-prs.jsonl"

cmd="${1:?usage: prs.sh extract|save-state}"
shift

if [ "$cmd" = "save-state" ]; then
  [ -f "$pending" ] || die "no pending state"
  touch "$state"
  sort -u "$state" "$pending" > "$state.tmp"
  mv "$state.tmp" "$state"
  rm -f "$pending" "$candidates_file"
  echo "$state"
  exit 0
fi

[ "$cmd" = "extract" ] || die "unknown command: $cmd"

while [ $# -gt 0 ]; do
  case "$1" in
    --limit) limit="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;;
    --all) all=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v glab >/dev/null || die "glab not installed" 4
command -v jq >/dev/null || die "jq not installed" 4
glab auth status >/dev/null 2>&1 || die "glab not authenticated, run: glab auth login" 4
me="$(glab api user | jq -r .username)" || die "glab api user failed" 5

mkdir -p "$dir"
touch "$state"
: > "$candidates_file"
: > "$pending"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One object for each thread that a person other than the MR author started. The bash loop
# below replaces "changed" when it needs the compare API.
threads_filter='
def bot: .bot == true or (.username | test("^(project|group)_[0-9]+_bot|bot$|\\[bot\\]$"; "i"));
def cut: if length > 1000 then .[0:1000] + "..." else . end;
.[]
| [.notes[] | select(.system | not)] as $notes
| select($notes | length > 0)
| select(($notes[0].author | bot | not) and $notes[0].author.username != $mr.author)
| $notes[0].position as $p
| {
    mr: $mr.iid, url: $mr.url, title: $mr.title, mr_author: $mr.author,
    mine: ($mr.author == $me), merged_at: $mr.merged_at,
    author: $notes[0].author.username,
    path: ($p.new_path // null),
    line: ($p.line_range.start.new_line // $p.new_line // null),
    end_line: ($p.line_range.end.new_line // $p.new_line // null),
    head_sha: ($p.head_sha // null),
    body: ($notes[0].body | cut),
    replies: [$notes[1:][] | select(.author | bot | not) | {author: .author.username, body: (.body | cut)}],
    resolved: (if $notes[0].resolvable then ($notes[0].resolved == true) else null end),
    changed: (if any($notes[]; any(.suggestions[]?; .applied == true)) then "yes"
              elif $p.new_path == null or ($p.line_range.start.new_line // $p.new_line) == null then "unknown"
              elif $p.head_sha == $mr.sha then "no"
              else "compare" end)
  }'

# changed_lines <iid> <from_sha> <to_sha> <path> <start> <end>: prints yes, no, or unknown.
changed_lines() {
  local cmp="$tmp/compare-$1-$2.json"
  if [ ! -f "$cmp" ]; then
    glab api "projects/:fullpath/repository/compare?from=$2&to=$3&straight=true" > "$cmp" 2>/dev/null \
      || echo '{"compare_timeout":true}' > "$cmp"
  fi
  jq -r --arg path "$4" --argjson s "$5" --argjson e "$6" '
    if .compare_timeout then "unknown" else
      [.diffs[]? | select(.old_path == $path)] as $d
      | if ($d | length) == 0 then "no"
        elif $d[0].deleted_file then "yes"
        else
          [$d[0].diff | scan("@@ -([0-9]+)(?:,([0-9]+))?")
           | (.[0] | tonumber) as $a | ((.[1] // "1") | tonumber) as $n
           # A hunk with 0 old lines inserts after line $a.
           | if $n == 0 then ($a >= $s - 1 and $a <= $e) else ($a <= $e and $a + $n - 1 >= $s) end]
          | if any then "yes" else "no" end
        end
    end' "$cmp"
}

read_count=0
over_limit=0
page=1
while :; do
  mrs="$(glab api "projects/:fullpath/merge_requests?state=merged&order_by=merged_at&sort=desc&per_page=100&page=$page")" \
    || die "glab api merge_requests failed (order_by=merged_at needs GitLab 17.2 or later)" 5
  [ "$(jq length <<<"$mrs")" -gt 0 ] || break
  stop=0
  while IFS= read -r mr; do
    iid="$(jq -r .iid <<<"$mr")"
    merged_at="$(jq -r .merged_at <<<"$mr")"
    if [ -n "$since" ] && [[ "$merged_at" < "$since" ]]; then stop=1; break; fi
    if [ "$all" -eq 0 ] && grep -q "^$iid"$'\t' "$state"; then continue; fi
    if [ "$read_count" -ge "$limit" ]; then over_limit=1; stop=1; break; fi
    read_count=$((read_count + 1))
    printf '%s\t%s\n' "$iid" "$merged_at" >> "$pending"
    sha="$(jq -r .sha <<<"$mr")"
    glab api --paginate "projects/:fullpath/merge_requests/$iid/discussions?per_page=100" \
      | jq -s 'add // []' > "$tmp/discussions.json" || die "glab api discussions failed for !$iid" 5
    jq -c --arg me "$me" --argjson mr "$(jq -c '{iid, url: .web_url, title, author: .author.username, merged_at, sha}' <<<"$mr")" \
      "$threads_filter" "$tmp/discussions.json" \
      | while IFS= read -r t; do
          changed="$(jq -r .changed <<<"$t")"
          if [ "$changed" = "compare" ]; then
            changed="$(changed_lines "$iid" "$(jq -r .head_sha <<<"$t")" "$sha" \
              "$(jq -r .path <<<"$t")" "$(jq -r .line <<<"$t")" "$(jq -r .end_line <<<"$t")")"
          fi
          jq -c --arg c "$changed" '.changed = $c | del(.head_sha, .end_line)' <<<"$t"
        done >> "$candidates_file"
  done < <(jq -c '.[]' <<<"$mrs")
  [ "$stop" -eq 0 ] || break
  page=$((page + 1))
done

threads="$(wc -l < "$candidates_file" | tr -d ' ')"
echo "mined dir: $dir"
echo "candidates: $candidates_file ($threads threads)"
echo "MRs read: $read_count, more MRs over the limit: $([ "$over_limit" -eq 1 ] && echo yes || echo no)"
