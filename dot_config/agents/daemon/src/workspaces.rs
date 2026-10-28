//! The seam for herdr: agents and panes. The Rust code outside `HerdrWorkspaces` makes no herdr
//! calls.

#[cfg(feature = "test-support")]
use std::path::PathBuf;
use std::path::Path;

use crate::paths::home;

pub trait Workspaces: Send + Sync {
    /// Opens the board pane next to the current pane. An open board pane stays.
    fn open_board(&self, repo: &Path) -> Result<(), String>;
}

pub struct HerdrWorkspaces;

/// Runs a script of `~/.claude/skills`, and gives its stderr text on failure.
fn run_skill_script(script: &str, args: &[&std::ffi::OsStr]) -> Result<(), String> {
    let path = home().join(".claude/skills").join(script);
    let output = std::process::Command::new(&path)
        .args(args)
        .output()
        .map_err(|error| format!("{}: {error}", path.display()))?;
    match output.status.success() {
        true => Ok(()),
        false => Err(String::from_utf8_lossy(&output.stderr).trim_end().to_string()),
    }
}

impl Workspaces for HerdrWorkspaces {
    fn open_board(&self, repo: &Path) -> Result<(), String> {
        run_skill_script("hub/hub-board.sh", &["--repo".as_ref(), repo.as_os_str()])
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
}

pub fn workspaces_of() -> Box<dyn Workspaces> {
    #[cfg(feature = "test-support")]
    if let Some(dir) = std::env::var_os("WATCHD_FAKE_WORKSPACES").filter(|value| !value.is_empty()) {
        return Box::new(FakeWorkspaces { dir: dir.into() });
    }
    Box::new(HerdrWorkspaces)
}
