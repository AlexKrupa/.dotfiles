@~/.config/agents/instructions-agents.md

@~/.config/agents/machine.md

# Claude Code notes for the skills

## work

Claude Code loads each slash command that comes after `/work` as a skill in this session. It
removes the skill names from `$ARGUMENTS`. If this turn loaded other skills next to `/work`, write
their names first in the prompt. Use the names from the `<command-name>` tags, in the same order,
on one line with spaces between them, for example `/plugin:skill-a /skill-b`. Then write
`$ARGUMENTS` on the same line. Do not run these skills in this session. They are for the new
agent.

One-time setup: Claude Code trusts `~/.herdr/worktrees` after you run `claude` in that folder and
accept the prompt.

## exec

The report of step 7 and the report of "Review handoff" end with a "Do not type in this pane"
sentence. Add one more sentence after it:

- Out of a `nono` sandbox: "The effort stays set for later sessions of this model: `/effort auto`
  resets it."
- In a `nono` sandbox: "The effort applies to this session. If `~/.claude/settings.json` has an
  effort for this model, that effort applies at the next start."

## Mining

The local agent instruction file of the repo is `CLAUDE.local.md`.
