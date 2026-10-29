//! The managed repos and the state of their worktrees, with no input or output.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::core::subs::{Agent, Mode};
use crate::engine::state::{Need, OwnMr};
use crate::key::review_key;

/// The main worktree of each repo that a client used, with no symlinks in the path.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Repos {
    pub repos: Vec<PathBuf>,
}

/// `key` is the git state at the last read of git-spice. `stack` has the branches above the trunk.
/// `ended` has the merged or closed MRs, and `ended_branches` has their source branches.
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
    #[serde(default)]
    pub ended_branches: Vec<String>,
    #[serde(default)]
    pub lookup_branch: Option<String>,
    /// From `watchd kind` or the first agent.
    #[serde(default)]
    pub kind: Option<Kind>,
    /// The end of the last agent.
    #[serde(default)]
    pub stage: Option<Stage>,
    /// The needs-you values of the last check of each author or review key, for the sidebar with no
    /// live agent.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub needs: BTreeMap<String, Vec<Need>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Mine,
    Review,
    Bump,
    Debug,
    Hub,
}

impl Kind {
    pub fn parse(text: &str) -> Option<Kind> {
        match text {
            "mine" => Some(Kind::Mine),
            "review" => Some(Kind::Review),
            "bump" => Some(Kind::Bump),
            "debug" => Some(Kind::Debug),
            "hub" => Some(Kind::Hub),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Stage {
    Done,
    Stopped,
}

/// `repo` is the folder of the check: the main checkout for the hub and the own MRs, else the
/// worktree.
#[derive(Clone, Debug, PartialEq)]
pub struct Target {
    pub key: String,
    pub slug: String,
    pub mode: Mode,
    pub repo: PathBuf,
    pub mrs: Vec<u64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ReviewLink {
    pub worktree: PathBuf,
    pub iid: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Reviews {
    pub reviews: Vec<ReviewLink>,
}

pub fn lookup_branch<'a>(state: &'a WorktreeState, default: Option<&str>, reviews: &[ReviewLink]) -> Option<&'a str> {
    let branch = state.branch.as_deref()?;
    let linked = reviews.iter().any(|link| link.worktree == state.path);
    let done = state.lookup_branch.as_deref() == Some(branch);
    match state.mrs.is_empty() && !linked && !done && default != Some(branch) {
        true => Some(branch),
        false => None,
    }
}

/// An MR of an author or own target is in no other target.
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
    for agent in agents.iter().filter(|agent| agent.mode == Mode::Author) {
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
            list.push(target(key, Mode::Author, &folder, left));
        }
    }
    let own: Vec<u64> = own_mrs
        .iter()
        .map(|mr| mr.iid)
        .filter(|iid| !taken.contains(iid))
        .collect();
    if !own.is_empty() {
        list.push(target(format!("{slug}-own"), Mode::Author, repo, own));
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
        let stack = branches.iter().filter(|branch| branch.down.is_some());
        WorktreeState {
            path,
            repo,
            branch,
            key,
            stack: stack.clone().map(|branch| branch.name.clone()).collect(),
            mrs: stack.filter_map(|branch| branch.mr).collect(),
            conflict: Vec::new(),
            ended: Vec::new(),
            ended_branches: Vec::new(),
            lookup_branch: None,
            kind: None,
            stage: None,
            needs: BTreeMap::new(),
        }
    }

    /// The other fields have other writers. `read.ended_branches` has the ended branches of the
    /// conflict test.
    pub fn set_local(&mut self, read: WorktreeState) {
        self.repo = read.repo;
        self.branch = read.branch;
        // An MR that ended during the git calls makes the next local round test again.
        self.key = match self.ended_branches == read.ended_branches {
            true => read.key,
            false => String::new(),
        };
        self.stack = read.stack;
        self.mrs = read.mrs;
        self.conflict = read.conflict;
    }
}

/// With no live watch, a new task starts, and the end stage of an earlier watch does not apply to it.
pub fn set_kind(state: &mut WorktreeState, kind: Kind, live_watch: bool) {
    state.kind = Some(kind);
    if !live_watch {
        state.stage = None;
    }
}

/// `down` is the branch below, none for the trunk.
#[derive(Clone, Debug, PartialEq)]
pub struct SpiceBranch {
    pub name: String,
    pub current: bool,
    pub down: Option<String>,
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

pub fn parse_spice_log(text: &str) -> Vec<SpiceBranch> {
    text.lines()
        .filter_map(|line| serde_json::from_str::<SpiceLine>(line).ok())
        .map(|line| SpiceBranch {
            name: line.name,
            current: line.current,
            down: line.down.map(|down| down.name),
            ups: line.ups.into_iter().map(|up| up.name).collect(),
            mr: line.change.and_then(|change| change.id.strip_prefix('!')?.parse().ok()),
        })
        .collect()
}

/// git-spice lists all branches on the trunk, also the other stacks. The stack of the current
/// branch is the branches below it down to the trunk, and all branches above it. On the trunk, it is
/// empty.
pub fn current_stack(branches: &[SpiceBranch]) -> Vec<SpiceBranch> {
    let named = |name: &str| branches.iter().find(|branch| branch.name == name);
    let Some(current) = branches.iter().find(|branch| branch.current && branch.down.is_some()) else {
        return Vec::new();
    };
    let mut names = vec![current.name.clone()];
    let mut below = current.down.as_deref().and_then(named);
    while let Some(branch) = below.filter(|branch| branch.down.is_some()) {
        names.push(branch.name.clone());
        below = branch.down.as_deref().and_then(named);
    }
    let mut above = current.ups.clone();
    while let Some(name) = above.pop() {
        if let Some(branch) = named(&name) {
            above.extend(branch.ups.iter().cloned());
        }
        names.push(name);
    }
    branches
        .iter()
        .filter(|branch| names.contains(&branch.name))
        .cloned()
        .collect()
}

pub fn top_branches(branches: &[SpiceBranch]) -> Vec<String> {
    branches
        .iter()
        .filter(|branch| branch.down.is_some() && branch.ups.is_empty())
        .map(|branch| branch.name.clone())
        .collect()
}

/// One conflict test: the commits of `tip` that are not in `base`, against the default branch.
#[derive(Clone, Debug, PartialEq)]
pub struct ConflictTest {
    pub base: Option<String>,
    pub tip: String,
}

/// The top branch has the commits of all branches below it. The commits of an ended branch are
/// in the default branch, or are not for it: they leave the test.
pub fn conflict_tests(branch: Option<&str>, branches: &[SpiceBranch], ended: &[String]) -> Vec<ConflictTest> {
    let is_ended = |name: &str| ended.iter().any(|known| known == name);
    let stack: Vec<&SpiceBranch> = branches.iter().filter(|branch| branch.down.is_some()).collect();
    if stack.is_empty() {
        return branch
            .filter(|name| !is_ended(name))
            .map(|tip| ConflictTest {
                base: None,
                tip: tip.to_string(),
            })
            .into_iter()
            .collect();
    }
    let named = |name: &str| stack.iter().find(|branch| branch.name == name);
    let mut tests = Vec::new();
    for top in top_branches(branches) {
        let below = std::iter::successors(named(&top), |branch| branch.down.as_deref().and_then(named));
        let mut down = below
            .map(|branch| branch.name.as_str())
            .skip_while(|name| is_ended(name));
        let Some(tip) = down.next() else {
            continue;
        };
        let test = ConflictTest {
            base: down.find(|name| is_ended(name)).map(str::to_string),
            tip: tip.to_string(),
        };
        if !tests.contains(&test) {
            tests.push(test);
        }
    }
    tests
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
                row("app-/r/a", Mode::Author, "/r/a", &[12]),
                row("app-/r/b", Mode::Author, "/r/b", &[13, 14]),
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
                row("app-/r/b", Mode::Author, "/r/b", &[14])
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
                row("app-/r/a", Mode::Author, "/r/a", &[12]),
                row("app-own", Mode::Author, "/r", &[30]),
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
        }
    }

