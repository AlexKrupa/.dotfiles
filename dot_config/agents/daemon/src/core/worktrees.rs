//! The managed repos and the state of their worktrees, with no input or output.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::core::subs::{Agent, Mode};
use crate::core::workspaces::{Kind, Stage};
use crate::engine::state::{Need, OwnMr};
use crate::key::review_key;

/// The main worktree of each repo that a client used, as a canonical path.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Repos {
    pub repos: Vec<PathBuf>,
}

/// The local state of one worktree. `key` is the git state at the last read of git-spice. `stack` has
/// the branches above the trunk, and `mrs` their MRs. `ended` has the merged or closed MRs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WorktreeState {
    pub path: PathBuf,
    pub repo: PathBuf,
    pub branch: Option<String>,
    pub key: String,
    pub stack: Vec<String>,
    pub mrs: Vec<u64>,
    #[serde(default)]
    pub conflict: Vec<String>,
    #[serde(default)]
    pub ended: Vec<u64>,
    /// The branch of the last MR lookup by branch name.
    #[serde(default)]
    pub lookup_branch: Option<String>,
    /// The kind of work, from `watchd kind` or the first agent, for the sidebar.
    #[serde(default)]
    pub kind: Option<Kind>,
    /// The end of the last agent.
    #[serde(default)]
    pub stage: Option<Stage>,
    /// The needs-you values of the last check of each stack or review key of the worktree. The
    /// sidebar shows them also with no live agent.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub needs: BTreeMap<String, Vec<Need>>,
}

/// One GitLab check of a round. `repo` is the folder of the check: the main checkout for the hub
/// and the own MRs, else the worktree.
#[derive(Clone, Debug, PartialEq)]
pub struct Target {
    pub key: String,
    pub slug: String,
    pub mode: Mode,
    pub repo: PathBuf,
    pub mrs: Vec<u64>,
}

/// The MR of another person that a worktree reviews.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ReviewLink {
    pub worktree: PathBuf,
    pub iid: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Reviews {
    pub reviews: Vec<ReviewLink>,
}

/// The branch to look up on GitLab: a branch with no git-spice MR and no review link, not the
/// default branch, and not looked up before.
pub fn lookup_branch<'a>(state: &'a WorktreeState, default: Option<&str>, reviews: &[ReviewLink]) -> Option<&'a str> {
    let branch = state.branch.as_deref()?;
    let linked = reviews.iter().any(|link| link.worktree == state.path);
    let done = state.lookup_branch.as_deref() == Some(branch);
    match state.mrs.is_empty() && !linked && !done && default != Some(branch) {
        true => Some(branch),
        false => None,
    }
}

/// The hub, then the reviews, the stacks of the worktrees and of the live agents, and the own MRs
/// with no worktree. A stack or own MR is in no other target. `key_of` gives the stack key of a
/// worktree.
pub fn targets(
    repo: &Path,
    slug: &str,
    worktrees: &[WorktreeState],
    own_mrs: &[OwnMr],
    reviews: &[ReviewLink],
    agents: &[Agent],
    key_of: &dyn Fn(&Path) -> String,
) -> Vec<Target> {
    let target = |key: String, mode: Mode, folder: &Path, mrs: Vec<u64>| Target {
        key,
        slug: slug.to_string(),
        mode,
        repo: folder.to_path_buf(),
        mrs,
    };
    let mut list = vec![target(slug.to_string(), Mode::Hub, repo, Vec::new())];
    let mut taken: Vec<u64> = Vec::new();
    let agent_reviews = agents
        .iter()
        .filter(|agent| agent.mode == Mode::Review)
        .filter_map(|agent| Some((agent.repo.clone(), *agent.mrs.first()?)));
    let links = reviews.iter().map(|link| (link.worktree.clone(), link.iid));
    // Two worktrees can review the same MR: the MR cache gives it one fetch in a round.
    for (worktree, iid) in links.chain(agent_reviews) {
        let key = review_key(&key_of(&worktree), iid);
        if list.iter().any(|known| known.key == key) {
            continue;
        }
        taken.push(iid);
        list.push(target(key, Mode::Review, &worktree, vec![iid]));
    }
    let open =
        |mrs: &[u64], ended: &[u64]| -> Vec<u64> { mrs.iter().copied().filter(|iid| !ended.contains(iid)).collect() };
    let mut stacks: Vec<(String, PathBuf, Vec<u64>)> = worktrees
        .iter()
        .map(|state| (key_of(&state.path), state.path.clone(), open(&state.mrs, &state.ended)))
        .collect();
    for agent in agents.iter().filter(|agent| agent.mode == Mode::Stack) {
        let mrs = open(&agent.mrs, &agent.ended_mrs);
        match stacks.iter_mut().find(|(key, ..)| *key == agent.key) {
            Some((.., known)) => known.extend(mrs),
            None => stacks.push((agent.key.clone(), agent.repo.clone(), mrs)),
        }
    }
    for (key, folder, mrs) in stacks {
        let mut left: Vec<u64> = Vec::new();
        for iid in mrs {
            if !taken.contains(&iid) {
                taken.push(iid);
                left.push(iid);
            }
        }
        if !left.is_empty() {
            list.push(target(key, Mode::Stack, &folder, left));
        }
    }
    let own: Vec<u64> = own_mrs
        .iter()
        .map(|mr| mr.iid)
        .filter(|iid| !taken.contains(iid))
        .collect();
    if !own.is_empty() {
        list.push(target(format!("{slug}-own"), Mode::Stack, repo, own));
    }
    list
}

