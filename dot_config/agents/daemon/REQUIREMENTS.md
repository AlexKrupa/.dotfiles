# watchd requirements

Each item is a behavior that the user asked for. An item with the `(spec)` marker comes only
from a design spec that the user approved.

## W1 Daemon process

- W1.1 One `watchd` daemon polls each repo one time and sends each event to the session that watches
  it or to the hub.
- W1.2 The hub, `draft-pr`, `review-pr`, and `bump` watches all use the daemon.
- W1.3 One binary contains the daemon, the check engine, and the client.
- W1.4 The daemon is a program in Rust with Tokio.
- W1.5 The daemon fetches and processes data in parallel.
- W1.6 The daemon and its clients are separate, and the clients talk to the daemon through `watchd`
  CLI commands.
- W1.7 Client commands talk to the daemon over a Unix socket, and the daemon pushes events to a
  waiting client.
- W1.8 The daemon is the only writer of the state files.
- W1.9 If no daemon runs, a client that needs it starts it, and the user never starts the daemon by
  hand.
- W1.10 (spec) If no daemon answers on the socket, the client removes the old socket file and starts
  the daemon.
- W1.11 `watchd wait` of a session with no watch connects to a running daemon but does not start a
  daemon.
- W1.12 (spec) Only one daemon runs on each machine, and a start lock stops a second daemon.
- W1.13 (spec) The daemon runs apart from the session that started it, and a stop of that session or
  a Claude Code `TaskStop` does not stop the daemon.
- W1.14 (spec) The daemon needs no installed launchd service or other system service.
- W1.15 (spec) The daemon keeps the environment of the client that starts it, and tests and evals
  can put a fake `glab` on `PATH`.
- W1.16 The daemon and the client have no Claude Code names or knowledge, and a session is any agent
  conversation that has an ID.
- W1.17 `watchd` makes herdr calls only through one explicit interface for agents and panes, and no
  other daemon code calls herdr.
- W1.18 The daemon reacts to events from any data source, and a new source such as Jira needs no new
  architecture.
- W1.19 The macOS code is in a platform layer apart from the core logic.
- W1.20 (spec) Only macOS on Apple Silicon must work.
- W1.21 With no subscription and no `follow` client for 10 minutes, the daemon stops, and the next
  client starts it again.

## W2 Managed repos and worktrees

- W2.1 A client request from a folder in a git repo adds the repo to the managed set, and the daemon
  needs no manual list of repos.
- W2.2 (spec) A client request from a folder outside a git repo adds no repo.
- W2.3 (spec) A `follow` client adds no repo and uses the state folder in `XDG_STATE_HOME`.
- W2.4 The daemon manages a repo until the repo folder is gone.
- W2.5 The daemon is the state server of each repo and its worktrees, and clients subscribe to the
  parts of the state that they need.
- W2.6 All daemon behavior applies to all worktrees and sessions, also to those with no live watch.
- W2.7 (spec) The daemon finds all worktrees of each managed repo.
- W2.8 The stack of a worktree is its current branch and the git-spice branches below and above it,
  not the sibling branches on the trunk.
- W2.9 A stack is 2 or more own branches above the trunk, all in one worktree.
- W2.10 The daemon reads the stack from the worktree itself, and it also finds stacks made by hand
  and stacks with no watch or MR.
- W2.11 The daemon finds the MRs of a worktree from the stack branches with a submitted MR, and it
  adds the MR of a branch after its submit.
- W2.12 Each branch of the user's own work is tracked with git-spice, also a single branch with no
  stack.
- W2.13 The branch of another person, for example in a review worktree, is not tracked with
  git-spice.
- W2.14 For a worktree on the branch of another person, the skill gives the MR number, and with no
  number the daemon finds the MR on GitLab by the branch name, read-only.
- W2.15 The daemon keeps the link of a worktree and its MR after the agent ends.
- W2.16 The daemon reads a small git key of each worktree every 5 s, and it reads the stack and runs
  the conflict test only when the key changes.
- W2.17 (spec) The daemon never runs `git status` or another full read of a checkout on each tick.
- W2.18 The daemon fetches the default branch of each managed repo on a timer and tests each
  worktree for a conflict with it, also a branch with no MR.
- W2.19 (spec) The daemon fetches the default branch one time for each repo, for all worktrees of
  the repo.
- W2.20 (spec) The conflict test merges the top branch of the stack with `origin/<default>`, one
  merge test covers the full stack, and a conflict shows the names of the conflicting files.
- W2.21 The conflict test ignores the branches of merged MRs, in git-spice stacks and in branches
  whose MR comes from the MR lookup.
- W2.22 In a partly merged stack, the conflict test checks only the commits above the highest merged
  branch.
- W2.23 The daemon fast-forwards the main checkout after each fetch, with no agent step.
- W2.24 The daemon skips the fast-forward while the main checkout is on a different branch, has
  changes in tracked files, or cannot fast-forward.
- W2.25 (spec) The fetch continues while the fast-forward is skipped, and the daemon tries the
  fast-forward again in each round.
- W2.26 The daemon does not compare the branches of parallel worktrees for overlapping work.

## W3 Polling and GitLab access

- W3.1 The daemon polls GitLab for the open MRs of each worktree, with or without an agent watch.
- W3.2 The daemon stops the GitLab polling of a worktree when all its MRs are merged or closed.
- W3.3 The daemon polls the project-wide state of each managed repo, the hub check, also with no hub
  agent.
- W3.4 The hub check also finds the open MRs of the user and polls an own MR that has no managed
  worktree.
- W3.5 The daemon fetches an MR that two watches or two sources name only one time in each round.
- W3.6 A managed repo polls every 120 s while a hub agent of the repo is live, and every 15 minutes
  with no hub agent.
- W3.7 (spec) The fetch of the default branch uses the same intervals as the project-wide poll.
- W3.8 (spec) A live agent with a shorter `--interval` makes the poll interval of its repo shorter.
- W3.9 The poll interval of a repo is dynamic: it is shorter than 120 s for relevant events and
  longer when no refresh is necessary.
- W3.10 The dynamic polling changes only the one interval of each repo, and each round still checks
  all targets of the repo.
- W3.11 The daemon calls GitLab only through `glab api` child processes, and it uses the `glab`
  login, and the tests can use a fake `glab`.
- W3.12 (spec) At most 8 `glab` calls run at the same time for the daemon, and a cancelled call does
  not continue to run.
- W3.13 The GitLab access works with a fine-grained token that has Read permission for User, Todo,
  Event, Project, Merge Request, Work Item, and Pipeline, with no `read_api`.
- W3.14 The error text of a 401 or 403 error on MR notes contains the Work Item permission.
- W3.15 The check reads more than the oldest 100 discussions of an MR, and it sees new comments also
  on an MR with many system notes.
- W3.16 GitLab is the only data source and code host, and the design stays open to a second host
  such as GitHub.
- W3.17 The source abstraction comes with the first extra data source.