    #[test]
    fn targets_have_the_mrs_of_a_live_agent() {
        let worktrees = [worktree("/r/a", &[12], &[])];
        let agents = [
            agent("app-/r/a", Mode::Author, "/r/a", &[12, 13, 9]),
            agent("app-/r", Mode::Author, "/r", &[5]),
            agent("app-/r/c-review-20", Mode::Review, "/r/c", &[20]),
            agent("app", Mode::Hub, "/r", &[]),
        ];

        let targets = targets(Path::new("/r"), "app", &worktrees, &[], &[], &agents, &key_of);

        assert_eq!(
            summary(&targets),
            [
                row("app", Mode::Hub, "/r", &[]),
                row("app-/r/c-review-20", Mode::Review, "/r/c", &[20]),
                row("app-/r/a", Mode::Author, "/r/a", &[12, 13]),
                row("app-/r", Mode::Author, "/r", &[5]),
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

    fn conflict_test(base: Option<&str>, tip: &str) -> ConflictTest {
        ConflictTest {
            base: base.map(str::to_string),
            tip: tip.to_string(),
        }
    }

    #[test]
    fn conflict_tests_start_above_the_highest_ended_branch() {
        let branches = parse_spice_log(STACK);

        assert_eq!(conflict_tests(Some("b"), &branches, &[]), [conflict_test(None, "b")]);
        assert_eq!(
            conflict_tests(Some("b"), &branches, &["a".to_string()]),
            [conflict_test(Some("a"), "b")]
        );
    }

    #[test]
    fn conflict_tests_end_at_the_highest_open_branch() {
        let branches = parse_spice_log(STACK);

        assert_eq!(
            conflict_tests(Some("b"), &branches, &["b".to_string()]),
            [conflict_test(None, "a")]
        );
        assert_eq!(
            conflict_tests(Some("b"), &branches, &["a".to_string(), "b".to_string()]),
            []
        );
    }

    #[test]
    fn conflict_tests_with_no_stack_test_the_open_branch() {
        assert_eq!(conflict_tests(Some("b"), &[], &[]), [conflict_test(None, "b")]);
        assert_eq!(conflict_tests(Some("b"), &[], &["b".to_string()]), []);
        assert_eq!(conflict_tests(None, &[], &[]), []);
    }

    fn names(branches: &[SpiceBranch]) -> Vec<String> {
        branches.iter().map(|branch| branch.name.clone()).collect()
    }

    #[test]
    fn current_stack_leaves_out_the_other_stacks_of_the_trunk() {
        let log = r#"{"name":"a","current":true,"down":{"name":"main"}}
{"name":"b","down":{"name":"main"},"ups":[{"name":"c"}]}
{"name":"c","down":{"name":"b"}}
{"name":"main","ups":[{"name":"a"},{"name":"b"}]}
"#;

        let stack = current_stack(&parse_spice_log(log));

        assert_eq!(names(&stack), ["a"]);
        assert_eq!(top_branches(&stack), ["a"]);
    }

    #[test]
    fn current_stack_has_the_branches_below_and_above_the_current_branch() {
        let log = r#"{"name":"main","ups":[{"name":"a"},{"name":"x"}]}
{"name":"a","down":{"name":"main"},"ups":[{"name":"b"}]}
{"name":"b","current":true,"down":{"name":"a"},"ups":[{"name":"c"}]}
{"name":"c","down":{"name":"b"}}
{"name":"x","down":{"name":"main"}}
"#;

        assert_eq!(names(&current_stack(&parse_spice_log(log))), ["a", "b", "c"]);
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
            &current_stack(&parse_spice_log(&trunk)),
        );

        assert_eq!((state.stack, state.mrs), (Vec::<String>::new(), Vec::<u64>::new()));
    }

    #[test]
    fn parse_spice_log_skips_bad_lines() {
        let text = format!("not json\n{STACK}");

        let names: Vec<String> = parse_spice_log(&text).into_iter().map(|branch| branch.name).collect();

        assert_eq!(names, ["main", "a", "b"]);
    }

    #[test]
    fn kind_without_live_subscription_clears_the_stage() {
        let mut state = WorktreeState {
            kind: Some(Kind::Mine),
            stage: Some(Stage::Done),
            ..WorktreeState::new("/r".into(), "/r".into(), None, String::new(), &[])
        };
        set_kind(&mut state, Kind::Review, true);
        assert_eq!((state.kind, state.stage), (Some(Kind::Review), Some(Stage::Done)));
        set_kind(&mut state, Kind::Bump, false);
        assert_eq!((state.kind, state.stage), (Some(Kind::Bump), None));
    }
}