impl WorktreeState {
    pub fn new(
        path: PathBuf,
        repo: PathBuf,
        branch: Option<String>,
        key: String,
        branches: &[SpiceBranch],
    ) -> WorktreeState {
        // From the trunk, git-spice lists all tracked branches: none of them is the stack of the
        // worktree.
        let on_trunk = branches.iter().any(|branch| branch.current && !branch.down);
        let stack = branches.iter().filter(|branch| branch.down && !on_trunk);
        WorktreeState {
            path,
            repo,
            branch,
            key,
            stack: stack.clone().map(|branch| branch.name.clone()).collect(),
            mrs: stack.filter_map(|branch| branch.mr).collect(),
            conflict: Vec::new(),
            ended: Vec::new(),
            lookup_branch: None,
            kind: None,
            stage: None,
            needs: BTreeMap::new(),
        }
    }

    /// Takes the git fields of a local read. The other fields have other writers.
    pub fn set_local(&mut self, read: WorktreeState) {
        self.repo = read.repo;
        self.branch = read.branch;
        self.key = read.key;
        self.stack = read.stack;
        self.mrs = read.mrs;
        self.conflict = read.conflict;
    }
}

/// One branch of `git-spice log short --json`. `down` is false for the trunk.
#[derive(Clone, Debug, PartialEq)]
pub struct SpiceBranch {
    pub name: String,
    pub current: bool,
    pub down: bool,
    pub ups: Vec<String>,
    pub mr: Option<u64>,
}

#[derive(Deserialize)]
struct Named {
    name: String,
}

#[derive(Deserialize)]
struct Change {
    id: String,
}

#[derive(Deserialize)]
struct SpiceLine {
    name: String,
    #[serde(default)]
    current: bool,
    down: Option<Named>,
    #[serde(default)]
    ups: Vec<Named>,
    change: Option<Change>,
}

/// One JSON object for each line. The `id` of a GitLab change is `!IID`.
pub fn parse_spice_log(text: &str) -> Vec<SpiceBranch> {
    text.lines()
        .filter_map(|line| serde_json::from_str::<SpiceLine>(line).ok())
        .map(|line| SpiceBranch {
            name: line.name,
            current: line.current,
            down: line.down.is_some(),
            ups: line.ups.into_iter().map(|up| up.name).collect(),
            mr: line.change.and_then(|change| change.id.strip_prefix('!')?.parse().ok()),
        })
        .collect()
}

