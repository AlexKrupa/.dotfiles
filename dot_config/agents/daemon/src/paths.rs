use std::path::{Path, PathBuf};

use crate::local::git;
use crate::platform::shasum12;

#[derive(Clone)]
pub struct StateDirs {
    pub watchd: PathBuf,
    pub engine: PathBuf,
}

/// The state folders of a client, and if the client can start a daemon.
pub struct ClientDirs {
    pub dirs: StateDirs,
    pub start: bool,
}

impl StateDirs {
    pub fn from_env() -> StateDirs {
        let base = match std::env::var_os("XDG_STATE_HOME") {
            Some(dir) if !dir.is_empty() => PathBuf::from(dir),
            _ => home().join(".local/state"),
        };
        StateDirs::from_base(&base)
    }

    fn from_base(base: &Path) -> StateDirs {
        StateDirs {
            watchd: base.join("watchd"),
            engine: base.join("watch-gitlab"),
        }
    }

    /// A repo with the git configuration key `watchd.stateHome` has its own daemon. A client
    /// there starts no daemon, because its binary can have a different engine.
    pub fn for_client(folder: &Path) -> ClientDirs {
        let value = git(folder, &["config", "--type=path", "--get", "watchd.stateHome"]).unwrap_or_default();
        match value.trim_end() {
            "" => ClientDirs {
                dirs: StateDirs::from_env(),
                start: true,
            },
            base => ClientDirs {
                dirs: StateDirs::from_base(Path::new(base)),
                start: false,
            },
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

    /// The report fields of the router rows in the inbox, for the next report of the model.
    pub fn routing(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("inbox/{key}.routing"))
    }

    pub fn items(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("items/{key}.json"))
    }

    /// The retry count of each failed job, as `<pipeline id>:<job name>`.
    pub fn retries(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("items/{key}.retries"))
    }

    /// The text of the newest report of the key, for `watchd board`.
    pub fn board(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("items/{key}.board"))
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
