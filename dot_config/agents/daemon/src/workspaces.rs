//! The Rust code outside `ScriptWorkspaces` runs no workspace script.

use std::path::{Path, PathBuf};

use crate::paths::home;

pub trait Workspaces: Send + Sync {
    /// Opens the board pane next to the current pane, if none is open. The pane runs
    /// `watchd board --repo <repo>` with the board args.
    fn open_board(&self, repo: &Path, board_args: &[String]) -> Result<(), String>;

    /// Starts an agent on the existing branch, in its own worktree workspace.
    fn start_agent(&self, repo: &Path, start: &AgentStart) -> Result<(), StartError>;

    /// The branch of each agent in the linked worktrees of the repo.
    fn agent_branches(&self, repo: &Path) -> Result<Vec<String>, String>;
}

pub struct AgentStart {
    pub title: String,
    pub branch: String,
    /// The first prompt of the agent runs this skill on the URL.
    pub skill: String,
    pub url: String,
}

#[derive(Debug, PartialEq)]
pub enum StartError {
    /// An agent works on the branch already.
    Busy,
    Failed(String),
}

/// The `work-start.sh` exit code of a branch that is open in a workspace already.
const BUSY_EXIT_CODE: i32 = 5;

/// Runs the scripts in the skill folders under `scripts`.
pub struct ScriptWorkspaces {
    pub scripts: PathBuf,
}

impl ScriptWorkspaces {
    /// Gives the stdout text, or on failure the exit code (none for a signal or a failed spawn)
    /// with the stderr text.
    fn run_skill_script(
        &self,
        script: &str,
        args: &[&std::ffi::OsStr],
        folder: &Path,
    ) -> Result<String, (Option<i32>, String)> {
        let path = self.scripts.join(script);
        let mut command = std::process::Command::new(&path);
        // The daemon keeps the multiplexer variables of the pane that started it. bin/mux.sh
        // finds the multiplexer of the repo with MUX_REPO instead.
        for (name, _) in std::env::vars_os() {
            let text = name.to_string_lossy();
            if text.starts_with("HERDR_") || text.starts_with("REX_") {
                command.env_remove(&name);
            }
        }
        let output = command
            .env("MUX_REPO", folder)
            .args(args)
            .current_dir(folder)
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|error| (None, format!("{}: {error}", path.display())))?;
        match output.status.success() {
            true => Ok(String::from_utf8_lossy(&output.stdout).to_string()),
            false => Err((
                output.status.code(),
                String::from_utf8_lossy(&output.stderr).trim_end().to_string(),
            )),
        }
    }
}

impl Workspaces for ScriptWorkspaces {
    fn open_board(&self, repo: &Path, board_args: &[String]) -> Result<(), String> {
        let mut args: Vec<&std::ffi::OsStr> = vec!["--repo".as_ref(), repo.as_os_str()];
        if !board_args.is_empty() {
            args.push("--".as_ref());
            args.extend(board_args.iter().map(std::ffi::OsStr::new));
        }
        self.run_skill_script("work/board-pane.sh", &args, repo)
            .map(|_| ())
            .map_err(|(_, text)| text)
    }

    fn start_agent(&self, repo: &Path, start: &AgentStart) -> Result<(), StartError> {
        let args = [
            start.title.as_ref(),
            "--branch".as_ref(),
            start.branch.as_ref(),
            "--no-track".as_ref(),
            "--skill".as_ref(),
            start.skill.as_ref(),
            start.url.as_ref(),
        ];
        self.run_skill_script("work/work-start.sh", &args, repo)
            .map(|_| ())
            .map_err(|(code, text)| match code {
                Some(BUSY_EXIT_CODE) => StartError::Busy,
                _ => StartError::Failed(text),
            })
    }

    fn agent_branches(&self, repo: &Path) -> Result<Vec<String>, String> {
        let text = self
            .run_skill_script("hub/hub-status.sh", &["--repo".as_ref(), repo.as_os_str()], repo)
            .map_err(|(_, text)| text)?;
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
    fn open_board(&self, repo: &Path, board_args: &[String]) -> Result<(), String> {
        let args: String = board_args.iter().map(|arg| format!(" {arg}")).collect();
        self.call(&format!("open_board {}{args}", repo.display()));
        Ok(())
    }

    /// The file `<dir>/start` gives the result: `ok` (also with no file), `busy`, or an error text.
    fn start_agent(&self, _repo: &Path, start: &AgentStart) -> Result<(), StartError> {
        self.call(&format!("start_agent {} {} {}", start.branch, start.skill, start.url));
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
    let scripts = std::env::var_os("WATCHD_SCRIPTS")
        .filter(|value| !value.is_empty())
        .map_or_else(|| home().join(".config/agents/skills"), PathBuf::from);
    Box::new(ScriptWorkspaces { scripts })
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    /// The `work/work-start.sh` of the folder writes its arguments to `<folder>/args`, writes the
    /// stderr text, and exits with the code.
    fn scripts(name: &str, code: i32, stderr: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("watchd-workspaces-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(folder.join("work")).unwrap();
        let script = folder.join("work/work-start.sh");
        let text = format!("#!/bin/sh\necho \"$@\" >\"$(dirname \"$0\")/../args\"\necho '{stderr}' >&2\nexit {code}\n");
        std::fs::write(&script, text).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        folder
    }

    #[test]
    fn a_busy_exit_code_is_busy_and_other_failures_are_failed() {
        let start = AgentStart {
            title: "Add foo".to_string(),
            branch: "ABC-1/foo".to_string(),
            skill: "review-pr".to_string(),
            url: "https://g/mr/5".to_string(),
        };
        let busy = scripts("busy", 5, "work-start: ABC-1/foo is open in workspace w1 already");
        let failed = scripts("failed", 1, "work-start: not a git repo: /x");

        let busy_result = ScriptWorkspaces { scripts: busy.clone() }.start_agent(&busy, &start);
        let failed_result = ScriptWorkspaces {
            scripts: failed.clone(),
        }
        .start_agent(&failed, &start);
        let args = std::fs::read_to_string(busy.join("args"));
        for folder in [&busy, &failed] {
            let _ = std::fs::remove_dir_all(folder);
        }

        assert_eq!(busy_result, Err(StartError::Busy));
        assert_eq!(
            failed_result,
            Err(StartError::Failed("work-start: not a git repo: /x".to_string()))
        );
        assert_eq!(
            args.unwrap(),
            "Add foo --branch ABC-1/foo --no-track --skill review-pr https://g/mr/5\n"
        );
    }

    #[test]
    fn a_script_gets_the_repo_and_no_multiplexer_variables_of_the_daemon() {
        let folder = std::env::temp_dir().join(format!("watchd-workspaces-{}-env", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(folder.join("work")).unwrap();
        let script = folder.join("work/board-pane.sh");
        std::fs::write(&script, "#!/bin/sh\nenv >\"$(dirname \"$0\")/../env\"\n").unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

        let result = ScriptWorkspaces { scripts: folder.clone() }.open_board(&folder, &[]);
        let env = std::fs::read_to_string(folder.join("env")).unwrap_or_default();
        let _ = std::fs::remove_dir_all(&folder);

        assert_eq!(result, Ok(()));
        assert!(env.lines().any(|line| line == format!("MUX_REPO={}", folder.display())));
        let leaked: Vec<&str> = env
            .lines()
            .filter(|line| line.starts_with("HERDR_") || line.starts_with("REX_"))
            .collect();
        assert_eq!(leaked, Vec::<&str>::new());
    }
}
