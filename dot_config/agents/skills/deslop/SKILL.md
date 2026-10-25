---
name: deslop
argument-hint: "[reply | uncommitted | staged | <path>... | <free-text target>]"
description:
  Use when an agent wrote prose that ignores the writing rules - docs, code comments, docstrings,
  and commit messages on the current branch, in uncommitted or staged changes, or in a part of the
  code that the user names, that contain AI slop, filler, banned words, marketing diction, or very
  long comments. Also use for any file or pasted text, also outside a git repo. Also use to fix
  the wording of the assistant's last reply.
  Triggers on "deslop", "deslop that", "deslop your reply", "deslop my uncommitted changes",
  "deslop the README intro", "clean up the writing", "fix the wording on this branch".
allowed-tools:
  - Bash(~/.config/agents/bin/git-diff-context.sh *)
  - Bash(~/.claude/skills/deslop/git-reword-fixup.sh *)
  - Bash(~/.config/agents/bin/git-absorb-fixes.sh *)
  - Bash(~/.config/agents/bin/git-squash-fixups.sh *)
---

# deslop

This skill applies the writing rules from the instructions to prose that an agent wrote. In branch
and path mode, `git absorb` folds the file edits into their originating commits, and commit
messages get `amend!` commits. Then `git-squash-fixups.sh` squashes them, with no prompt. In the
working-tree modes, the skill writes the edits to the working tree. In file mode, the skill edits
the files in place and uses no git.

## Rules source - read, do not recall

Open these files at the start of **every** run, before you edit anything. Read them with the Read
tool, not with Bash:

- `~/.config/agents/instructions-agents.md` - the `## Written communication` section. It has the
  simple language, banned words, and formatting rules.
- `~/.config/agents/skills/documenting/SKILL.md` - for Markdown and docs.

In all modes except reply mode, also read these files in the same step:

- `~/.claude/skills/deslop/git-modes.md` - the scope, the judgment call, the comment pass, the
  loops, and the summary.
- `~/.config/agents/instructions-agents.md` - the `### Comments (inline and doc)` section of
  `## Code`. The comment pass applies these rules.
- The repo's own style docs, if they exist (`CONTRIBUTING*`, `docs/style*`). For files in that repo,
  these docs have priority over the personal rules.

This skill defines no writing rules. Do not recall them - recall causes the defect that this skill
must correct. The files are in your context, but in a long session they are far from the task.
Read them again. If `~/.config/agents/instructions-agents.md` is missing, tell the user and stop.

## Modes

Select the mode from the user's words. The user does not need a keyword. If the words fit more than
one mode, ask before you edit.

| Mode               | The user says                                   | Base       | Output       |
| ------------------ | ----------------------------------------------- | ---------- | ------------ |
| reply              | "reply", "your reply", or pasted text           | -          | Reply        |
| branch             | nothing                                         | `<parent>` | Fixups       |
| path               | only paths                                      | `<parent>` | Fixups       |
| uncommitted        | "uncommitted", "working tree", "my changes"     | `HEAD`     | Working tree |
| staged             | "staged", "index"                               | `HEAD`     | Working tree |
| branch-uncommitted | uncommitted, plus "with the branch"             | `<parent>` | Working tree |
| branch-staged      | staged, plus "with the branch"                  | `<parent>` | Working tree |
| target             | other words that name text in the repo          | `<parent>` | Working tree |
| file               | paths or words, with no git (see below)         | -          | Files        |

File mode replaces path mode and target mode in these cases:

- Path args: one path is not in a git work tree, or it is untracked, or its changes are not
  committed. Also when `git status --porcelain` in that repo gives output.
- Target words: the text is not in a git work tree.

Find this with `git -C <dir> rev-parse --is-inside-work-tree` and `git -C <dir> status --porcelain`.
Do not run `git-diff-context.sh` to find it. Do not stop. Do not tell the user about git. Git is
optional.

Targets:

- reply: the last assistant message, or the pasted text.
- branch: the branch diff `<parent>...HEAD` and its commit messages.
- path: the full files at those paths. There is no commit-message pass.
- uncommitted: the working tree and the untracked files vs `HEAD`. The branch commits are not in
  scope.
- staged: the index vs `HEAD`. The branch commits are not in scope.
- branch-uncommitted and branch-staged: the branch commits plus the uncommitted or staged changes.
- target: the text that the words name, for example a doc section, the comments in a file, or the
  docstrings of a class.
- file: the full files at those paths, or the text in files that the words name. There is no
  commit-message pass.

If there are no args and the directory is not a git repo, use reply mode. If the words name text in
the conversation and not in a file, use reply mode.

## Reply mode

1. Read the rule files for all modes (see "Rules source"). Do not skip this step because the
   target is only a reply.
2. Print the new text and nothing more. No diff, no list of changes, no preamble.
3. Apply each fix, including the fixes that remove data. Add one line below the new text. It names
   the removed data for the user to restore. Never prompt.
4. Change `[text](url)` to `text (url)`.

Skip all the git steps. There is no working tree, no `<parent>`, and no absorb.

## Mistakes - stop

- You write from memory of the rules instead of from the files. This is the defect to correct.
- You use git in reply mode. There is nothing to commit.
- You stop, or you tell the user, because a path is not in a git repo. Use file mode.
