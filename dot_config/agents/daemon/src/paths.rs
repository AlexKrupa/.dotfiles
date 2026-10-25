use std::path::PathBuf;

/// The state folders and the file paths in them.
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
        StateDirs { watchd: base.join("watchd"), engine: base.join("watch-gitlab") }
    }

    pub fn engine_state(&self, key: &str) -> PathBuf {
        self.engine.join(format!("{key}.json"))
    }

    pub fn sub(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("subs/{key}.json"))
    }

    /// The events that wait for a client.
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

    /// The last delivery, for `report`.
    pub fn last(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("inbox/{key}.last.jsonl"))
    }

    pub fn items(&self, key: &str) -> PathBuf {
        self.watchd.join(format!("items/{key}.json"))
    }

    pub fn workspace(&self, id: &str) -> PathBuf {
        self.watchd.join(format!("workspaces/{id}.json"))
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