## W4 Errors, sleep, and network

- W4.1 The daemon recovers from network errors by itself, and a network error does not stop a watch.
- W4.2 A retriable GitLab server error, for example `graphql: Internal server error`, does not stop
  the watch.
- W4.3 A GitLab token failure ends the affected watches at once.
- W4.4 (spec) Errors that need the user, for example a missing token permission, `glab` with no
  login, a wrong repo, or a project that is gone, end the affected watches.
- W4.5 (spec) A permanent GitLab error, or 5 other errors in a row, ends the agent record of the
  key, and the next `wait` of the session gets the error.
- W4.6 (spec) An error ends only the affected watches, and the daemon continues.
- W4.7 (spec) A network error does not count as one of the errors in a row.
- W4.8 The daemon does no checks while the Mac sleeps, and a screen lock does not pause the checks.
- W4.9 Idle sleep pauses the checks the same as a lid close, and the caffeinate plugin does not keep
  the Mac awake for a watch.
- W4.10 (spec) Short maintenance wakes during sleep count as sleep.
- W4.11 After the computer wakes, the watches continue with no user step.
- W4.12 (spec) After a wake, the daemon waits for the network, checks at once, puts the events of
  the sleep into one delivery, and then uses the normal interval again.
- W4.13 During a network outage while the Mac is awake, the daemon waits with no limit and sends no
  report and no notification.
- W4.14 (spec) The sleep and network rules apply to all polling: the MR watches, the hub check, the
  fetch, and the job retry.
- W4.15 A watch has no deadline.

## W5 Events

- W5.1 The daemon makes one event set for each MR, with no code path for each skill.
- W5.2 An MR watch reports pipelines, comments, reactions, approvals, unapprovals, mergeable
  changes, merges, and closes.
- W5.3 (spec) Each event is one JSON line with `kind`, `iid`, `title`, `url`, `actor`, `detail`, and
  `branch`, and a comment or reaction on a diff line also has `path` and `line`.
- W5.4 (spec) Each event line has a `key` and a `mode` field, and a session with two watches can
  tell the events apart.
- W5.5 A reaction event has the emoji and the user who reacted, on the MR, on a comment, or on a
  thread message.
- W5.6 A `mergeable` event comes when the MR becomes mergeable, after the checks pass and enough
  reviewers approve.
- W5.7 The `mergeable` event gives the number of open threads.
- W5.8 (spec) A `conflict` or `mergeable` event comes only when the `conflicts` or `mergeable` field
  of the MR changes to true.
- W5.9 `need_rebase` is not an event, and only a merge conflict is an event.
- W5.10 The watch reports changes to the MR title, description, and labels, except changes that the
  user made.
- W5.11 A `pushed` event comes for each new push to a watched MR.
- W5.12 (spec) The `pushed` event has `old_base`, `old_head`, `new_base`, and `new_head` from the
  GitLab MR versions.
- W5.13 The daemon fetches the new commits of an MR before it sends the `pushed` event, and the
  agent can review only the interdiff.
- W5.14 (spec) The fetch of a push gets `refs/merge-requests/<iid>/head` from `origin`, also for a
  fork MR, and it changes no local ref and no `FETCH_HEAD`.
- W5.15 (spec) A failed MR fetch does not stop the event, the daemon logs `fetch of MR <iid>:
  <error>`, and the failure does not count as one of the 5 errors of the check.
- W5.16 (spec) A `pushed` event gets `local: true` when its new head is an ancestor of the local
  source branch.
- W5.17 A `resolved` event comes when a thread that the user started is resolved.
- W5.18 (spec) The `resolved` event has the user who resolved the thread as `actor`, if GitLab gives
  it.
- W5.19 (spec) Each delivery has one `unaddressed` line for each open thread whose last comment is
  not from the user, and these lines alone never wake the agent.
- W5.20 (spec) Each `unaddressed` event has a flag for a thread with a comment of the user.
- W5.21 The hub check reports new MRs, to-do items, comments in MRs of other people where the user
  commented, and failed pipelines of the default branch.
- W5.22 The watch does not report a passed default-branch pipeline, also not the first pass after a
  failure.
- W5.23 (spec) The `default-failed` event has the field `previous` with the status of the previous
  finished default-branch pipeline, or null if there is none.
- W5.24 (spec) The daemon reports `default-failed` only for a pipeline id above the saved id, and a
  job retry does not report an older failed pipeline again.

## W6 Watches

- W6.1 `watchd watch` in a worktree saves a watch of all MRs of the worktree, with no `--mr` list.
- W6.2 `--mr` is only an optional filter of MRs, and it does not start the polling.
- W6.3 `watchd watch --session <id>` saves the watch for the session and exits at once, with no
  `--once` and no `--stream` flag.
- W6.4 The watch of the MRs of one worktree, with one branch or many, is called `author` mode.
- W6.5 In the main checkout on a branch that is not the default branch, a watch with no `--mr` uses
  author mode, not hub mode.
- W6.6 (spec) Each watch has a key from its mode and folder, and a hub, author, and review watch in
  one worktree have separate state and do not replace each other.
- W6.7 A client that runs `watchd watch` and takes the events of its key is an agent, and a client
  that runs `watchd follow` and takes nothing is a follower.
- W6.8 (spec) The CLI keeps the names `watch`, `unsubscribe`, and `follow`, and the name "agent"
  applies only to the code and the docs.
- W6.9 Each mode has a default event list in one daemon table, with the condition and the exceptions
  of each event.
- W6.10 An author watch gets all MR kinds except `resolved`, and it gets `pushed` only without
  `local`.
- W6.11 An author watch gets a `pushed` event for a push that did not come from the agent.
- W6.12 A bump watch gets a `pushed` event when a different person pushes to the branch.
- W6.13 A review or bump watch gets all MR kinds, and it gets `unaddressed` only for threads with a
  comment of the user.
- W6.14 `watchd watch --events <kinds>` can only remove kinds from the list of the mode.
- W6.15 `--events` with a kind outside the mode list exits 1 with an error that contains the mode
  and its kinds.
- W6.16 (spec) A client that sends no `events` field gets the full list of the mode.
- W6.17 An event that the mode allows and the `--events` list of the watch does not is dropped, and
  it does not go to the hub.
- W6.18 The engine has no mode, and the daemon applies the mode filter right after each check,
  before the inbox, the items, and the hub.
- W6.19 A review watch puts no threads of other people on the hub board.
- W6.20 Each watch keeps its own engine state, not one shared state for each MR.
- W6.21 (spec) A new watch of a key with saved state first gets the events since the last check.
- W6.22 (spec) The `draft-pr`, `review-pr`, and `bump` watches work with no hub session and continue
  after the hub session closes.
- W6.23 `unsubscribe` does not remove a live watch of a different session, for example the hub
  watch.
