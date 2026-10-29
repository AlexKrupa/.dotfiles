#!/usr/bin/env bash
# Usage: watch-stack.sh <repo-dir>
# notes-app.sh with a bare `origin`, git-spice on trunk `main`, and a pushed stack of 2 branches
# with MRs: `tags-model` (!11, Add Tag model, with an unused wildcard import in Tag.kt) and
# `tags-in-list` (!12). The current branch is `tags-model`. <repo>.host/ has the fake host
# commands and the host file host.md that names them. The scenario fixtures add the job logs.
# Prints host=<repo>.host, and intro= with the prompt intro that names the host file.
"$(dirname "$0")/../../../draft-ticket/evals/fixtures/notes-app.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
allow_commits
add_origin
git-spice --no-prompt repo init --trunk main --remote origin >/dev/null 2>&1

git switch -q -c tags-model
put app/src/main/kotlin/notes/Tag.kt <<'EOF'
package notes

import java.util.*

data class Tag(val name: String, val color: Long)
EOF
commit "Add Tag model"
git-spice --no-prompt branch track --base main >/dev/null 2>&1

git switch -q -c tags-in-list
put app/src/main/kotlin/notes/list/NoteListItem.kt <<'EOF'
package notes.list

@Composable
fun NoteListItem(note: Note, tags: List<Tag>) { Row { Text(note.title); tags.forEach { TagChip(it) } } }
EOF
commit "Show tags in the note list"
git-spice --no-prompt branch track --base tags-model >/dev/null 2>&1
git push -q origin tags-model tags-in-list
git switch -q tags-model

mr=https://gitlab.example.com/notes/app/-/merge_requests
cat >"$PWD.changes.json" <<EOF
{"tags-model": {"id": "!11", "url": "$mr/11"}, "tags-in-list": {"id": "!12", "url": "$mr/12"}}
EOF

host="$PWD.host"
mkdir -p "$host/logs"
put "$host/watch" <<'EOF'
#!/bin/sh
# Fake watch command. It stops at once as "replaced", so the session does not wait for it.
sleep 2
echo "watchd: replaced by a new watch" >&2
exit 3
EOF
put "$host/job-log" <<'EOF'
#!/bin/sh
# Usage: job-log <pipeline-id> - prints the logs of the failed jobs of the pipeline.
cat "$(dirname "$0")/logs/$1.log" 2>/dev/null || echo "no failed jobs in pipeline $1"
EOF
put "$host/retry" <<'EOF'
#!/bin/sh
# Usage: retry <job-id>
echo "$1" >>"$(dirname "$0")/retried"
echo "Retried job $1. New job: $(($1 + 1000))"
EOF
chmod +x "$host/watch" "$host/job-log" "$host/retry"
put "$host/host.md" <<EOF
# Watch: test host

| Function                              | Command                                             |
| ------------------------------------- | --------------------------------------------------- |
| Watch command, author mode            | \`$host/watch --interval 120 --mr <iid>\`, with one \`--mr\` for each MR |
| Restart command                       | The same watch command                              |
| Logs of the failed jobs of a pipeline | \`$host/job-log <pipeline-id>\`                     |
| Retry a job                           | \`$host/retry <job-id>\`                            |

The id of an MR is \`!<iid>\`.
EOF
echo "host=$host"
echo "intro=Use the draft-pr skill. The wrapper published the MRs of this stack. This is the" \
  "Watch step. Use the host file \`$host/host.md\`."
