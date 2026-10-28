use std::path::{Path, PathBuf};

use crate::platform::shasum12;

#[derive(Clone)]
pub struct StateDirs {
    pub watchd: PathBuf,
    pub engine: PathBuf,
}

impl StateDirs {
    pub fn from_env() -> StateDirs {
        let base = match std::env::var_os("XDG_STATE_HOME") {
            Some(dir) if !dir.is_empty() => PathBuf::from(dir),
            _ => home().join(".local/state"),
        };
        StateDirs {
            watchd: base.join("watchd"),
            engine: base.join("watch-gitlab"),
        }
    }

    pub fn engine_state(&self, key: &str) -> PathBuf {
        self.engine.join(format!("{key}.json"))
    }

    pub fn sub(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("subs/{key}.json"))
    }

    pub fn inbox(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("inbox/{key}.jsonl"))
    }

    /// The error text of an ended subscription, for the next client of its session.
    pub fn error(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("inbox/{key}.error"))
    }

    /// The session of the results of an ended subscription.
    pub fn owner(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("inbox/{key}.owner"))
    }

    pub fn last(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("inbox/{key}.last.jsonl"))
    }

    pub fn items(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("items/{key}.json"))
    }

    pub fn repos(&self) -> PathBuf {
        self.watchd.join("repos.json")
    }

    pub fn reviews(&self) -> PathBuf {
        self.watchd.join("reviews.json")
    }

    pub fn worktree(&self, path: &Path) -> Result<PathBuf, String> {
        let hash = shasum12(&path.to_string_lossy())?;
        Ok(self.watchd.join(format!("worktrees/{hash}.json")))
    }

    pub fn socket(&self) -> PathBuf {
        self.watchd.join("daemon.sock")
    }

    pub fn lock(&self) -> PathBuf {
        self.watchd.join("daemon.lock")
    }

    pub fn pid(&self) -> PathBuf {
        self.watchd.join("daemon.pid")
    }

    pub fn log(&self) -> PathBuf {
        self.watchd.join("watchd.log")
    }

    pub fn events(&self) -> PathBuf {
        self.watchd.join("events.jsonl")
    }
}

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}