- W6.24 (spec) `watchd unsubscribe --session <id>` removes the watch of the folder.
- W6.25 The cleanup of sessions never removes a watch that a new session just saved.
- W6.26 A watch ends only when all its MRs are merged or closed, an error needs the user, a newer
  session takes it, the user stops it, its worktree is gone, or its session ends.
- W6.27 When the worktree folder is gone, the daemon ends the watch with the error `the worktree is
  gone: PATH`.

## W7 Sessions and delivery

- W7.1 (spec) `watchd wait --session <id> --owner-pid <pid>` blocks until the session has events,
  prints them, and exits 0.
- W7.2 (spec) `watchd wait` exits with no output when the owner process ends or a newer waiter of
  the session replaces it.
- W7.3 The waiter checks only the owner PID, every 3 seconds, and the end of a process above the
  owner, for example Ghostty, does not stop the watch.
- W7.4 When the daemon closes the socket, for example at a restart, a waiting client connects again
  to the new daemon.
- W7.5 A round with no events gives no output and no message in the agent session.
- W7.6 (spec) Events that come while the agent works wait in the inbox and come in one batch to the
  next waiter.
- W7.7 (spec) While the agent record of a key exists, also during a restart, the events of the key
  go to its inbox, not to the hub.
- W7.8 The hub gets the events of a worktree that has no live agent session, but only as pending
  items.
- W7.9 (spec) An event kind with no item kind, for example `approved` or `merged`, does not go to
  the hub, but the notification and the sidebar still show it.
- W7.10 A session that has no connected waiter between turns keeps its watches.
- W7.11 (spec) A session is live while its owner process is alive, and away when the owner is gone,
  with its records and inbox kept.
- W7.12 (spec) An away session is back when a waiter with the same session ID comes, also with a new
  owner PID.
- W7.13 (spec) A session that stays away for the grace period ends, its agent records end, and the
  daemon removes its records.
- W7.14 The grace period of an away session is 30 minutes.
- W7.15 After `/clear`, a waiter with a new session ID and the same owner PID takes the watches of
  the old ID, and the watch continues.
- W7.16 When a second session watches a key that has a record, the newer session takes the record,
  and the older session gets one `replaced` event.

## W8 Hub and router

- W8.1 When a session watches an MR, the hub does not show the events and pending items of that MR,
  and the user gets no double report.
- W8.2 For an MR of a work session, the hub gets only the review request and the `opened` event.
- W8.3 The hub hides an MR from the watch start of its session on, with no earlier claim.
- W8.4 (spec) When a review or bump watch starts, the pending hub items of its MR move to that
  watch.
- W8.5 While no hub runs, the daemon keeps only pending items for the hub, not events, and a new hub
  gets these items in its first delivery.
- W8.6 The hub shows a pending item of an own worktree with no agent as one row, and it starts no
  agent for it.
- W8.7 `pull-blocked`, to-do items, mentions, and items of own worktrees become report rows with no
  model.
- W8.8 The router runs in the daemon after each hub check, and agents also start between hub turns
  and the hub session does not stall.
- W8.9 With no hub session open, the router starts no agent.
- W8.10 Each new MR goes through one router that takes one action for each MR.
- W8.11 A bump MR that also requests the review of the user gets only the bump agent.
- W8.12 (spec) If an MR has an `opened` and a `todo` event in one round, the MR action applies and
  the router dismisses the other event.
- W8.13 A bump MR is an MR whose author name or id contains `renovate` or `dependabot`, and the
  branch name does not count.
- W8.14 For a bump MR, the daemon starts a bump agent with `/bump <mr-url>` in a new worktree and
  workspace.
- W8.15 Auto-bump runs for each bump MR, also when the user is not a reviewer.
- W8.16 Auto-bump has no limit, with one workspace for each bump MR.
- W8.17 Bump MRs that are already open when the watch first starts get no agent.
- W8.18 When a newer bump agent of the same dependency starts, the daemon marks the older bump
  agents as stale.
- W8.19 (spec) Two bump branches are of the same dependency when they are equal with no `renovate/`
  or `dependabot/` prefix and no version suffix.
- W8.20 For a review request from a different person, the daemon starts a review agent with
  `/review-pr <mr-url>` in a new worktree of the MR source branch.
- W8.21 (spec) Auto-review starts on a `todo` event with the detail `review_requested`.
- W8.22 If a review report for the MR exists, the router starts no agent, the row shows `Already
  reviewed: <path>`, and the to-do item stays pending, also after new commits.
- W8.23 A new MR that is not a bump and requests no review of the user gets no row, no output, and
  no notification.
- W8.24 (spec) When an agent already works on the branch, the router starts no agent, and the cell
  is `An agent works on the branch` in the Agent section.
- W8.25 When an agent start fails, its stderr text is the cell, and the row stays pending.
- W8.26 (spec) If the list of agents fails in the stale check, the report shows no stale rows, and
  the daemon log has the error.
- W8.27 The router starts review and bump agents on the existing branch with no ticket id or
  placeholder id.
- W8.28 (spec) `work-start.sh` in `--branch` mode accepts no ticket id, and the session name is then
  the title or, with no title, the branch name.
- W8.29 The daemon starts review and bump agents through `work-start.sh` with an explicit agent
  kind, and the start needs no herdr agent pane.
- W8.30 An agent that `watchd` starts gets the same sandbox setting as an agent that the user
  starts, and `watchd` does not change it.
- W8.31 The hub starts agents with no prompt and no keys in the hub pane or in worktree agents, and
  nothing mixes with the typing of the user.
- W8.32 When a default-branch job fails for a runner reason, the daemon retries it at most 2 times.
- W8.33 (spec) The runner reasons are `runner_system_failure`, `stuck_or_timeout_failure`,
  `scheduler_failure`, and `api_failure`, and a job log with no script steps is not a runner
  failure.
- W8.34 (spec) The retry task reads the job status every 30 seconds for at most 1 hour, with no
  count of sleep time and network outages.
- W8.35 (spec) The retry count of each job is in the hub state, and the limit of 2 retries holds
  across a daemon restart.
- W8.36 A retry that runs during a daemon stop or restart is not dropped silently: the stop waits
  for it and writes a row.
- W8.37 Each retry result is one short row in the Agent section: passed after retry, retried 2 of 2,
  failed 3 times and stopped, or canceled or skipped after retry.
- W8.38 When a job fails for a reason other than the runner, the hub model does the triage and
  starts a debug agent.
- W8.39 (spec) A retried job that fails for another reason becomes a `default-failed` event with
  only that job, for the hub model.
- W8.40 The debug agent runs in a new worktree and herdr workspace, the same as `/work`.
- W8.41 One debug workspace covers all causes of one default-branch failure incident, and a new
  failure in the same incident uses it again.
- W8.42 (spec) With a debug workspace open, a failure after a failed `previous` pipeline is the same
  incident, and after a passed `previous` the hub starts a new debug workspace and marks the old one
  as stale with no close.
- W8.43 The hub gives its triage findings to the debug agent.
- W8.44 The debug agent fixes the failure, commits, runs `review-me` in auto mode and then
  `draft-pr`, and does not publish.
