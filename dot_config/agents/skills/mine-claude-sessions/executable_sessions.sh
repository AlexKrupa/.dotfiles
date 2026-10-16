#!/usr/bin/env bash
# Usage:
#   sessions.sh extract [--limit N] [--since YYYY-MM-DD] [--exclude SESSION_ID] [--all]
#   sessions.sh save-state
#
# extract: finds the Claude Code transcripts of the current repo (all worktrees, normal and sandbox
# config dirs) and writes correction candidates to <mined dir>/.candidates.jsonl, one JSON per line:
#   {"session","ts","kind":"message|interrupt|rejected","text","before"}
# "before" is the last assistant action before the event (for "rejected": the rejected tool call).
# It prints the paths and the counts. Without --all, it reads only the lines that
# are newer than the state file. It writes the new state to a pending file.
# save-state: merges the pending file into the state file and deletes the candidates file. Run it
# after the findings file is saved.
set -euo pipefail

limit=50
since=""
exclude=""
all=0

repo_slug="$("$HOME/.config/agents/bin/repo-slug.sh")"
if [ "$repo_slug" = "_no-repo" ]; then
  echo "sessions.sh: not in a git repo" >&2
  exit 1
fi
dir="$HOME/.ai/$repo_slug/mined"
state="$dir/state-sessions.tsv"
pending="$dir/.state-sessions.pending.tsv"
candidates_file="$dir/.candidates.jsonl"

cmd="${1:?usage: sessions.sh extract|save-state}"
shift

if [ "$cmd" = "save-state" ]; then
  [ -f "$pending" ] || { echo "sessions.sh: no pending state" >&2; exit 1; }
  touch "$state"
  # Keep the newest timestamp for each session id.
  sort -t $'\t' -k1,1 -k2,2r "$state" "$pending" | awk -F '\t' '!seen[$1]++' > "$state.tmp"
  mv "$state.tmp" "$state"
  rm -f "$pending" "$candidates_file"
  echo "$state"
  exit 0
fi

[ "$cmd" = "extract" ] || { echo "sessions.sh: unknown command: $cmd" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --limit) limit="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;;
    --exclude) exclude="$2"; shift 2 ;;
    --all) all=1; shift ;;
    *) echo "sessions.sh: unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$dir"
touch "$state"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
iso_to_epoch() { jq -rn --arg t "$1" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601'; }

since_epoch=0
if [ -n "$since" ]; then
  since_epoch="$(iso_to_epoch "${since}T00:00:00Z")"
fi

# Claude Code names a project dir after the session cwd, with each non-alphanumeric char as "-".
encode() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

worktrees="$(git worktree list --porcelain | sed -n 's/^worktree //p')"
bases=("$HOME/.claude/projects" "$HOME/.claude-sandbox/config/projects")

# Print "<mtime>\t<file>" for each session of a worktree or of its subdirs.
candidates() {
  local base wt enc d f cwd
  for base in "${bases[@]}"; do
    [ -d "$base" ] || continue
    while IFS= read -r wt; do
      enc="$(encode "$wt")"
      for d in "$base/$enc" "$base/$enc"-*; do
        [ -d "$d" ] || continue
        for f in "$d"/*.jsonl; do
          [ -f "$f" ] || continue
          # The dir name prefix also matches sibling repos (repo vs repo2). The cwd decides.
          cwd="$(jq -r 'select(.cwd) | .cwd' "$f" 2>/dev/null | head -1)"
          case "$cwd" in
            "$wt" | "$wt"/*) printf '%s\t%s\n' "$(mtime "$f")" "$f" ;;
          esac
        done
      done
    done <<< "$worktrees"
  done
}

# Last mined timestamp of a session, or empty.
state_ts() { awk -F '\t' -v id="$1" '$1 == id { print $2 }' "$state"; }

read_filter='
def short($n): gsub("\\s+"; " ") | if length > $n then .[0:$n] + "..." else . end;
def text_of: if type == "array" then map(.text? // "") | join("") else (. // "" | tostring) end;
def action: [.message.content[]?
  | if .type == "text" then .text
    elif .type == "tool_use" then "\(.name): \(.input | tostring)"
    else empty end] | join(" | ") | short(300);
def noise: test("^\\s*<(command-|local-command|bash-|task-notification|system-reminder)");
reduce (inputs | select(.isSidechain != true)) as $r (
  {before: "", tools: {}, out: [], last: ""};
  .last = ($r.timestamp // .last)
  | if $r.type == "assistant" and ($r.message.content | type) == "array" then
      .before = ($r | action)
      | .tools += ([$r.message.content[] | select(.type == "tool_use")
          | {(.id): "\(.name): \(.input | tostring | short(300))"}] | add // {})
    elif $r.type == "user" and ($r.isMeta | not) and (($r.timestamp // "") > $after) then
      . as $s
      | ($r.message.content | if type == "string" then [{type: "text", text: .}] else . end) as $blocks
      | .out += [$blocks[]
          | if .type == "text" and (.text | startswith("[Request interrupted by user")) then
              {kind: "interrupt", text: "", before: $s.before}
            elif .type == "text" and (.text | noise | not) and (.text | length) <= 400 then
              {kind: "message", text: (.text | short(400)), before: ($s.before | short(200))}
            elif .type == "tool_result" and .is_error == true
                and (.content | text_of | test("want to proceed with this tool use")) then
              {kind: "rejected",
               text: (.content | text_of | (capture("the user said:\\s*(?<r>[\\s\\S]*)").r // "") | short(400)),
               before: ($s.tools[.tool_use_id] // $s.before)}
            else empty end
          | {session: $sid, ts: $r.timestamp} + .]
    else . end)
| (.out[] | tostring), "#last\t\(.last)"
'

: > "$pending"
: > "$candidates_file"
total=0
read_count=0
skipped=0
while IFS=$'\t' read -r m f; do
  [ -n "$f" ] || continue
  sid="$(basename "$f" .jsonl)"
  [ "$sid" = "$exclude" ] && continue
  [ "$m" -ge "$since_epoch" ] || continue
  after=""
  if [ "$all" -eq 0 ]; then
    after="$(state_ts "$sid")"
    # No new lines since the last run.
    if [ -n "$after" ] && [ "$m" -le "$(iso_to_epoch "$after")" ]; then continue; fi
  fi
  total=$((total + 1))
  if [ "$read_count" -ge "$limit" ]; then skipped=$((skipped + 1)); continue; fi
  read_count=$((read_count + 1))
  jq -nr --arg after "$after" --arg sid "$sid" "$read_filter" < "$f" 2>/dev/null \
    | while IFS= read -r line; do
        case "$line" in
          "#last"*) printf '%s\t%s\n' "$sid" "${line#*$'\t'}" >> "$pending" ;;
          *) printf '%s\n' "$line" >> "$candidates_file" ;;
        esac
      done
done < <(candidates | sort -t $'\t' -k1,1nr | awk -F '\t' '!seen[$2]++')

echo "mined dir: $dir"
echo "candidates: $candidates_file ($(wc -l < "$candidates_file" | tr -d ' ') lines)"
echo "sessions read: $read_count, not read (over the limit): $skipped, total new: $total"
