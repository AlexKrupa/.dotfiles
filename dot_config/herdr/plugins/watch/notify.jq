# The notification of one group of event log lines of the watch daemon `watchd`.
#
#   in:  an array of log lines: the events of one MR in one round, one `stopped` line, or an
#        `opened` event with its `route` line
#   $notify_opened: the router actions that give a notification for an opened event
#   out: {title, body, sound}, or nothing
#
# Pure: watch.sh does the reads and the herdr calls.

def capital: (.[0:1] | ascii_upcase) + .[1:];
def lower: (.[0:1] | ascii_downcase) + .[1:];

# "@<actor> <text>", or the text with a capital letter if the actor is empty.
def by($actor; $text): if $actor == "" then $text | capital else "@\($actor) \($text)" end;

def failed_jobs:
  if (.jobs // []) == [] then "Pipeline failed" else "Pipeline failed: \(.jobs | join(", "))" end;

# [long text, short text for a list] of one event.
def texts:
  (.actor // "") as $a
  | if .kind == "todo" then
      (if .detail == "review_requested" then by($a; "requested your review")
       elif .detail | IN("mentioned", "directly_addressed") then by($a; "mentioned you")
       elif .detail == "approval_required" then by($a; "requested your approval")
       elif $a == "" then .detail | gsub("_"; " ") | capital
       else "@\($a): \(.detail | gsub("_"; " "))" end) as $t | [$t, $t]
    elif .kind | IN("note", "comment") then
      [by($a; "commented: \"\(.detail)\""), by($a; "commented")]
    elif .kind == "reaction" then by($a; "reacted \(.detail)") | [., .]
    elif .kind == "default-failed" or (.kind == "pipeline" and has("jobs")) then
      [failed_jobs, "pipeline failed"]
    elif .kind == "pipeline" then ["Pipeline passed", "pipeline passed"]
    elif .kind == "approved" then by($a; "approved") | [., .]
    elif .kind == "unapproved" then by($a; "removed the approval") | [., .]
    elif .kind == "conflict" then ["Merge conflict", "merge conflict"]
    elif .kind == "mergeable" then ["Ready to merge", "ready to merge"]
    elif .kind | IN("merged", "closed") then .kind | [capital, .]
    elif .kind | IN("draft", "ready") then by($a; "marked it as \(.kind)") | [., .]
    elif .kind | IN("title", "description", "labels") then by($a; "changed the \(.kind)") | [., .]
    elif .kind == "pushed" then ["New commits", "new commits"]
    elif .kind == "resolved" then by($a; "resolved your thread") | [., .]
    elif .kind == "pull-blocked" then ["Pull blocked: \(.detail)", "pull blocked"]
    else by($a; .detail) | [., (. | lower)] end;

def clean: gsub("'"; " ");

def opened_body($action; $actor):
  if $action == "bump" then "New dependency bump. Bump agent started."
  elif $action == "review" then "New MR. Review agent started."
  else "New MR from @\($actor)" end;

if .[0].type == "stopped" then
  {title: (.[0].title // "Hub"), body: "Watch stopped: \(.[0].error)", sound: "request"}
elif any(.[]; .type == "route") then
  (map(select(.type == "event"))[0]) as $opened | (map(select(.type == "route"))[0]) as $route
  | select($route.action | IN($notify_opened[]))
  | {title: ($opened.event.title // $opened.event.branch),
     body: opened_body($route.action; $opened.event.actor), sound: $opened.sound}
else
  map(select((.event.kind | IN("unaddressed", "own-comment") | not) and (.event.own != true)))
  | select(length > 0)
  | {title: (.[0].event.title // .[0].event.branch),
     body: (if length == 1 then (.[0].event | texts[0])
       else map(.event | texts[1]) | join(", ") end),
     sound: (if any(.[]; .sound == "request") then "request" else "none" end)}
end
| .title |= clean | .body |= clean