/// A top branch has the commits of all branches below it.
pub fn top_branches(branches: &[SpiceBranch]) -> Vec<String> {
    branches
        .iter()
        .filter(|branch| branch.down && branch.ups.is_empty())
        .map(|branch| branch.name.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::subs::{Agent, Mode};
    use crate::engine::state::OwnMr;

    fn worktree(path: &str, mrs: &[u64], ended: &[u64]) -> WorktreeState {
        WorktreeState {
            mrs: mrs.to_vec(),
            ended: ended.to_vec(),
            ..WorktreeState::new(path.into(), "/r".into(), Some("b".into()), "k".into(), &[])
        }
    }

    fn own(iids: &[u64]) -> Vec<OwnMr> {
        iids.iter().map(|iid| OwnMr { iid: *iid }).collect()
    }

    fn key_of(path: &Path) -> String {
        format!("app-{}", path.display())
    }

    /// `(key, mode, repo, mrs)` of each target.
    fn summary(targets: &[Target]) -> Vec<(String, Mode, String, Vec<u64>)> {
        targets
            .iter()
            .map(|target| {
                let repo = target.repo.display().to_string();
                (target.key.clone(), target.mode, repo, target.mrs.clone())
            })
            .collect()
    }

    fn row(key: &str, mode: Mode, repo: &str, mrs: &[u64]) -> (String, Mode, String, Vec<u64>) {
        (key.to_string(), mode, repo.to_string(), mrs.to_vec())
    }

    #[test]
    fn targets_have_one_hub_and_one_stack_per_worktree_with_mrs() {
        let worktrees = [
            worktree("/r", &[], &[]),
            worktree("/r/a", &[12], &[]),
            worktree("/r/b", &[13, 14], &[]),
        ];

        let targets = targets(Path::new("/r"), "app", &worktrees, &[], &[], &[], &key_of);

        assert_eq!(
            summary(&targets),
            [
                row("app", Mode::Hub, "/r", &[]),
                row("app-/r/a", Mode::Stack, "/r/a", &[12]),
                row("app-/r/b", Mode::Stack, "/r/b", &[13, 14]),
            ]
        );
        assert!(targets.iter().all(|target| target.slug == "app"));
    }

    #[test]
    fn targets_skip_a_worktree_with_all_mrs_ended() {
        let worktrees = [worktree("/r/a", &[12], &[12]), worktree("/r/b", &[13, 14], &[13])];

        let targets = targets(Path::new("/r"), "app", &worktrees, &[], &[], &[], &key_of);

        assert_eq!(
            summary(&targets),
            [
                row("app", Mode::Hub, "/r", &[]),
                row("app-/r/b", Mode::Stack, "/r/b", &[14])
            ]
        );
    }

    #[test]
    fn targets_put_own_mrs_without_worktree_in_the_own_key() {
        let worktrees = [worktree("/r/a", &[12], &[])];

        let targets = targets(Path::new("/r"), "app", &worktrees, &own(&[12, 14]), &[], &[], &key_of);

        assert_eq!(
            targets.last().map(|target| (target.key.as_str(), target.mrs.clone())),
            Some(("app-own", vec![14]))
        );
        assert_eq!(
            targets.last().map(|target| target.repo.clone()),
            Some(PathBuf::from("/r"))
        );
    }

    #[test]
    fn targets_have_each_mr_one_time() {
        let worktrees = [worktree("/r/a", &[12, 20], &[])];
        let reviews = [ReviewLink {
            worktree: "/r/c".into(),
            iid: 20,
        }];

        let targets = targets(
            Path::new("/r"),
            "app",
            &worktrees,
            &own(&[12, 20, 30]),
            &reviews,
            &[],
            &key_of,
        );

        assert_eq!(
            summary(&targets),
            [
                row("app", Mode::Hub, "/r", &[]),
                row("app-/r/c-review-20", Mode::Review, "/r/c", &[20]),
                row("app-/r/a", Mode::Stack, "/r/a", &[12]),
                row("app-own", Mode::Stack, "/r", &[30]),
            ]
        );
    }

    #[test]
    fn targets_have_a_review_of_the_same_mr_in_each_worktree() {
        let reviews = [
            ReviewLink {
                worktree: "/r/c".into(),
                iid: 20,
            },
            ReviewLink {
                worktree: "/r/d".into(),
                iid: 20,
            },
        ];

        let targets = targets(Path::new("/r"), "app", &[], &[], &reviews, &[], &key_of);

        let keys: Vec<&str> = targets.iter().map(|target| target.key.as_str()).collect();
        assert_eq!(keys, ["app", "app-/r/c-review-20", "app-/r/d-review-20"]);
    }

    #[test]
    fn lookup_branch_needs_a_branch_with_no_mr_no_link_and_no_lookup() {
        let plain = worktree("/r/a", &[], &[]);
        let link = [ReviewLink {
            worktree: "/r/a".into(),
            iid: 20,
        }];
        let looked_up = WorktreeState {
            lookup_branch: Some("b".into()),
            ..plain.clone()
        };
        let detached = WorktreeState {
            branch: None,
            ..plain.clone()
        };

        assert_eq!(lookup_branch(&plain, Some("main"), &[]), Some("b"));
        assert_eq!(lookup_branch(&plain, Some("b"), &[]), None, "the default branch");
        assert_eq!(
            lookup_branch(&worktree("/r/a", &[12], &[]), None, &[]),
            None,
            "a git-spice MR"
        );
        assert_eq!(lookup_branch(&plain, None, &link), None, "a review link");
        assert_eq!(lookup_branch(&looked_up, None, &[]), None, "the same branch again");
        assert_eq!(lookup_branch(&detached, None, &[]), None, "no branch");
    }

    fn agent(key: &str, mode: Mode, repo: &str, mrs: &[u64]) -> Agent {
        Agent {
            key: key.to_string(),
            slug: "app".to_string(),
            repo: repo.into(),
            mode,
            mrs: mrs.to_vec(),
            interval: 120,
            session_pid: 1,
            client_pid: 2,
            client_at: 0,
            replaced_sessions: Vec::new(),
            ended_mrs: vec![9],
            herdr_workspace: None,
        }
    }

    #[test]
    fn targets_have_the_mrs_of_a_live_agent() {
        let worktrees = [worktree("/r/a", &[12], &[])];
        let agents = [
            agent("app-/r/a", Mode::Stack, "/r/a", &[12, 13, 9]),
            agent("app-/r", Mode::Stack, "/r", &[5]),
            agent("app-/r/c-review-20", Mode::Review, "/r/c", &[20]),
            agent("app", Mode::Hub, "/r", &[]),
        ];

        let targets = targets(Path::new("/r"), "app", &worktrees, &[], &[], &agents, &key_of);

        assert_eq!(
            summary(&targets),
            [
                row("app", Mode::Hub, "/r", &[]),
                row("app-/r/c-review-20", Mode::Review, "/r/c", &[20]),
                row("app-/r/a", Mode::Stack, "/r/a", &[12, 13]),
                row("app-/r", Mode::Stack, "/r", &[5]),
            ]
        );
    }

    const STACK: &str = r#"{"name":"main","ups":[{"name":"a"}]}
{"name":"a","down":{"name":"main"},"ups":[{"name":"b"}],"change":{"id":"!12","url":"u"}}
{"name":"b","current":true,"down":{"name":"a"}}
"#;

    #[test]
    fn parse_spice_log_reads_stack_and_change() {
        let branches = parse_spice_log(STACK);

        assert_eq!(top_branches(&branches), ["b"]);
        let mrs: Vec<Option<u64>> = branches.iter().map(|branch| branch.mr).collect();
        assert_eq!(mrs, [None, Some(12), None]);
        assert_eq!(branches[1].ups, ["b"]);
    }

    #[test]
    fn parse_spice_log_with_one_branch_has_one_top_branch() {
        let branches = parse_spice_log(
            "{\"name\":\"main\",\"ups\":[{\"name\":\"a\"}]}\n{\"name\":\"a\",\"current\":true,\"down\":{\"name\":\"main\"}}\n",
        );

        assert_eq!(top_branches(&branches), ["a"]);
    }

    #[test]
    fn worktree_on_the_trunk_has_no_stack() {
        let trunk = STACK
            .replace(r#""name":"b","current":true,"#, r#""name":"b","#)
            .replacen(r#"{"name":"main","#, r#"{"name":"main","current":true,"#, 1);

        let state = WorktreeState::new(
            "/r".into(),
            "/r".into(),
            Some("main".into()),
            "k".into(),
            &parse_spice_log(&trunk),
        );

        assert_eq!((state.stack, state.mrs), (Vec::<String>::new(), Vec::<u64>::new()));
    }

    #[test]
    fn parse_spice_log_skips_bad_lines() {
        let text = format!("not json\n{STACK}");

        let names: Vec<String> = parse_spice_log(&text).into_iter().map(|branch| branch.name).collect();

        assert_eq!(names, ["main", "a", "b"]);
    }
}