- W8.45 The hub and the `draft-pr` watch never name the GitLab debug skill, and the agent selects
  that skill by its description.
- W8.46 The router uses no code host or issue tracker data directly, and the code host and the
  tracker are behind interfaces.
- W8.47 (spec) If a fact for a decision cannot be read, for example a missing MR author, the event
  goes to the hub model as `AskModel`.
- W8.48 Events that the router handles do not wake the hub model, and an `AskModel` event goes to
  the hub inbox and wakes the model.
- W8.49 (spec) The hub report merges the saved router outcomes with the rows that the model sends
  for its own events.
- W8.50 (spec) Each router action of an MR logs the result `bump`, `review`, or `none` for the
  notification.

## W9 Pending items

- W9.1 The items that wait for the user are called "pending items", and an event with no row is
  "dismissed".
- W9.2 The router uses the name `ReportOnly` for an outcome that is only a report row.
- W9.3 The daemon opens and closes pending items from events and GitLab state, and the model opens
  and closes items that have no GitLab event.
- W9.4 An item that the model added stays pending until the model closes it, also after a reply or a
  reaction of the user.
- W9.5 A pending item closes when GitLab shows that its cause is gone, for example after a pipeline
  passes or a thread is resolved.
- W9.6 A comment item stays pending until the user replies after it, the user reacts to the last
  comment, or the thread is resolved.
- W9.7 A new comment from a different user in the thread opens the item again.
- W9.8 At each hub check, the daemon reads the reactions of each pending note of other users, with
  one REST call for each note, and closes a note that the user reacted to.
- W9.9 A hub `todo` item stays pending until GitLab marks the to-do done.
- W9.10 A hub `default-failed` item stays pending until a later pipeline of the default branch
  passes.
- W9.11 `reaction` and `opened` events never become pending hub items.
- W9.12 (spec) A review request with no agent start is a pending hub item.
- W9.13 A skipped fast-forward is one pending item until a fast-forward succeeds.
- W9.14 Pending items stay after a compaction, a session restart, and a daemon restart.
- W9.15 When a session ends or unsubscribes with pending items, these items go to the hub.
- W9.16 (spec) The pending items of a watch go away with its other results by the cleanup rules, but
  items that go to the hub stay.
- W9.17 (spec) A pending item keeps its row number in all rounds, and Agent and Info rows get new
  numbers in each round.
- W9.18 (spec) The client adds the row number to each JSON event line, and the model knows the key
  of each cell.
- W9.19 (spec) Each pending item keeps the time of its first event, and a report shows `Since
  <HH:MM>:` for an item from an earlier round.
- W9.20 (spec) The session can add its assessment to a pending item through `watchd report`, and the
  assessment stays until the item closes.
- W9.21 The report, the notification, and the sidebar use the same GitLab state, and they never show
  different states of one item.

## W10 State, restart, and log

- W10.1 The daemon keeps the watches, engine states, pending items with numbers and model text,
  waiting events, errors of ended watches, and the event log in state files.
- W10.2 (spec) The daemon writes each change to disk at once, and a crash loses no event.
- W10.3 A daemon restart or upgrade loses no event, sends no event two times, and needs no full
  sync.
- W10.4 The daemon keeps the kind, `done`, and `stopped` state of each worktree, and a herdr server
  restart does not lose them.
- W10.5 The daemon keys the kind and the stage by worktree path and keeps no herdr workspace IDs.
- W10.6 The daemon keeps only states, and the display picks the glyphs.
- W10.7 When the `watchd` binary changes, the daemon completes the current round, writes its state,
  and starts the new binary in the same process.
- W10.8 An update of the code takes effect by itself, with no manual restart of the daemon or the
  clients, and with no lost state.
- W10.9 (spec) The upgrade keeps the lock and the socket open, and it stops no running watch.
- W10.10 A restart of Ghostty, herdr, or Claude Code does not stop the watches, also with
  `claude-upgrade`.
- W10.11 `watchd` has no knowledge of `claude-upgrade`.
- W10.12 After any restart, each session that had a watch has the watch again, with no user input
  and no model turn.
- W10.13 An upgrade uses a migration and a smooth restart, and a new version converts only the state
  of the version before it.
- W10.14 (spec) The daemon logs and removes a state record of an older or unknown format version,
  and its watch starts again with a first check.
- W10.15 A change of the client API keeps no old path for old clients, and the skills change to the
  new names.
- W10.16 After a change of the client API, an old watch client gets an error from the daemon, and
  the user starts each old watch again one time.
- W10.17 (spec) When the state format version increases, the new daemon ends each old agent record
  at its first start, and the items of the record go to the hub.
- W10.18 The event log has one line for each event with the key, repo, MR title, time, and a sound
  class, and any program can read it.
- W10.19 (spec) The event log keeps 7 days of events.
- W10.20 (spec) The daemon removes the engine state of a key that has had no record for 7 days.
- W10.21 (spec) The daemon log has one line for each poll round, error, start, stop, watch change,
  and routed event, with the time, repo, and key.
- W10.22 At start, the daemon cuts a log of over 10000 lines to its last 5000 lines.
- W10.23 The error texts of the client, the daemon, and the engine start with `watchd: `.
- W10.24 The error text of an ended watch contains its key.

## W11 Client commands

- W11.1 The CLI has the subcommands `watch`, `wait`, `unsubscribe`, `status`, `kind`, `route`,
  `report`, `follow`, and `board`.
- W11.2 `watchd status` prints the daemon PID, the last poll time of each repo, and one line for
  each watch with its key, role, MRs, `live` or `away`, and inbox line count.
- W11.3 `live` in `watchd status` and in the sidebar JSON means that the session is not away.
- W11.4 (spec) `watchd debug state` prints all state as JSON, also the parts in memory only, and
  with no daemon it reads the disk.
- W11.5 (spec) The role skills set the kind of their worktree with `watchd kind` at start, and
  `work-start.sh` sets `mine` for new and next work.
- W11.6 (spec) `watchd kind` goes through the daemon and starts a stopped daemon.
- W11.7 `watchd follow` sends the full sidebar state and then a stream of event log lines and
  sidebar changes, with no polling.
- W11.8 Each `follow` line has an id, and a new connection with `--after <last id>` loses no event.
- W11.9 (spec) The sidebar state of `watchd follow` has the state of each worktree, keyed by
  worktree path.

## W12 Reports

- W12.1 The agent writes reports as Markdown tables, not as a code block.
- W12.2 `watchd report` prints the report table from the JSON cells of the model, and the model
  outputs the table word for word.
- W12.3 The daemon keeps only report data and no text layout.
- W12.4 Reports have the sections "Needs you", "Agent", and "Info".
- W12.5 (spec) The report columns are `#`, Section, MR (in the hub only), What happened, and
  Proposal or result.
- W12.6 The hub report is one table for the round with an MR column, and the MR links follow the
  table as Markdown bullets.
