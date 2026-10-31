//! The local git state of the managed repos: thin `git` and `git-spice` calls and pure parsers.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::core::worktrees::{SpiceBranch, current_stack, parse_spice_log};
use crate::nap::is_network_error;

/// A detached or bare entry has no branch.
#[derive(Clone, Debug, PartialEq)]
pub struct Worktree {
    pub path: PathBuf,
    pub head: Option<String>,
    pub branch: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SharedRefs {
    pub spice: Option<String>,
    pub default_branch: Option<String>,
    pub origin_default: Option<String>,
}

pub fn git(folder: &Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(folder)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("git: {error}"))?;
    let stderr = String::from_utf8_lossy(&output.stderr);
    match output.status.success() {
        true => Ok(String::from_utf8_lossy(&output.stdout).to_string()),
        false => Err(format!("git {}: {}", args.join(" "), stderr.trim_end())),
    }
}

pub fn parse_worktree_list(text: &str) -> Vec<Worktree> {
    let mut worktrees: Vec<Worktree> = Vec::new();
    for line in text.lines() {
        if let Some(path) = line.strip_prefix("worktree ") {
            worktrees.push(Worktree {
                path: PathBuf::from(path),
                head: None,
                branch: None,
            });
            continue;
        }
        let Some(worktree) = worktrees.last_mut() else {
            continue;
        };
        if let Some(head) = line.strip_prefix("HEAD ") {
            worktree.head = Some(head.to_string());
        } else if let Some(branch) = line.strip_prefix("branch ") {
            worktree.branch = Some(branch.strip_prefix("refs/heads/").unwrap_or(branch).to_string());
        }
    }
    worktrees
}

pub fn list_worktrees(repo: &Path) -> Result<Vec<Worktree>, String> {
    let text = git(repo, &["worktree", "list", "--porcelain"])?;
    Ok(parse_worktree_list(&text)
        .into_iter()
        .filter_map(|worktree| {
            let path = std::fs::canonicalize(&worktree.path).ok()?;
            Some(Worktree { path, ..worktree })
        })
        .collect())
}

/// The main worktree is the first entry of the list, also when the folder is in a linked worktree.
pub fn repo_of(folder: &Path) -> Option<PathBuf> {
    let worktrees = list_worktrees(folder).ok()?;
    worktrees.into_iter().next().map(|worktree| worktree.path)
}

/// A new HEAD, branch, git-spice data, or `origin/HEAD` changes the key.
pub fn worktree_key(worktree: &Worktree, refs: &SharedRefs) -> String {
    let text = |value: &Option<String>| value.clone().unwrap_or_default();
    format!(
        "{} {} {} {}",
        text(&worktree.head),
        text(&worktree.branch),
        text(&refs.spice),
        text(&refs.origin_default)
    )
}

pub fn shared_refs(repo: &Path) -> SharedRefs {
    let format = "--format=%(refname) %(objectname) %(symref)";
    let text = git(
        repo,
        &["for-each-ref", format, "refs/spice/data", "refs/remotes/origin/HEAD"],
    )
    .unwrap_or_default();
    let mut refs = SharedRefs::default();
    for line in text.lines() {
        let mut fields = line.split(' ');
        let (Some(name), Some(object)) = (fields.next(), fields.next()) else {
            continue;
        };
        match name {
            "refs/spice/data" => refs.spice = Some(object.to_string()),
            "refs/remotes/origin/HEAD" => {
                refs.origin_default = Some(object.to_string());
                refs.default_branch = fields
                    .next()
                    .and_then(|target| target.strip_prefix("refs/remotes/origin/"))
                    .map(str::to_string);
            }
            _ => {}
        }
    }
    refs
}

#[derive(Debug)]
pub enum FetchError {
    Network(String),
    Other(String),
}

/// A connection that a system sleep broke can hang for hours.
pub const FETCH_TIMEOUT: Duration = Duration::from_secs(120);

