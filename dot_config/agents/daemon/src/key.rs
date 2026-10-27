use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::paths::home;
use crate::platform::shasum12;

pub enum KeyMode {
    Hub,
    Stack,
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
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["rev-parse", "--show-toplevel"])
        .stderr(Stdio::inherit())
        .output()
        .map_err(|error| format!("git: {error}"))?;
    match output.status.success() {
        true => Ok(PathBuf::from(String::from_utf8_lossy(&output.stdout).trim_end())),
        false => Err(format!("not a git worktree: {}", repo.display())),
    }
}

/// The worktree hash keeps the key of a stack watch apart from the hub watch of the same repo.
pub fn stack_key(slug: &str, top: &Path) -> Result<String, String> {
    Ok(format!("{slug}-{}", shasum12(&top.to_string_lossy())?))
}

pub fn review_key(stack_key: &str, iid: u64) -> String {
    format!("{stack_key}-review-{iid}")
}

pub fn watch_key(repo: &Path, mode: &KeyMode) -> Result<String, String> {
    let slug = repo_slug(repo)?;
    match mode {
        KeyMode::Hub => Ok(slug),
        KeyMode::Stack => stack_key(&slug, &worktree_top(repo)?),
        KeyMode::Review { iid } => Ok(review_key(&stack_key(&slug, &worktree_top(repo)?)?, *iid)),
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
        let stack = format!("app-{}", hash(&repo));
        assert_eq!(watch_key(&repo, &KeyMode::Hub).unwrap(), "app");
        assert_eq!(watch_key(&repo, &KeyMode::Stack).unwrap(), stack);
        assert_eq!(
            watch_key(&repo, &KeyMode::Review { iid: 5 }).unwrap(),
            format!("{stack}-review-5")
        );
        std::fs::remove_dir_all(repo.parent().unwrap()).unwrap();
    }
}
