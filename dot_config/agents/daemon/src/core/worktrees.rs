//! The managed repos and the state of their worktrees, with no input or output.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// The main worktree of each repo that a client used, as a canonical path.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Repos {
    pub repos: Vec<PathBuf>,
}

/// The local state of one worktree. `key` is the git state at the last read of git-spice. `stack` has
/// the branches above the trunk, and `mrs` their MRs.
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
        }
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

/// The branches above the trunk.
pub fn stack_size(branches: &[SpiceBranch]) -> usize {
    branches.iter().filter(|branch| branch.down).count()
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

    const STACK: &str = r#"{"name":"main","ups":[{"name":"a"}]}
{"name":"a","down":{"name":"main"},"ups":[{"name":"b"}],"change":{"id":"!12","url":"u"}}
{"name":"b","current":true,"down":{"name":"a"}}
"#;

    #[test]
    fn parse_spice_log_reads_stack_and_change() {
        let branches = parse_spice_log(STACK);

        assert_eq!(stack_size(&branches), 2);
        assert_eq!(top_branches(&branches), ["b"]);
        let mrs: Vec<Option<u64>> = branches.iter().map(|branch| branch.mr).collect();
        assert_eq!(mrs, [None, Some(12), None]);
        assert_eq!(branches[1].ups, ["b"]);
    }

    #[test]
    fn parse_spice_log_with_one_branch_is_a_stack_of_one() {
        let branches = parse_spice_log(
            "{\"name\":\"main\",\"ups\":[{\"name\":\"a\"}]}\n{\"name\":\"a\",\"current\":true,\"down\":{\"name\":\"main\"}}\n",
        );

        assert_eq!(stack_size(&branches), 1);
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