- W12.7 A work session report has one table for each MR, with the MR title and link above the table.
- W12.8 A report lists the pending items of earlier rounds, not only the events of this round.
- W12.9 (spec) Agent and Info rows show only the events since the last report, and an empty section
  is not shown.
- W12.10 (spec) The model can move an event to a different section, for example a failed pipeline
  that it fixed goes to Agent.
- W12.11 (spec) The first line of a report is the time as `HH:MM`.
- W12.12 A report shows an MR by its title, and the id shows only next to the link as `<MR title>
  (!<iid>) <url>`.
- W12.13 Watch output never shows an MR id or a pipeline id alone, with no readable name next to it.
- W12.14 (spec) Reports show no pipeline ids, SHAs, pane ids, or space numbers.
- W12.15 Reports show no Nerd Font glyphs.
- W12.16 Reports show a merged MR but do not suggest to remove the worktree.

## W13 Board

- W13.1 `watchd board` shows the current hub report and draws it again after each event, and router
  events stay visible after the notification.
- W13.2 The board is a persistent pane to the right of the hub agent pane, and it opens by itself at
  hub start.
- W13.3 (spec) `watchd kind hub` opens the board pane, and if a board pane of the repo exists, it
  opens no second pane.
- W13.4 (spec) If the board pane cannot open, `watchd kind hub` prints the error and exits 0.
- W13.5 The daemon writes the board rows as JSON for `watchd board`, and `watchd report` and the
  agents keep the Markdown text.
- W13.6 The board shows text formatted for the terminal, not a raw Markdown table.
- W13.7 The board draws one block for each row with the number, MR, what happened, and proposal,
  under a heading for each section.
- W13.8 The board wraps the text to the pane width and draws again when the pane size changes.
- W13.9 The board shows the "Needs you" heading in red and the "Agent" heading in yellow.
- W13.10 Each board row has a clickable terminal link to its MR or directly to the comment, and the
  board has no URL list.

## W14 Notifications

- W14.1 The herdr `watch` plugin sends all watch notifications from the daemon data, and the agent
  sessions and the hub send none.
- W14.2 (spec) The `watch` plugin makes the notification and sidebar decisions, and it stays a Bash
  plugin.
- W14.3 A notification shows as soon as the events come, with one notification for each MR in each
  round.
- W14.4 The title of a notification is the MR title, never the branch name.
- W14.5 The title of a notification for a default-branch pipeline is the branch name, for example
  `develop`.
- W14.6 The body of a notification shows what happened with names, not ids, and a pipeline
  notification shows the failed jobs.
- W14.7 The sound is `request` for events that need the user and `none` for all other events.
- W14.8 A stopped watch gets a notification with the MR title or `Hub` as the title and `Watch
  stopped: <error text>` as the body.
- W14.9 The own events of the user give no notification, for example an assignment of the user to an
  own MR.
- W14.10 An `opened` event gets a notification only after the router result, and by default only
  for a new dependency bump.
- W14.11 (spec) With no hub agent, a new MR gives no notification.
- W14.12 A configuration lists the router results that give a notification for a new MR, and the
  user can get notifications for other new MRs.
- W14.13 (spec) The notification of a new bump MR shows the action, for example `New dependency
  bump. Bump agent started.`, and a review request gets its notification from its `todo` event.
- W14.14 (spec) The watch works with no herdr, and then nothing sends notifications.

## W15 Author agent

- W15.1 After `draft-pr` submits, the agent watches the opened MRs in the background.
- W15.2 The agent finds the cause of a failed pipeline automatically.
- W15.3 The agent fixes trivial failures itself and pushes the fixes, and for other failures it asks
  the user.
- W15.4 Formatter, lint, and obvious compile errors are trivial failures.
- W15.5 The agent retries a failed job only when the cause is not in the branch, for example a
  runner failure.
- W15.6 A failure that is not trivial goes under "Needs you" with the cause and a proposed fix.
- W15.7 The agent folds each fix into the commits that added the lines.
- W15.8 The agent pushes fixes with the assumption that a push does not remove approvals.
- W15.9 Before each push, the agent syncs and restacks the branch.
- W15.10 (spec) The agent pushes with `git-spice stack submit --update-only`, which never opens an
  MR for a new branch.
- W15.11 If the restack before a push has a conflict, the agent resolves it when it can, and else it
  pushes with no restack and puts the conflict under "Needs you".
- W15.12 On a merge conflict, the agent syncs, restacks, resolves trivial conflicts, and pushes, and
  for other conflicts it stops the rebase and reports under "Needs you".
- W15.13 After a `merged` event, the agent runs sync, restack, and submit only when it is idle and
  an open MR is above.
- W15.14 The agent does auto-fixes only when the session is idle: a clean working tree, no rebase in
  progress, and no other task.
- W15.15 When the session is not idle, an auto-fix shows under "Needs you" as "fix waits, session
  not idle", and the agent does it at the first idle report or when the user asks.
- W15.16 For a new comment, the agent assesses if the suggestion is good or the reported bug is
  real, and it answers a question in the session output.
- W15.17 For a valid suggestion, the agent only proposes a fix and does not make it.
- W15.18 The agent never replies to a comment on the code host.
- W15.19 The agent never merges an MR.
- W15.20 (spec) The agent never resolves a thread, reacts, approves, marks an MR ready, or changes
  the title, description, or labels of an MR.
- W15.21 Approvals, unapprovals, reactions, mergeable changes, passed pipelines, and merged or
  closed MRs go under "Info", with no other action.
- W15.22 The agent reports a passed pipeline and an approval to the user and does not drop Info
  events.
- W15.23 The mergeable row gives the number of open threads and lists the threads with no answer,
  for example questions.
- W15.24 (spec) "Needs you" rows have numbers, and the user can say "fix 1".
- W15.25 (spec) On a `pushed` event that did not come from a local branch, the agent does not reset
  the branch, and it reports under "Needs you" that the local branch is behind or diverged.

## W16 Review agent

- W16.1 After `review-pr` reviews an MR, it watches the MR for conversation changes, replies, and
  approvals.
- W16.2 The review watch starts after each review, with no extra argument.
- W16.3 A session has one review watch for one MR, and if a watch for a different MR runs, the
  skill can stop with one line.
- W16.4 The review watch is read-only: no job retries, no replies, and no reactions.
- W16.5 (spec) During the review watch, the agent changes the repo only with a fetch of
  remote-tracking refs, and an author force push does not break the watch.
- W16.6 The review watch also reports comments from other people, not only replies in the threads of
  the user.
- W16.7 (spec) A reply in a thread of the user gets an assessment and a proposed response under
  "Needs you", a comment about the code of a finding or against the review goes under "Needs you",
  and all other comments go under "Info".
- W16.8 In review mode, `unaddressed` lists only open threads that the user started or replied in
  and whose last comment is not from the user.
- W16.9 A failed or passed pipeline, a conflict, an approval, an unapproval, a mergeable change, and
  a reaction go under "Info", with no retry.
