---
name: handoff
description: >-
  Use when the user runs /handoff. It frees the context of this session for the same work in a
  fresh session, or parks the work for later.
argument-hint: "[park] [focus of the next session]"
disable-model-invocation: true
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/handoff.sh *)
---

# handoff

Writes a handoff document, so that a fresh agent can continue the same work. A different task in a
new worktree is `/work split`, not this skill.

Input: the skill arguments are optional free text.

- The word `park`: write the file and stop. This session stays as it is.
- Other text: the focus of the next session. Keep only the context for that focus.
- No text: the next session continues the same work.

## Steps

1. Get the file path. The topic is 2 to 5 English words about the work. If the branch name starts
   with an issue key, that key is the ticket id:

   ```sh
   <skill folder>/handoff.sh path '<topic>' [<ticket-id>]
   ```

2. Write the handoff document to that path:
   - Summarize this session so that a fresh agent can continue the work.
   - Include a "Suggested skills" section with the skills that the next agent must load.
   - Do not copy content that other artifacts record (specs, plans, ADRs, issues, commits,
     diffs). Refer to them by path or URL.
   - If the work changed something that a spec or plan records, state the difference and its
     reason, for example "The plan says Room. This session uses DataStore, because the data is
     one small object." Do not edit the spec or plan for this.
   - If only a status in an artifact is out of date, for example a done plan step that is not
     ticked, update the artifact.
   - Keep the instructions of the user to ignore something, for example "ignore the lint warning
     in `:settings`". Without them, the next agent can try to fix it.
   - Redact sensitive data, for example API keys, passwords, or personal data.

3. Park: end the turn. The last line of the reply is `` 📄 Handoff: `<path>` ``.

4. Else, refresh:

   ```sh
   <skill folder>/handoff.sh refresh <path>
   ```

   In a `nono` sandbox (`printenv NONO_CAP_FILE` prints a path), run it as a background task.
   `nono` blocks `herdr` calls from a detached helper. There, the script runs its helper in the
   foreground of the background task.

5. Report the result, then end the turn. Do not call more tools.
   - Exit `0`: "This session clears after this turn and continues from the file. Do not type in
     this pane until the prompt shows." The log of the helper is
     `${TMPDIR:-/tmp}/handoff-refresh.log`. The last line of the reply is
     `` 📄 Handoff: `<path>` ``.
   - Exit `4` (not in herdr): tell the user to clear the session, then send the line that the
     script printed.
   - Exit `1`: the stderr text, word for word.
