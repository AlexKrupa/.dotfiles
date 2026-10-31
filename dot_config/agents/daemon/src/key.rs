use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::local::git;
use crate::paths::home;
use crate::platform::shasum12;

pub enum KeyMode {
    Hub,
    Author,
    Review { iid: u64 },
}

pub fn repo_slug(repo: &Path) -> Result<String, String> {
    let script = home().join(".config/agents/bin/repo-slug.sh");
    let output = Command::new(&script)
        .current_dir(repo)
        .stderr(Stdio::inherit())
        .output()
        .map_err(|error| format!("{}: {error}", script.display()))?;
    match output.status.success() {
        true => Ok(String::from_utf8_lossy(&output.stdout).trim_end().to_string()),
        false => Err(format!("{} failed in {}", script.display(), repo.display())),
    }
}

pub fn worktree_top(repo: &Path) -> Result<PathBuf, String> {
    let top =
        git(repo, &["rev-parse", "--show-toplevel"]).map_err(|_| format!("not a git worktree: {}", repo.display()))?;
    Ok(PathBuf::from(top.trim_end()))
}

/// The worktree hash keeps the key of an author watch apart from the hub watch of the same repo.
pub fn author_key(slug: &str, top: &Path) -> String {
    format!("{slug}-{}", shasum12(&top.to_string_lossy()))
}

pub fn review_key(author: &str, iid: u64) -> String {
    format!("{author}-review-{iid}")
}

pub fn digits(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit())
}

pub fn is_worktree_key(key: &str) -> bool {
    let key = match key.rsplit_once("-review-") {
        Some((front, iid)) if digits(iid) => front,
        _ => key,
    };
    key.len() > 13
        && key.as_bytes()[key.len() - 13] == b'-'
        && key[key.len() - 12..]
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

pub fn watch_key(repo: &Path, mode: &KeyMode) -> Result<String, String> {
    let slug = repo_slug(repo)?;
    match mode {
        KeyMode::Hub => Ok(slug),
        KeyMode::Author => Ok(author_key(&slug, &worktree_top(repo)?)),
        KeyMode::Review { iid } => Ok(review_key(&author_key(&slug, &worktree_top(repo)?), *iid)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::process::Command;

    fn temp_repo(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("watchd-key-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let repo = dir.join("app");
        std::fs::create_dir_all(&repo).unwrap();
        let git = |args: &[&str]| {
            assert!(
                Command::new("git")
                    .arg("-C")
                    .arg(&repo)
                    .args(args)
                    .status()
                    .unwrap()
                    .success()
            );
        };
        git(&["init", "-q"]);
        git(&["remote", "add", "origin", "https://gitlab.example.com/group/app.git"]);
        repo.canonicalize().unwrap()
    }

    fn hash(path: &Path) -> String {
        let mut child = Command::new("shasum")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        std::io::Write::write_all(child.stdin.as_mut().unwrap(), path.to_str().unwrap().as_bytes()).unwrap();
        String::from_utf8(child.wait_with_output().unwrap().stdout).unwrap()[..12].to_string()
    }

    #[test]
    fn watch_key_is_the_slug_then_the_worktree_hash_then_the_reviewed_mr() {
        let repo = temp_repo("match");
        let author = format!("app-{}", hash(&repo));
        assert_eq!(watch_key(&repo, &KeyMode::Hub).unwrap(), "app");
        assert_eq!(watch_key(&repo, &KeyMode::Author).unwrap(), author);
        assert_eq!(
            watch_key(&repo, &KeyMode::Review { iid: 5 }).unwrap(),
            format!("{author}-review-5")
        );
        std::fs::remove_dir_all(repo.parent().unwrap()).unwrap();
    }

    #[test]
    fn worktree_keys_have_the_hash_of_the_worktree() {
        assert!(is_worktree_key("app-0123456789ab"));
        assert!(is_worktree_key("app-0123456789ab-review-5"));
        assert!(!is_worktree_key("app"));
        assert!(!is_worktree_key("my-app"));
        assert!(!is_worktree_key("app-0123456789ab-review-"));
    }
}
