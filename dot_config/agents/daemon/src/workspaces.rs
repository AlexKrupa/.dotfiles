//! The Rust code outside `HerdrWorkspaces` makes no herdr calls.

use std::path::Path;
#[cfg(feature = "test-support")]
use std::path::PathBuf;

use crate::paths::home;

pub trait Workspaces: Send + Sync {
    /// Opens the board pane next to the current pane, if none is open.
    fn open_board(&self, repo: &Path) -> Result<(), String>;

    /// Starts an agent on the existing branch, in its own worktree workspace.
    fn start_agent(&self, repo: &Path, start: &AgentStart) -> Result<(), StartError>;

    /// The branch of each agent in the linked worktrees of the repo.
    fn agent_branches(&self, repo: &Path) -> Result<Vec<String>, String>;
}

pub struct AgentStart {
    pub title: String,
    pub branch: String,
    pub prompt: String,
}

#[derive(Debug, PartialEq)]
pub enum StartError {
    /// An agent works on the branch already.
    Busy,
    Failed(String),
}

pub struct HerdrWorkspaces;

/// Gives the stdout text, or the stderr text on failure.
fn run_skill_script(script: &str, args: &[&std::ffi::OsStr], folder: &Path, stdin: &str) -> Result<String, String> {
    use std::io::Write;
    let path = home().join(".claude/skills").join(script);
    let failed = |error: std::io::Error| format!("{}: {error}", path.display());
    let mut child = std::process::Command::new(&path)
        .args(args)
        .current_dir(folder)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(failed)?;
    if let Some(mut input) = child.stdin.take() {
        input.write_all(stdin.as_bytes()).map_err(failed)?;
    }
    let output = child.wait_with_output().map_err(failed)?;
    match output.status.success() {
        true => Ok(String::from_utf8_lossy(&output.stdout).to_string()),
        false => Err(String::from_utf8_lossy(&output.stderr).trim_end().to_string()),
    }
}

impl Workspaces for HerdrWorkspaces {
    fn open_board(&self, repo: &Path) -> Result<(), String> {
        run_skill_script("hub/hub-board.sh", &["--repo".as_ref(), repo.as_os_str()], repo, "").map(|_| ())
    }

    fn start_agent(&self, repo: &Path, start: &AgentStart) -> Result<(), StartError> {
        let args = [
            start.title.as_ref(),
            "--branch".as_ref(),
            start.branch.as_ref(),
            "--no-track".as_ref(),
        ];
        run_skill_script("work/work-start.sh", &args, repo, &start.prompt)
            .map(|_| ())
            .map_err(|text| match text.contains("is open in herdr workspace") {
                true => StartError::Busy,
                false => StartError::Failed(text),
            })
    }

    fn agent_branches(&self, repo: &Path) -> Result<Vec<String>, String> {
        let text = run_skill_script("hub/hub-status.sh", &["--repo".as_ref(), repo.as_os_str()], repo, "")?;
        // The fields: pane id, status, branch, cwd, title.
        Ok(text
            .lines()
            .filter_map(|line| line.split('\t').nth(2))
            .map(str::to_string)
            .collect())
    }
}

/// The workspaces of the tests: each call adds one line to `<dir>/calls`.
#[cfg(feature = "test-support")]
pub struct FakeWorkspaces {
    pub dir: PathBuf,
}

#[cfg(feature = "test-support")]
impl FakeWorkspaces {
    fn call(&self, line: &str) {
        let log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join("calls"));
        if let Ok(mut log) = log {
            let _ = std::io::Write::write_all(&mut log, format!("{line}\n").as_bytes());
        }
    }
}

#[cfg(feature = "test-support")]
impl Workspaces for FakeWorkspaces {
    fn open_board(&self, repo: &Path) -> Result<(), String> {
        self.call(&format!("open_board {}", repo.display()));
        Ok(())
    }

    /// The file `<dir>/start` gives the result: `ok` (also with no file), `busy`, or an error text.
    fn start_agent(&self, _repo: &Path, start: &AgentStart) -> Result<(), StartError> {
        self.call(&format!("start_agent {} {}", start.branch, start.prompt));
        let result = std::fs::read_to_string(self.dir.join("start")).unwrap_or_default();
        match result.trim() {
            "" | "ok" => Ok(()),
            "busy" => Err(StartError::Busy),
            text => Err(StartError::Failed(text.to_string())),
        }
    }

    /// The file `<dir>/branches` gives one branch on each line.
    fn agent_branches(&self, repo: &Path) -> Result<Vec<String>, String> {
        self.call(&format!("agent_branches {}", repo.display()));
        let text = std::fs::read_to_string(self.dir.join("branches")).unwrap_or_default();
        Ok(text.lines().map(str::to_string).collect())
    }
}

pub fn workspaces_of() -> Box<dyn Workspaces> {
    #[cfg(feature = "test-support")]
    if let Some(dir) = std::env::var_os("WATCHD_FAKE_WORKSPACES").filter(|value| !value.is_empty()) {
        return Box::new(FakeWorkspaces { dir: dir.into() });
    }
    Box::new(HerdrWorkspaces)
}