/// No prompt for credentials: the daemon has no terminal. At the timeout, the fetch and its child
/// processes stop.
pub async fn fetch(repo: &Path, branch: &str, timeout: Duration) -> Result<(), FetchError> {
    let child = tokio::process::Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["fetch", "-q", "origin", branch])
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| FetchError::Other(format!("git fetch: {error}")))?;
    let group = child.id().and_then(|pid| libc::pid_t::try_from(pid).ok());
    let output = match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(output) => output.map_err(|error| FetchError::Other(format!("git fetch: {error}")))?,
        Err(_) => {
            if let Some(group) = group {
                // SAFETY: kill with a negative PID sends the signal to the process group of the fetch.
                unsafe { libc::kill(-group, libc::SIGKILL) };
            }
            return Err(FetchError::Network(format!(
                "git fetch: timed out after {} s",
                timeout.as_secs()
            )));
        }
    };
    let text = String::from_utf8_lossy(&output.stderr).trim_end().replace('\n', " ");
    match (output.status.success(), is_network_error(&text)) {
        (true, _) => Ok(()),
        (false, true) => Err(FetchError::Network(format!("git fetch: {text}"))),
        (false, false) => Err(FetchError::Other(format!("git fetch: {text}"))),
    }
}

#[derive(Debug, PartialEq)]
pub enum Blocked {
    OtherBranch(String),
    Changes,
    NoFastForward,
}

impl Blocked {
    pub fn text(&self, default: &str) -> String {
        match self {
            Blocked::OtherBranch(branch) => format!("the checkout is on {branch}, not {default}"),
            Blocked::Changes => "the checkout has changes in tracked files".to_string(),
            Blocked::NoFastForward => format!("cannot fast-forward {default} to origin/{default}"),
        }
    }
}

fn is_ancestor(folder: &Path, ancestor: &str, commit: &str) -> bool {
    git(folder, &["merge-base", "--is-ancestor", ancestor, commit]).is_ok()
}

/// Returns false if the checkout has all commits of `origin/<branch>` already.
pub fn fast_forward(main: &Path, branch: &str) -> Result<bool, Blocked> {
    let current = git(main, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
    if current.trim_end() != branch {
        return Err(Blocked::OtherBranch(current.trim_end().to_string()));
    }
    let remote = format!("origin/{branch}");
    if is_ancestor(main, &remote, "HEAD") {
        return Ok(false);
    }
    if !is_ancestor(main, "HEAD", &remote) {
        return Err(Blocked::NoFastForward);
    }
    // The refresh makes a file with a new time but the same content count as unchanged.
    let _ = git(main, &["update-index", "-q", "--refresh"]);
    if git(main, &["diff-index", "--quiet", "HEAD"]).is_err() {
        return Err(Blocked::Changes);
    }
    match git(main, &["merge", "-q", "--ff-only", &remote]) {
        Ok(_) => Ok(true),
        Err(_) => Err(Blocked::NoFastForward),
    }
}

/// With `merge_base`, only the commits of `top` that are not in `merge_base` count.
pub fn conflict(worktree: &Path, default: &str, merge_base: Option<&str>, top: &str) -> Result<Vec<String>, String> {
    let base = format!("origin/{default}");
    let output = Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["merge-tree", "--write-tree", "--name-only", "--no-messages"])
        .args(merge_base.map(|commit| format!("--merge-base={commit}")))
        .args([&base, top])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("git merge-tree: {error}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    match output.status.code() {
        Some(0) => Ok(Vec::new()),
        // The first line is the tree.
        Some(1) => Ok(stdout
            .lines()
            .skip(1)
            .filter(|line| !line.is_empty())
            .map(str::to_string)
            .collect()),
        _ => Err(format!(
            "git merge-tree {base} {top}: {}",
            String::from_utf8_lossy(&output.stderr).trim_end()
        )),
    }
}

