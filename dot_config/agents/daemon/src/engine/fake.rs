//! The engine of the tests. For the key of a check, the files `<key>.*` of its folder give:
//! - `.jsonl`: the event lines. The check takes them and empties the file.
//! - `.exit`: one exit code for each line. The check takes the first line and fails with the text
//!   of `.err`.
//! - `.state`: the saved state of the engine.
//! - `.sleep`: the seconds to wait after the events are read. The file then goes away.
//!
//! Each check adds its arguments as one line to `args`.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::event::Event;
use super::{Engine, EngineArgs, EngineError, EngineFuture, LookupFuture, MrCache};
use crate::key::watch_key;

pub struct FakeEngine {
    pub dir: PathBuf,
    pub engine_dir: PathBuf,
}

fn take_first_line(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let (first, rest) = text.split_once('\n').unwrap_or((&text, ""));
    let first = first.trim().to_string();
    let _ = std::fs::write(path, rest);
    Some(first).filter(|line| !line.is_empty())
}

fn arguments(args: &EngineArgs) -> Vec<String> {
    let mut flags = Vec::new();
    if let Some(repo) = &args.repo {
        flags.extend(["--repo".to_string(), repo.display().to_string()]);
    }
    if args.fresh {
        flags.push("--fresh".to_string());
    }
    if args.review {
        flags.push("--review".to_string());
    }
    for mr in &args.mrs {
        flags.extend(["--mr".to_string(), mr.to_string()]);
    }
    for mr in &args.skip_mrs {
        flags.extend(["--skip-mr".to_string(), mr.to_string()]);
    }
    flags
}

impl FakeEngine {
    async fn run(&self, args: EngineArgs) -> Result<Vec<Event>, EngineError> {
        let line = arguments(&args).join(" ") + "\n";
        let log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join("args"));
        if let Ok(mut log) = log {
            let _ = std::io::Write::write_all(&mut log, line.as_bytes());
        }
        let repo = args.repo.clone().unwrap_or_else(|| PathBuf::from("."));
        let key = match &args.key {
            Some(key) => key.clone(),
            None => watch_key(&repo, &args.key_mode()).map_err(EngineError::Other)?,
        };
        let file = |suffix: &str| self.dir.join(format!("{key}.{suffix}"));
        if file("state").exists() {
            let _ = std::fs::create_dir_all(&self.engine_dir);
            let _ = std::fs::copy(file("state"), self.engine_dir.join(format!("{key}.json")));
        }
        if let Some(code) = take_first_line(&file("exit")) {
            let text = std::fs::read_to_string(file("err")).unwrap_or_default();
            return Err(match code.as_str() {
                "4" => EngineError::Network(text),
                "5" => EngineError::Permanent(text),
                _ => EngineError::Other(text),
            });
        }
        let text = std::fs::read_to_string(file("jsonl")).unwrap_or_default();
        let _ = std::fs::write(file("jsonl"), "");
        if let Ok(seconds) = std::fs::read_to_string(file("sleep")) {
            let _ = std::fs::remove_file(file("sleep"));
            tokio::time::sleep(std::time::Duration::from_secs(seconds.trim().parse().unwrap_or(0))).await;
        }
        text.lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                serde_json::from_str(line)
                    .map_err(|error| EngineError::Other(format!("bad engine line: {error}: {line}\n")))
            })
            .collect()
    }
}

impl Engine for FakeEngine {
    fn check(&self, args: EngineArgs, _cache: Arc<MrCache>) -> EngineFuture<'_> {
        Box::pin(self.run(args))
    }

    /// The file `lookup-<branch>` gives the MR number. The call adds `lookup <branch>` to `args`.
    fn lookup(&self, _repo: PathBuf, branch: String) -> LookupFuture<'_> {
        Box::pin(async move {
            let log = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.dir.join("args"));
            if let Ok(mut log) = log {
                let _ = std::io::Write::write_all(&mut log, format!("lookup {branch}\n").as_bytes());
            }
            let file = self.dir.join(format!("lookup-{}", branch.replace('/', "%2F")));
            let text = std::fs::read_to_string(file).unwrap_or_default();
            Ok(text.trim().parse().ok())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn scratch(name: &str) -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!("watchd-fake-{}-{name}", std::process::id()));
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
        std::fs::create_dir_all(dir.join("events")).unwrap();
        (dir.canonicalize().unwrap(), repo.canonicalize().unwrap())
    }

    fn hub(repo: &Path) -> EngineArgs {
        EngineArgs {
            repo: Some(repo.to_path_buf()),
            ..EngineArgs::default()
        }
    }

    fn cache(dir: &Path) -> Arc<MrCache> {
        Arc::new(MrCache::new(dir.join("cache")))
    }

    #[tokio::test]
    async fn fake_engine_gives_the_events_of_its_file_once() {
        let (dir, repo) = scratch("events");
        let engine = FakeEngine {
            dir: dir.join("events"),
            engine_dir: dir.join("engine"),
        };
        let line = r#"{"kind":"todo","iid":5,"title":"Add foo","url":"u","actor":"anna","detail":"d","branch":"b"}"#;
        std::fs::write(dir.join("events/app.jsonl"), format!("{line}\n")).unwrap();
        std::fs::write(dir.join("events/app.state"), "{\"todos\": []}\n").unwrap();

        let first = engine.check(hub(&repo), cache(&dir)).await.unwrap();
        let second = engine.check(hub(&repo), cache(&dir)).await.unwrap();

        assert_eq!(first.len(), 1);
        assert_eq!(serde_json::to_string(&first[0]).unwrap(), line);
        assert!(second.is_empty());
        assert_eq!(
            std::fs::read_to_string(dir.join("engine/app.json")).unwrap(),
            "{\"todos\": []}\n"
        );
        let logged = format!("--repo {}\n", repo.display());
        assert_eq!(
            std::fs::read_to_string(dir.join("events/args")).unwrap(),
            logged.repeat(2)
        );
    }

    #[tokio::test]
    async fn fake_engine_fails_once_for_each_exit_line() {
        let (dir, repo) = scratch("exit");
        let engine = FakeEngine {
            dir: dir.join("events"),
            engine_dir: dir.join("engine"),
        };
        std::fs::write(dir.join("events/app.exit"), "5\n4\n").unwrap();
        std::fs::write(dir.join("events/app.err"), "watchd: HTTP 403\n").unwrap();

        let first = engine.check(hub(&repo), cache(&dir)).await;
        let second = engine.check(hub(&repo), cache(&dir)).await;
        let third = engine.check(hub(&repo), cache(&dir)).await;

        assert!(matches!(first, Err(EngineError::Permanent(text)) if text == "watchd: HTTP 403\n"));
        assert!(matches!(second, Err(EngineError::Network(_))));
        assert!(matches!(third, Ok(events) if events.is_empty()));
    }
}
