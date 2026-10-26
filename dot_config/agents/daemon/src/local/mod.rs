//! The local git state of the managed repos: thin `git` and `git-spice` calls and pure parsers.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::core::worktrees::{SpiceBranch, parse_spice_log};

/// `branch` has no `refs/heads/` prefix. A detached or bare entry has no branch.
#[derive(Clone, Debug, PartialEq)]
pub struct Worktree {
    pub path: PathBuf,
    pub head: Option<String>,
    pub branch: Option<String>,
}

/// The refs that all worktrees of a repo share.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SharedRefs {
    pub spice: Option<String>,
    pub default_branch: Option<String>,
    pub origin_default: Option<String>,
}

fn git(folder: &Path, args: &[&str]) -> Result<String, String> {
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

/// Canonical paths. A worktree whose folder is gone is not in the list.
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

/// A change of the key is a change of the stack, of the branch, or of the default branch.
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

/// One call: the target of `origin/HEAD` gives the default branch.
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
        true => Ok(parse_spice_log(&String::from_utf8_lossy(&output.stdout))),
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