- W16.10 A `merged` or `closed` event goes under "Info" and ends the review watch.
- W16.11 On an author push, the agent reviews only the content change and adds a round to the review
  report, and an amend or a force push gives no review of the whole branch.
- W16.12 A push with no content change gives one Info row.
- W16.13 (spec) The content change of a push is the diff of the two heads if the base did not
  change, and after a rebase it has only the files whose patch changed.
- W16.14 (spec) Each round of the review report has the date, the short new head, the fixed
  findings, the new findings, and the open findings.
- W16.15 (spec) Right after the review watch starts, if the remote MR branch is not the reviewed
  head, the agent handles it as a `pushed` event.
- W16.16 (spec) The review watch report shows if the local branch is behind or diverged after a
  push.
- W16.17 On a `resolved` event, the agent checks that a commit fixes the thread, with an Info row if
  fixed and a "Needs you" row if not.
- W16.18 The agent runs its own `git fetch` only when the new head of a push is not present after
  the daemon fetch.

## W17 Bump agent

- W17.1 The bump agent always watches the bot MR after its bump report.
- W17.2 On a bot push, if the versions in the diff changed, the bump agent checks the new versions
  again, and else it writes "Rebased" and waits for CI again.
- W17.3 On a failed pipeline, the bump agent retries jobs that the bump did not cause, and it
  commits and pushes fixes for failures that the bump caused.
- W17.4 If a bot force push deletes the fix commits of the bump agent, the agent lists them under
  "Needs you" and does not push them again.

## W18 Watch rules in skills

- W18.1 The watch rules that all watching skills share are in one place, and each skill keeps only
  its own role actions.
- W18.2 The Claude Code instructions for the watch are in a separate file from the generic watch
  rules.
- W18.3 The `draft-pr` watch has no host-specific commands and no name of a wrapper skill.
- W18.4 The host commands of the watch come from one GitLab host file, and the `draft-pr` wrapper
  only starts the watch of `draft-pr`.
- W18.5 The `git-spice` commands of the watch are in `draft-pr`, not in the host file.
- W18.6 When the user says "stop watch", the agent runs the unsubscribe command, and when the user
  says "watch", the agent starts the watch.
- W18.7 (spec) When a role rule says to stop, for example when all MRs are merged, the agent runs
  the unsubscribe command.
- W18.8 On a `replaced` event, the agent does not start the watch again.
- W18.9 (spec) On a watch error, the agent reports the error text and does not start the watch
  again.
- W18.10 (spec) The runner file tells the agent to start the watch with `--session` in the Bash
  tool, to take the events from the `Stop` hook feedback as JSON lines, and not to start the watch
  again after a result.
- W18.11 The `draft-pr` skill allows `Bash(watchd *)`, and it runs `watchd` with no permission
  prompt.
- W18.12 (spec) The GitLab watch reference documents the optional `--events <kinds>` flag.

## W19 herdr display states

- W19.1 herdr shows the kind of work and the stage of each workspace at a glance, for 5 to 10 or
  more agents.
- W19.2 The watch display is in herdr.
- W19.3 The kinds are `mine`, `review`, `bump`, `debug`, and `hub`.
- W19.4 (spec) A workspace with no kind shows no watch glyphs.
- W19.5 Each workspace with an agent shows kind and stage glyphs, also for an agent that did not
  start through `/work`.
- W19.6 A worktree with no kind gets its kind from the mode of its watch, with no extra GitLab call.
- W19.7 A review worktree never shows the `mine` kind.
- W19.8 Own work, review, and bump use one stage model: `watching` while a watch runs, and then
  `done` or `stopped`.
- W19.9 The `started` stage shows from the agent start until the watch starts, for all kinds except
  `mine` and `hub`.
- W19.10 (spec) A space never looks like `watching` while no watch runs, and the sidebar shows no
  glyph with no cause.
- W19.11 The `done` stage shows when all MRs are merged or closed, and it stays while the workspace
  is open.
- W19.12 A stack in which only some branches are merged is not `done`.
- W19.13 A merged worktree shows `done` and no conflict glyph.
- W19.14 A watch that stopped with MRs still open, after an error or a session end, shows the
  `stopped` stage.
- W19.15 (spec) The hub has no `started` and no `done` stage, and the stage does not repeat the
  agent state of the herdr dot.
- W19.16 A space shows a primary glyph for the stage and a secondary glyph for what needs the user.
- W19.17 A needs glyph follows the current GitLab state and goes away when its cause is gone.
- W19.18 (spec) A space shows the glyph of the first present needs value over all MRs of its stack,
  and the agents panel lists all present values.
- W19.19 (spec) An author worktree has the needs `failed`, `conflict`, `reply`, `requested_changes`,
  `ready`, and `draft`, in this order.
- W19.20 A review or bump worktree has two needs, in this order: a reply waits in a thread with a
  comment of the user, and new commits wait.
- W19.21 (spec) `reply` shows while an open thread waits for the user, and a separate need shows
  while a thread with a comment of the user waits.
- W19.22 (spec) `failed` shows while the head pipeline failed, and `conflict` while the merge status
  is `conflict` or `need_rebase`.
- W19.23 A local conflict with the default branch shows the same `conflict` glyph as an MR conflict,
  with low priority.
- W19.24 The conflict glyph shows only for a worktree whose own branches conflict.
- W19.25 `requested_changes` shows while the merge status is `requested_changes`.
- W19.26 `ready` comes from the GitLab merge status `mergeable`, not only from approvals and
  pipeline status.
- W19.27 A draft MR shows the `draft` value in the watching stage.
- W19.28 `commits` shows for a review while the head changed after the last comment or approval of
  the user.
- W19.29 The hub needs are `todo` while a review request or mention is pending, and `main-failed`
  while the newest default-branch pipeline failed.
- W19.30 After an agent session ends, the sidebar still shows the needs of the MRs of its worktree.
- W19.31 A worktree with a stack of 2 or more own branches shows a `stack` glyph.
- W19.32 The `stack` glyph shows for the full life of the workspace, not only while a watch is live.

## W20 herdr glyphs and layout

- W20.1 The watch state shows in the spaces part and in the agents part of the herdr sidebar.
- W20.2 The sidebar shows the state with leading glyphs, not with colors.
- W20.3 The glyphs are Nerd Fonts icons.
- W20.4 One space follows each glyph.
- W20.5 In the spaces part, the glyphs go between the slot number and the name.
- W20.6 (spec) Spaces in slot 10 and up show only the glyphs, with no number.
- W20.7 A space keeps the branch name as its name.
- W20.8 Each space stays one row, and over 20 spaces fit.
- W20.9 The sidebar shows no MR or PR numbers.
- W20.10 The `stack` glyph comes after the kind glyph, and for own work it is usually the first
  glyph.
- W20.11 The `stack` glyph shows in the sidebar row and in the agents panel line.
- W20.12 In the agents panel, the watch glyphs are at the start of the session title row, before the
  session name, with no status words.
