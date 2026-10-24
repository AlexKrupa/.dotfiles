# The Markdown report of `watch.sh report`.
#
#   in:  {mode, time: "HH:MM", mrs: [<iid>], rows: [<row>], links: [{title, iid, url}]}
#        row: {n, section: "Needs you"|"Agent"|"Info", iid, title, url, event, what, result,
#              since}. what is the text of a model row, else the sentence of the event comes
#              from event. since is the epoch time of an item from an earlier delivery, or null.
#   out: the report text
#
# Pure: watch.sh reads and writes the state.

def capital: (.[0:1] | ascii_upcase) + .[1:];

# "@<actor> <text>", or the text with a capital letter if the actor is empty.
def by($actor; $text): if $actor == "" then $text | capital else "@\($actor) \($text)" end;

def sentence:
  (.actor // "") as $a
  | if .kind == "todo" then
      if .detail == "review_requested" then by($a; "requested your review")
      elif .detail | IN("mentioned", "directly_addressed") then by($a; "mentioned you")
      elif .detail == "approval_required" then by($a; "requested your approval")
      elif $a == "" then .detail | gsub("_"; " ") | capital
      else "@\($a): \(.detail | gsub("_"; " "))" end
    elif .kind | IN("note", "comment") then by($a; "commented: \"\(.detail)\"")
    elif .kind == "reaction" then by($a; "reacted \(.detail)")
    elif .kind == "opened" then by($a; "opened a dependency bump")
    elif .kind == "default-failed" or (.kind == "pipeline" and has("jobs")) then
      if (.jobs // []) == [] then "Pipeline failed"
      else "Pipeline failed: \(.jobs | join(", "))" end
    elif .kind == "pipeline" then "Pipeline passed"
    elif .kind == "approved" then by($a; "approved")
    elif .kind == "unapproved" then by($a; "removed the approval")
    elif .kind == "conflict" then "Merge conflict"
    elif .kind == "mergeable" then "Ready to merge"
    elif .kind | IN("merged", "closed") then .kind | capital
    elif .kind | IN("draft", "ready") then by($a; "marked it as \(.kind)")
    elif .kind | IN("title", "description", "labels") then by($a; "changed the \(.kind)")
    elif .kind == "pushed" then "New commits"
    elif .kind == "resolved" then by($a; "resolved your thread")
    else by($a; .detail) end;

def cell:
  tostring | gsub("[\r\n]+"; " ") | (if length > 200 then .[0:197] + "..." else . end)
  | gsub("\\|"; "\\|");

def what:
  (if .since then "Since \(.since | strflocaltime("%H:%M")): " else "" end)
  + (.what // (.event | sentence));

def pad($width): if $width > length then . + (" " * ($width - length)) else . end;

# The lines of an aligned Markdown table. A column is 3 characters at least.
def table($header; $rows):
  ([$header] + $rows) as $all
  | [range($header | length) as $i | [3, ($all[][$i] | length)] | max] as $widths
  | ($all | map("| "
      + ([to_entries[] | .key as $column | .value | pad($widths[$column])] | join(" | ")) + " |"))
  | [.[0], ("| " + ([$widths[] | "-" * .] | join(" | ")) + " |")] + .[1:];

def link: if .iid then "\(.title) (!\(.iid)) \(.url)" else "\(.title) \(.url)" end;

if .rows == [] then .time
else
  [.time, "",
   table(["#", "Section", "MR", "What happened", "Proposal or result"];
     [.rows[] | [(.n | tostring), .section, (.title // "" | cell), (what | cell),
       (.result // "" | cell)]])[],
   "", (.links[] | link)]
  | join("\n")
end