pub fn spice_log(worktree: &Path) -> Result<Vec<SpiceBranch>, String> {
    let output = Command::new("git-spice")
        .args(["log", "short", "--json", "--no-cr-status", "--no-cr-comments"])
        .current_dir(worktree)
        .stdin(Stdio::null())
        .output();
    let output = match output {
        Ok(output) => output,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err("git-spice is not installed".to_string());
        }
        Err(error) => return Err(format!("git-spice: {error}")),
    };
    match output.status.success() {
        true => Ok(current_stack(&parse_spice_log(&String::from_utf8_lossy(
            &output.stdout,
        )))),
        false => Err(format!(
            "git-spice log: {}",
            String::from_utf8_lossy(&output.stderr).trim_end()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The global git configuration of the user can sign commits, which fails with no agent.
    fn git(folder: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(folder)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "T")
            .env("GIT_AUTHOR_EMAIL", "t@example.com")
            .env("GIT_COMMITTER_NAME", "T")
            .env("GIT_COMMITTER_EMAIL", "t@example.com")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim_end().to_string()
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("watchd-local-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn repo_with_commit(dir: &Path) -> PathBuf {
        let repo = dir.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("f"), "one\n").unwrap();
        git(&repo, &["add", "f"]);
        git(&repo, &["commit", "-q", "-m", "one"]);
        repo
    }

    fn origin_and_clones(name: &str) -> (PathBuf, PathBuf) {
        let dir = scratch(name);
        git(&dir, &["init", "-q", "--bare", "-b", "main", "origin.git"]);
        git(&dir, &["clone", "-q", "origin.git", "pusher"]);
        let pusher = dir.join("pusher");
        std::fs::write(pusher.join("f"), "one\n").unwrap();
        git(&pusher, &["add", "f"]);
        git(&pusher, &["commit", "-q", "-m", "one"]);
        git(&pusher, &["push", "-q", "origin", "main"]);
        git(&dir, &["clone", "-q", "origin.git", "clone"]);
        (pusher, dir.join("clone"))
    }

    fn fetch_now(repo: &Path, branch: &str, timeout: Duration) -> Result<(), FetchError> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(fetch(repo, branch, timeout))
    }

    fn push(pusher: &Path, file: &str) {
        std::fs::write(pusher.join(file), "pushed\n").unwrap();
        git(pusher, &["add", file]);
        git(pusher, &["commit", "-q", "-m", file]);
        git(pusher, &["push", "-q", "origin", "main"]);
    }

    #[test]
    fn fast_forward_moves_main_to_origin() {
        let (pusher, clone) = origin_and_clones("ff");
        push(&pusher, "g");

        fetch_now(&clone, "main", FETCH_TIMEOUT).unwrap();

        assert_eq!(fast_forward(&clone, "main"), Ok(true));
        assert_eq!(
            git(&clone, &["rev-parse", "HEAD"]),
            git(&pusher, &["rev-parse", "HEAD"])
        );
        assert_eq!(fast_forward(&clone, "main"), Ok(false));
    }

    #[test]
    fn fast_forward_is_blocked_on_another_branch() {
        let (pusher, clone) = origin_and_clones("ff-branch");
        git(&clone, &["switch", "-q", "-c", "other"]);
        push(&pusher, "g");
        fetch_now(&clone, "main", FETCH_TIMEOUT).unwrap();

        let blocked = fast_forward(&clone, "main").unwrap_err();

        assert_eq!(blocked.text("main"), "the checkout is on other, not main");
    }

    #[test]
    fn fast_forward_is_blocked_with_changes_in_tracked_files() {
        let (pusher, clone) = origin_and_clones("ff-changes");
        std::fs::write(clone.join("f"), "local\n").unwrap();
        push(&pusher, "g");
        fetch_now(&clone, "main", FETCH_TIMEOUT).unwrap();

        let blocked = fast_forward(&clone, "main").unwrap_err();

        assert_eq!(blocked.text("main"), "the checkout has changes in tracked files");
    }

    #[test]
    fn fast_forward_is_blocked_when_main_diverged() {
        let (pusher, clone) = origin_and_clones("ff-diverged");
        std::fs::write(clone.join("h"), "local\n").unwrap();
        git(&clone, &["add", "h"]);
        git(&clone, &["commit", "-q", "-m", "local"]);
        push(&pusher, "g");
        fetch_now(&clone, "main", FETCH_TIMEOUT).unwrap();

        let blocked = fast_forward(&clone, "main").unwrap_err();

        assert_eq!(blocked.text("main"), "cannot fast-forward main to origin/main");
    }

    #[test]
    fn conflict_lists_the_conflicting_files() {
        let (pusher, clone) = origin_and_clones("conflict");
        git(&clone, &["switch", "-q", "-c", "b"]);
        std::fs::write(clone.join("f"), "branch\n").unwrap();
        git(&clone, &["commit", "-q", "-am", "branch"]);
        git(&clone, &["switch", "-q", "-c", "c", "main"]);
        std::fs::write(clone.join("g"), "other file\n").unwrap();
        git(&clone, &["add", "g"]);
        git(&clone, &["commit", "-q", "-m", "other file"]);
        std::fs::write(pusher.join("f"), "main\n").unwrap();
        git(&pusher, &["commit", "-q", "-am", "main"]);
        git(&pusher, &["push", "-q", "origin", "main"]);
        fetch_now(&clone, "main", FETCH_TIMEOUT).unwrap();

        assert_eq!(conflict(&clone, "main", None, "b"), Ok(vec!["f".to_string()]));
        assert_eq!(conflict(&clone, "main", None, "c"), Ok(Vec::new()));
    }

    fn commit_f(folder: &Path, text: &str) {
        std::fs::write(folder.join("f"), text).unwrap();
        git(folder, &["commit", "-q", "-am", text]);
    }

    #[test]
    fn conflict_leaves_out_the_commits_of_the_merge_base() {
        let (pusher, clone) = origin_and_clones("conflict-merge-base");
        commit_f(&pusher, "1\n2\n3\n4\n5\n");
        git(&pusher, &["push", "-q", "origin", "main"]);
        git(&clone, &["pull", "-q"]);
        git(&clone, &["switch", "-q", "-c", "lower"]);
        commit_f(&clone, "1\nB\n3\n4\n5\n");
        git(&clone, &["switch", "-q", "-c", "upper"]);
        commit_f(&clone, "1\nB\n3\n4\nE\n");
        commit_f(&pusher, "A\n2\n3\n4\n5\n");
        commit_f(&pusher, "A\nB\n3\n4\n5\n");
        git(&pusher, &["push", "-q", "origin", "main"]);
        fetch_now(&clone, "main", FETCH_TIMEOUT).unwrap();

        assert_eq!(conflict(&clone, "main", None, "upper"), Ok(vec!["f".to_string()]));
        assert_eq!(conflict(&clone, "main", Some("lower"), "upper"), Ok(Vec::new()));
    }

    #[test]
    fn fetch_reports_a_network_error() {
        let (_, clone) = origin_and_clones("fetch-network");
        git(
            &clone,
            &["remote", "set-url", "origin", "https://unreachable.invalid/x.git"],
        );

        let result = fetch_now(&clone, "main", FETCH_TIMEOUT);

        assert!(matches!(result, Err(FetchError::Network(_))), "{result:?}");
    }

    #[test]
    fn fetch_stops_at_the_timeout() {
        let (_, clone) = origin_and_clones("fetch-timeout");
        let hang = clone.parent().unwrap().join("hang");
        std::fs::write(&hang, "#!/bin/sh\nsleep 20\n").unwrap();
        std::fs::set_permissions(&hang, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        git(&clone, &["config", "remote.origin.uploadpack", hang.to_str().unwrap()]);
        let start = std::time::Instant::now();

        let result = fetch_now(&clone, "main", Duration::from_secs(1));

        assert!(start.elapsed() < Duration::from_secs(5), "{:?}", start.elapsed());
        assert!(
            matches!(&result, Err(FetchError::Network(text)) if text.contains("timed out")),
            "{result:?}"
        );
    }

    #[test]
    fn parse_worktree_list_reads_branch_and_detached_entries() {
        let text = "worktree /r\nHEAD 1111\nbranch refs/heads/main\n\nworktree /r/.wt/a\nHEAD 2222\nbranch refs/heads/a\n\nworktree /r/.wt/d\nHEAD 3333\ndetached\n\n";

        let worktrees = parse_worktree_list(text);

        let branches: Vec<Option<&str>> = worktrees.iter().map(|worktree| worktree.branch.as_deref()).collect();
        assert_eq!(branches, [Some("main"), Some("a"), None]);
        assert_eq!(worktrees[1].path, PathBuf::from("/r/.wt/a"));
        assert_eq!(worktrees[2].head.as_deref(), Some("3333"));
    }

    #[test]
    fn shared_refs_reads_spice_data_and_the_default_branch_of_origin() {
        let dir = scratch("shared-refs");
        let repo = repo_with_commit(&dir);
        let head = git(&repo, &["rev-parse", "HEAD"]);
        assert_eq!(shared_refs(&repo), SharedRefs::default());

        git(&repo, &["update-ref", "refs/remotes/origin/dev/x", "HEAD"]);
        git(
            &repo,
            &["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/dev/x"],
        );
        git(&repo, &["update-ref", "refs/spice/data", "HEAD"]);

        let expected = SharedRefs {
            spice: Some(head.clone()),
            default_branch: Some("dev/x".to_string()),
            origin_default: Some(head),
        };
        assert_eq!(shared_refs(&repo), expected);
    }

    #[test]
    fn repo_of_gives_the_main_worktree_for_a_linked_worktree() {
        let dir = scratch("repo-of");
        let repo = repo_with_commit(&dir);
        git(&repo, &["worktree", "add", "-q", "../wt", "-b", "a"]);
        std::fs::create_dir_all(dir.join("wt/sub")).unwrap();
        let outside = dir.join("outside");
        std::fs::create_dir_all(&outside).unwrap();

        assert_eq!(repo_of(&dir.join("wt/sub")), Some(repo.canonicalize().unwrap()));
        assert_eq!(repo_of(&outside), None);
    }
}