- W20.13 In the agents panel, the herdr bullet with a space on each side separates the glyphs from
  the session name.
- W20.14 The session name of an agent that works on an MR is the MR title.
- W20.15 The user picks the glyphs, and they are in one table in the `labels` configuration folder
  that the user can edit.
- W20.16 (spec) A value with no glyph shows nothing.
- W20.17 The kind `mine` has no glyph.
- W20.18 The kind glyphs are package for bump, code_review for review, bug for debug, and home for
  hub.
- W20.19 The stage glyphs are robot for started, `oct-sync` for watching, stop for stopped, and
  broom for done.
- W20.20 The needs glyphs are x_circle for failed, alert for conflict, comment for reply,
  hand_back_left for requested_changes, repo_push for commits, rocket for ready, pencil for draft,
  bell for todo, and flame for main-failed.
- W20.21 The `stack` glyph is `oct-stack`.

## W21 herdr plugins

- W21.1 A separate herdr plugin `watch` (id `local.watch`) follows the daemon and writes the sidebar
  values.
- W21.2 The `watch` plugin gets the daemon state through `watchd follow`, not from the state files.
- W21.3 The `watch` plugin joins the herdr workspaces with the worktree state of the daemon.
- W21.4 (spec) The plugin finds the folder of a workspace from its checkout path or else from the
  focused pane of the active tab, and it maps the folder to the worktree with the longest path
  prefix, with no git call.
- W21.5 (spec) The `watch` plugin starts a separate watcher at herdr startup, and a herdr event
  starts a dead watcher again.
- W21.6 (spec) At herdr startup the plugin writes all sidebar values again, and it keeps the last
  kind and stage of each workspace until the workspace closes.
- W21.7 After the watcher starts, its first pass clears old watch tokens on every workspace of its
  own daemon.
- W21.8 During a restart of the agent session, the sidebar drops the watch token for a few
  seconds.
- W21.9 (spec) A follower writes and clears only the workspaces of its own daemon, and two followers
  can run together.
- W21.10 The `labels` plugin shows the watch data and reads only herdr workspace metadata, no
  `watchd` files.
- W21.11 The `labels` plugin watcher keeps running and updates the glyph of each workspace each time
  the watch state changes.
- W21.12 One command restarts the running herdr watchers, and `chezmoi update` runs it when the
  watcher files change.
- W21.13 The restart covers the `watch`, `labels`, and `caffeinate` watchers, and a watcher that
  does not run stays stopped.
- W21.14 A chezmoi run script links the herdr watch plugin at the first apply on a machine and when
  its setup files change.

## W22 herdr workspace order

- W22.1 The `watch` plugin sorts the worktree workspaces of a repo by work kind and then by label.
- W22.2 The sort moves only the linked worktree workspaces inside a repo group, and repo workspaces
  do not move.
- W22.3 The kind order is unwatched own work, watched own work, debug, bumps, code reviews, and then
  other kinds.
- W22.4 Only a worktree with a live watching agent counts as watched.
- W22.5 The label sort is case-insensitive and natural, and `ABC-23` comes before `ABC-123`.
- W22.6 The sort runs after each token write and sends no move if the order is already correct.
- W22.7 (spec) The sort touches only the worktree groups with at least one workspace that its
  follower knows.

## W23 Claude Code plugin

- W23.1 One Claude Code plugin holds all Claude Code logic of `watchd`.
- W23.2 The plugin is in `daemon/integrations/claude-code/`, with a symlink from the `local-pins`
  marketplace.
- W23.3 (spec) Claude Code reads the plugin live through its symlink, and a plugin change takes
  effect at the next session start or after `/reload-plugins`.
- W23.4 The plugin runs `watchd wait` from hooks and wakes Claude with the events, with no `Monitor`
  tool and no `/exit` dialog.
- W23.5 (spec) The plugin gives events as exit 2 with the events on stderr, and the `Stop` hook
  after each turn starts the next waiter.
- W23.6 (spec) The `SessionStart` hook for all sources and the `Stop` hook run `wait.sh` with
  `asyncRewake` and a one-week timeout.
- W23.7 (spec) Only the `SessionStart` source `clear` renames the session.
- W23.8 (spec) After `/resume` in a running process, the old conversation is away and keeps its
  watches and inbox until it comes back or the grace period ends.
- W23.9 The plugin wakes Claude one time for one error text of a session, and the same error text
  again gives no wake.
- W23.10 While a watch runs, the user can use the same session for other prompts.
- W23.11 The Claude Code install script installs only the plugins of the dotfiles, from
  `settings.json` and from the local marketplace with `watchd`.

## W24 Sample repo

- W24.1 A sample repo shows the live behavior of the daemon and its herdr plugins inside herdr.
- W24.2 The sample runs in the real herdr session of the user, not in a separate herdr server.
- W24.3 A test daemon is only for the sample repo and runs next to the real daemon, independent of
  it.
- W24.4 The local git key `watchd.stateHome` selects the test daemon, and all worktrees of the
  sample share it.
- W24.5 (spec) A client in a repo with `watchd.stateHome` uses that folder for the socket and the
  state, and a client in a repo with no key does not change.
- W24.6 (spec) A client with `watchd.stateHome` never starts a daemon, and with no daemon it fails
  with `no watchd daemon in <folder>, run: daemon/sample/sample start`.
- W24.7 The test daemon has its own state, a fake engine, and a fake `git-spice`, starts no Claude
  agents, and moves between fixture states.
- W24.8 (spec) The test daemon does a round every 2 s.
- W24.9 The fakes of the sample are local to the sample and not in the global configuration.
- W24.10 The sample uses the fakes of the tests again, for example one fake `git-spice` for both.
- W24.11 The sample covers the hub, a stacked worktree with MR events and the conflict test, a
  single branch, a review worktree, the watching state, a daemon restart, and a state migration.
- W24.12 The sample also covers a removed worktree, 5 failed checks, a hub job retry, a merged
  bottom MR, and an own MR with no worktree.
- W24.13 (spec) The sample tests the daemon core, the `watch` plugin, and the `labels` plugin, and
  not the GitLab checks or the skills.
- W24.14 The sample has separate scenarios, each a short chain of steps from a reset, and a problem
  in one scenario does not block the others.
- W24.15 A control pane shows the current scenario, step, expected view, and daemon facts.
- W24.16 A simple CLI, `sample`, starts and moves through the scenarios.
- W24.17 (spec) The `sample` CLI has `start`, `stop`, `run`, `next`, `back`, `status`, `list`, `ui`,
  and `check`.
- W24.18 `sample check` is a command that the user runs by hand, and it is not a part of
  `daemon/test.sh`.
- W24.19 (spec) `sample check` runs the scenarios with no herdr and fails a step on a daemon error
  line, a stopped daemon, or a failed settle.
- W24.20 (spec) `sample` makes the sample repo with a local bare repo as `origin`, and the fetch
  stays real with no network.
- W24.21 (spec) `sample start` copies the test binary with a new name, and a running test daemon
  restarts with it.
- W24.22 (spec) `sample start` starts a second `watch` plugin watcher for the test daemon, with its
  own plugin state.
- W24.23 (spec) Each step has a change script and an `expect.md` list of what the sidebar, the
  board, and the agent panes show.
- W24.24 (spec) After each step, `sample` waits until the daemon takes all fake events, and after 15
  s it fails with the keys that have events.
- W24.25 (spec) A step stops at its first failed command, prints the step and the path of
  `watchd.log`, and does not move the current step.
- W24.26 (spec) A reset stops the sample agents, workspaces, and test daemon, deletes the sample
  state and repo, and starts again from a new repo.
- W24.27 (spec) The current step is in a file, and `sample status` and `sample ui` show the same
  state, also after a restart.
- W24.28 (spec) If the test daemon does not run from the test binary, each `sample` command except
  `start` stops with an error that names `sample start`.
- W24.29 (spec) `SAMPLE_ROOT` and `SAMPLE_STATE` change the two base folders of the sample, for the
  tests of `sample`.
- W24.30 (spec) The sample `agent-loop` runs one `watchd watch --session $$` and then a loop of
  `watchd wait`, which shows that an agent other than Claude can use `watchd`.
- W24.31 `sample ui` draws again only when the status text changes, with no screen clear and no
  blank frame.
- W24.32 `sample ui` shows one flat list of all steps on its main screen at start, under a header
  for each scenario.
- W24.33 In `sample ui`, a step number and Enter go to that step.

## W25 Build and install

- W25.1 The daemon source is in the `daemon/` folder of the dotfiles repo, next to the skills, not
  in its own repo.
- W25.2 A skill change and its daemon change go into the same commit.
- W25.3 The binary is not in git, and `chezmoi update` builds it again.
- W25.4 (spec) The binary installs to a folder on `PATH` outside chezmoi management, and on the main
  machine the agent runs the build script after each change.
- W25.5 (spec) No build runs in a session at run time, and a compile error does not stop the
  watches.
- W25.6 The build uses a simple toolchain and dependency manager, with no Gradle-like complexity.
- W25.7 A clean build of about 1 minute after `chezmoi update` is acceptable.
- W25.8 The build can assume Homebrew.
- W25.9 (spec) `dot_brewfile` installs the Rust toolchain.
- W25.10 The old Bash watch scripts are deleted, and `.chezmoiremove` lists them.
- W25.11 The Bash scripts of `watchd` need Bash 5 or later, and macOS `/bin/bash` 3.2 is not
  supported.

## W26 Tests

- W26.1 The tests use fake `glab`, `git-spice`, and `herdr` programs where a real program is not
  possible, and real `git` in temporary repos.
- W26.2 The daemon tests are native tests, and the shell tests run on the default bash only, with no
  run on macOS `/bin/bash` 3.2.
- W26.3 When a change removes an internal mechanism, each test of that mechanism becomes a test of
  the same behavior.
- W26.4 The daemon tests are in separate test files by topic, and each file has its own temp folder
  and daemon.
- W26.5 `daemon/test.sh` runs all test binaries in parallel, and the tests of one binary run one at
  a time.
- W26.6 A test that checks for no change waits for daemon rounds that start after the action, not
  for a fixed sleep, except a wait that tests a wall-clock limit.
- W26.7 `WATCHD_TICK` and `WATCHD_MANAGED_SECONDS` accept fractions of a second, and the tests run
  with 0.2 s rounds.
- W26.8 (spec) `WATCHD_GRACE_SECONDS` sets the grace period.
- W26.9 The tests cover a daemon run with the network down and a kill of the daemon together with
  its loops.
- W26.10 (spec) The tests cover more than 5 network errors and then a success, a check at once after
  a wake, exit 1 at once on an auth error, the retry timeout with no sleep time, and no deadline.
- W26.11 (spec) The tests cover author watch events, `unaddressed` lines, reactions, and the end of
  a watch when its worktree is removed.
- W26.12 (spec) The tests cover review mode: `pushed` after an amend, `pushed` after a rebase,
  `resolved`, `unaddressed` with the review filter, and the separate key.
- W26.13 (spec) The interdiff tests cover an amend, a rebase with no content change, and a rebase
  with a content change.
- W26.14 (spec) The tests cover the `previous` field and the pipeline id rule of `default-failed`.
- W26.15 (spec) The tests cover `wait`: an exit when the owner ends, no exit when a process above
  the owner ends, a new connection after a daemon restart, and exit 1 with the error text.
- W26.16 (spec) The tests cover liveness, rename, replace, migration, and the scenarios of the
  sample with the new `agent-loop`.
- W26.17 (spec) A shell test checks the exit code table of the plugin `wait.sh` with a fake
  `watchd`.
- W26.18 (spec) An end-to-end check in a herdr test pane, with the real plugin and the sample
  daemon, shows the plugin install through the symlink, the wake of an idle session, events after
  `/clear` and after `/exit` and `claude --resume`, and no dialog at `/exit`.
- W26.19 (spec) A daemon test with real git repos and a fake `glab` shows `pushed` with the commits
  present for a push from a different clone, and `local: true` with no author event for a push from
  the repo.
- W26.20 (spec) Table tests for each mode show the kinds, the `mine` and `local` conditions, the
  needs order, and the `--events` filter, and a client test shows exit 1 for a kind outside the mode
  list.
- W26.21 (spec) The router tests cover each decision rule with no fakes, the agent starts and the 6
  retry results with fakes, and a read-only board render.
- W26.22 (spec) The tests cover the `watchd.stateHome` client, followers that do not touch unknown
  workspaces, and a sort that skips groups with no tokens.
- W26.23 An end-to-end test runs the watch in a test repo with a worktree and a fake `glab`, in a
  herdr test workspace.
- W26.24 An automated test starts a watch, stops it, and checks that the sidebar glyph changes each
  time.
- W26.25 The `review-pr` and `bump` evals work with the daemon client, and each eval run uses its
  own state folder, not the real daemon of the user.
- W26.26 The skill evals expect a Bash `watchd watch --session` call, allow no `Monitor` or
  `TaskStop`, and stop no watch clients.
- W26.27 (spec) The `draft-pr` evals use a fake watch command with fixture events and check that the
  agent never replies, resolves, approves, merges, or marks an MR ready.
- W26.28 (spec) The `draft-pr` evals check that a lint failure gives a fix in the correct commit and
  a submit, a failure that is not trivial gives a "Needs you" row and no push, and a comment gives
  an assessment and no reply.
- W26.29 (spec) The `draft-pr` evals check the report format, and that a dirty working tree gives
  "fix waits" and no fix.
- W26.30 (spec) The reviewer evals cover a small amend, a rebase with no content change, a reply and
  a comment from a different reviewer, a resolve with no fix, and no retry or reply on a failed job.
