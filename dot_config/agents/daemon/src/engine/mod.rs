//! Usage: watchd engine [--repo PATH] [--fresh] [--review] [--mr IID]... [--skip-mr IID]...
//! The check engine of the watch daemon. It does one check and prints one JSON line for
//! each new event: kind, iid, title, url, actor, detail, branch. With no state file, the check only
//! saves the state. A value that the saved state does not have gives no event at its first check.
//! --fresh: delete the state file before the check.
//! --skip-mr: hub mode, an MR with a review watch.
//! WATCH_MR_CACHE=DIR: a fetched MR goes to DIR/<project>-<iid>.json, and a later fetch of the MR
//! reads it. Two clones with the same directory name share one DIR.
//!
//! Hub mode (no --mr) watches the project of the repo, for the hub. Events:
//!   kind            when                                          except
//!   todo            a new pending to-do item on an MR             on an MR of the user
//!   opened          a new open MR, of the newest 100              an MR of the user
//!   note            a new comment on an MR of a different         a comment of the user, a system
//!                   person that the user commented on (14 days)   note
//!   reaction        a new reaction on a comment of the user       a reaction of the user
//!   default-failed  a new failed default-branch pipeline          a pipeline id below the saved id,
//!                                                                 for example during a job retry
//! An MR of --skip-mr gives only the review_requested to-do item and the opened event. The agent of
//! the review watch reports the other events.
//! opened: actor is the MR author. default-failed: iid and title are null, previous is the status
//! of the saved default-branch pipeline, or null, and jobs are the names of the failed jobs.
//!
//! Stack mode (--mr, one for each MR, `!` prefix allowed) watches the MRs of the stack of the user.
//! Review mode (--review and one --mr) watches one MR for its reviewer. Events of both modes:
//!   kind                     when                                       except
//!   pipeline                 the head pipeline failed or passed. A failed
//!                            pipeline has jobs: the names of the failed jobs
//!   comment                  a new comment                              a comment of the user
//!   own-comment              a new comment of the user
//!   reaction                 a new reaction, on the MR or a comment     a reaction of the user
//!   approved, unapproved     an approval added or removed               the user
//!   draft, ready             the draft state changed                    a change of the user
//!   title                    the title changed (detail: new title)      a change of the user
//!   description              the description changed                    a change of the user
//!   labels                   the labels changed (detail: +new, -gone)   a change of the user
//!   conflict                 a merge conflict started
//!   mergeable                the MR became mergeable
//!   merged, closed           the MR was merged or closed                none (the user: own true)
//!   unaddressed              after the other events: each open thread   a thread that the user
//!                            whose last comment is not of the user      answered last
//! Review mode only:
//!   pushed                   the head changed (old_base, old_head, new_base, new_head)
//!   resolved                 a different user resolved a thread that the user started
//!   unaddressed              only for the threads that have a comment of the user
//! Comments, reactions, and threads on a diff line also have path and line. The actor of a change
//! comes from the newest system note of that change, or is empty.
//!
//! Open items. An event that opens an item for the user has the item key in `item`. The state
//! file has present: the item keys whose cause GitLab still shows. The daemon closes the other
//! items.
//!   item                     event                        present while
//!   todo:<to-do id>          todo                         the to-do item is pending
//!   note:<note id>           note                         the MR is open, the note is not
//!                                                         resolved, and the user has no later
//!                                                         note on the MR (at the last notes fetch)
//!   main-failed:<branch>     default-failed               the newest default-branch pipeline
//!                                                         failed
//!   thread:<discussion id>   comment (only if the thread  the open MR has the thread in
//!                            is unaddressed), unaddressed unaddressed
//!   pipeline:<iid>           failed pipeline              the head pipeline of the open MR failed
//!   conflict:<iid>           conflict                     the merge status of the open MR is
//!                                                         conflict or need_rebase
//!
//! A stack watch has its own state for each worktree. A review watch has its own state for each MR.
//! Exit codes: 0 check done, 1 error, 4 network error, 5 permanent error (HTTP 401 or 403, a
//! GraphQL error, an unknown MR, unreadable comments, no glab authentication).

pub mod event;
#[cfg(feature = "test-support")]
pub mod fake;
pub mod hub;
pub mod stack;
pub mod state;

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;

use serde::de::DeserializeOwned;

use self::event::{Event, EventKind};
use crate::glab;
use crate::key::{KeyMode, watch_key};
use crate::paths::StateDirs;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct EngineArgs {
    pub repo: Option<PathBuf>,
    pub fresh: bool,
    pub review: bool,
    pub mrs: Vec<u64>,
    pub skip_mrs: Vec<u64>,
}

impl EngineArgs {
    /// The flags of the `engine` subcommand. The callers compare the error texts.
    pub fn parse(args: Vec<String>) -> Result<EngineArgs, String> {
        let mut parsed = EngineArgs::default();
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--repo" => {
                    parsed.repo = Some(args.next().ok_or("--repo needs a path")?.into());
                }
                "--mr" => parsed.mrs.push(mr_number(args.next()).ok_or("--mr needs an MR number")?),
                "--skip-mr" => parsed
                    .skip_mrs
                    .push(mr_number(args.next()).ok_or("--skip-mr needs an MR number")?),
                "--review" => parsed.review = true,
                "--fresh" => parsed.fresh = true,
                _ => return Err(format!("unexpected argument: {arg}")),
            }
        }
        if parsed.review && parsed.mrs.len() != 1 {
            return Err("--review needs exactly one --mr".to_string());
        }
        Ok(parsed)
    }

    fn key_mode(&self) -> KeyMode {
        match (self.review, self.mrs.first()) {
            (true, Some(iid)) => KeyMode::Review { iid: *iid },
            (_, Some(_)) => KeyMode::Stack,
            (_, None) => KeyMode::Hub,
        }
    }
}

/// A positive decimal number, with an optional `!` prefix.
pub fn mr_number(arg: Option<String>) -> Option<u64> {
    let arg = arg?;
    let digits = arg.strip_prefix('!').unwrap_or(&arg);
    match !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit()) {
        true => digits.parse().ok(),
        false => None,
    }
}

#[derive(Debug)]
pub enum EngineError {
    Permanent(String),
    Network(String),
    Other(String),
}

impl EngineError {
    pub fn exit_code(&self) -> i32 {
        match self {
            EngineError::Permanent(_) => 5,
            EngineError::Network(_) => 4,
            EngineError::Other(_) => 1,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            EngineError::Permanent(message)
            | EngineError::Network(message)
            | EngineError::Other(message) => message,
        }
    }
}

impl From<glab::ApiError> for EngineError {
    fn from(error: glab::ApiError) -> EngineError {
        match error {
            glab::ApiError::Auth { .. } => EngineError::Permanent(error.to_string()),
            glab::ApiError::Network(message) => EngineError::Network(message),
            glab::ApiError::Other(message) => EngineError::Other(message),
        }
    }
}

/// What a check needs, from the preflight.
#[derive(Clone)]
pub struct CheckContext {
    pub args: EngineArgs,
    /// The worktree: the `glab` calls run in it.
    pub repo: PathBuf,
    pub state: PathBuf,
    pub project: String,
    pub project_ref: String,
    pub cache: Option<Arc<MrCache>>,
}

pub type EngineFuture<'a> = std::pin::Pin<Box<dyn Future<Output = Result<Vec<Event>, EngineError>> + Send + 'a>>;

/// One check of a subscription. The daemon runs the GitLab engine, the tests a fake.
pub trait Engine: Send + Sync {
    fn check(&self, args: EngineArgs, cache: Arc<MrCache>) -> EngineFuture<'_>;
}

pub struct GitlabEngine {
    pub dirs: StateDirs,
}

impl Engine for GitlabEngine {
    /// The error text starts with `watch-gitlab: `, as the error of the `engine` subcommand.
    fn check(&self, args: EngineArgs, cache: Arc<MrCache>) -> EngineFuture<'_> {
        Box::pin(async move {
            let result = match preflight(args, &self.dirs, Some(cache)).await {
                Ok(ctx) => run_check(&ctx).await,
                Err(error) => Err(error),
            };
            result.map_err(|error| {
                let text = format!("watch-gitlab: {}\n", error.message());
                match error {
                    EngineError::Permanent(_) => EngineError::Permanent(text),
                    EngineError::Network(_) => EngineError::Network(text),
                    EngineError::Other(_) => EngineError::Other(text),
                }
            })
        })
    }
}

/// The MR cache of a round: a fetched MR goes to `<dir>/<project>-<iid>.json`, and a later fetch
/// of the MR reads it. The checks of one MR wait for each other, so that the MR has one fetch.
pub struct MrCache {
    pub dir: PathBuf,
    locks: std::sync::Mutex<std::collections::HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

impl MrCache {
    pub fn new(dir: PathBuf) -> MrCache {
        MrCache { dir, locks: std::sync::Mutex::default() }
    }

    pub async fn lock(&self, name: &str) -> tokio::sync::OwnedMutexGuard<()> {
        let lock = {
            let mut locks = self.locks.lock().expect("the lock map is never poisoned");
            locks.entry(name.to_string()).or_default().clone()
        };
        lock.lock_owned().await
    }
}

/// The checks before the first fetch. Their order selects the error of a setup with more than one
/// problem.
pub async fn preflight(
    args: EngineArgs,
    dirs: &StateDirs,
    cache: Option<Arc<MrCache>>,
) -> Result<CheckContext, EngineError> {
    let other = |message: String| EngineError::Other(message);
    if !on_path("glab") {
        return Err(other("glab is not installed".to_string()));
    }
    let current = std::env::current_dir().map_err(|error| other(error.to_string()))?;
    let repo = match &args.repo {
        Some(repo) => current.join(repo),
        None => current,
    };
    let shown = args.repo.clone().unwrap_or_else(|| repo.clone());
    if !git_ok(&repo, &["rev-parse", "--git-dir"]) {
        return Err(other(format!("not a git repo: {}", shown.display())));
    }
    let key = watch_key(&repo, &args.key_mode()).map_err(other)?;
    let state = dirs.engine_state(&key);
    std::fs::create_dir_all(&dirs.engine)
        .map_err(|error| other(format!("{}: {error}", dirs.engine.display())))?;
    let authenticated = glab::run(&repo, &["auth", "status"]).await.is_ok_and(|out| out.status.success());
    if !authenticated {
        return Err(EngineError::Permanent(
            "glab is not authenticated, run: glab auth login".to_string(),
        ));
    }
    if args.fresh {
        let _ = std::fs::remove_file(&state);
    }
    let remote = remote_url(&repo).ok_or_else(|| other(format!("no git remote in {}", shown.display())))?;
    let project = project_of_url(&remote);
    let project_ref = uri_encode(&project);
    Ok(CheckContext { args, repo, state, project, project_ref, cache })
}

fn on_path(program: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|dir| {
            std::fs::metadata(dir.join(program))
                .is_ok_and(|meta| meta.is_file() && std::os::unix::fs::PermissionsExt::mode(&meta.permissions()) & 0o111 != 0)
        })
    })
}

fn git(repo: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    match output.status.success() {
        true => Some(String::from_utf8_lossy(&output.stdout).trim_end().to_string()),
        false => None,
    }
}

fn git_ok(repo: &Path, args: &[&str]) -> bool {
    git(repo, args).is_some()
}

/// The URL of `origin`, else of the first remote.
pub fn remote_url(repo: &Path) -> Option<String> {
    git(repo, &["remote", "get-url", "origin"]).or_else(|| {
        let remotes = git(repo, &["remote"])?;
        git(repo, &["remote", "get-url", remotes.lines().next()?])
    })
}

/// The host and the path of an https, ssh, or scp-like git URL. `None` for a local path.
pub fn split_remote(url: &str) -> Option<(&str, &str)> {
    if let Some((scheme, rest)) = url.split_once("://")
        && !scheme.is_empty()
        && scheme.bytes().all(|byte| byte.is_ascii_lowercase() || byte == b'+')
    {
        let (authority, path) = rest.split_once('/')?;
        let host = authority.split_once('@').map_or(authority, |(_, host)| host);
        let host = host.split(':').next().unwrap_or_default();
        return (!host.is_empty()).then_some((host, path));
    }
    let (user, rest) = url.split_once('@')?;
    if user.is_empty() || user.contains(['/', ':']) {
        return None;
    }
    let (host, path) = rest.split_once(':')?;
    (!host.is_empty()).then_some((host, path))
}

/// The group/project path of an https, ssh, or scp-like git URL.
pub fn project_of_url(url: &str) -> String {
    let url = url.strip_suffix(".git").unwrap_or(url);
    split_remote(url).map_or(url, |(_, path)| path).to_string()
}

/// jq `@uri`: each byte except the unreserved characters is percent-encoded.
pub fn uri_encode(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

/// One `glab api` call: its folder and its arguments. The first argument is the path.
pub struct Call {
    pub dir: PathBuf,
    pub args: Vec<String>,
}

impl CheckContext {
    /// A call in the worktree of the check.
    pub fn call(&self, items: &[&str]) -> Call {
        Call { dir: self.repo.clone(), args: args(items) }
    }
}

/// `glab api ARGS`, one JSON value.
pub async fn api_json<T: DeserializeOwned>(call: Call) -> Result<T, EngineError> {
    let output = glab::api(&call.dir, &call.args).await?;
    serde_json::from_slice(&output).map_err(|error| bad_json(&call.args, error))
}

/// `glab api ARGS`, one array or one array for each page, as `jq -s 'add // []'`.
pub async fn api_pages<T: DeserializeOwned>(call: Call) -> Result<Vec<T>, EngineError> {
    let output = glab::api(&call.dir, &call.args).await?;
    let mut items = Vec::new();
    for page in serde_json::Deserializer::from_slice(&output).into_iter::<Vec<T>>() {
        items.extend(page.map_err(|error| bad_json(&call.args, error))?);
    }
    Ok(items)
}

fn bad_json(args: &[String], error: serde_json::Error) -> EngineError {
    let path = args.first().map(String::as_str).unwrap_or_default();
    EngineError::Other(format!("{path}: unexpected JSON: {error}"))
}

pub fn args(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| item.to_string()).collect()
}

/// The first error in the order of the results, else all values.
pub fn all_ok<T>(results: Vec<Result<T, EngineError>>) -> Result<Vec<T>, EngineError> {
    results.into_iter().collect()
}

#[derive(serde::Deserialize)]
struct Job {
    name: String,
}

/// A failed pipeline gets the sorted names of its failed jobs. An error must not save the state,
/// so that the events of the check come again.
pub async fn add_jobs(
    ctx: &CheckContext,
    project: &str,
    mut events: Vec<Event>,
) -> Result<Vec<Event>, EngineError> {
    let mut calls = Vec::new();
    for (index, event) in events.iter().enumerate() {
        let failed = match event.kind {
            EventKind::Pipeline | EventKind::DefaultFailed => failed_pipeline(&event.detail),
            _ => None,
        };
        if let Some(id) = failed {
            let path = format!("projects/{project}/pipelines/{id}/jobs?scope[]=failed&per_page=100");
            calls.push((index, path));
        }
    }
    let tasks = calls
        .iter()
        .map(|(_, path)| {
            let call = ctx.call(&[path]);
            Box::pin(async move { api_pages::<Job>(call).await }) as glab::Task<_>
        })
        .collect();
    let jobs: Vec<Vec<Job>> = all_ok(glab::parallel(tasks).await)?;
    for ((index, _), jobs) in calls.into_iter().zip(jobs) {
        let mut names: Vec<String> = jobs.into_iter().map(|job| job.name).collect();
        names.sort();
        names.dedup();
        events[index].jobs = Some(names);
    }
    Ok(events)
}

/// The id of `pipeline <id> failed`.
fn failed_pipeline(detail: &str) -> Option<&str> {
    let id = detail.strip_prefix("pipeline ")?.strip_suffix(" failed")?;
    match !id.is_empty() && id.bytes().all(|byte| byte.is_ascii_digit()) {
        true => Some(id),
        false => None,
    }
}

/// One check: the events, and the new state saved.
pub async fn run_check(ctx: &CheckContext) -> Result<Vec<Event>, EngineError> {
    match ctx.args.mrs.is_empty() {
        true => hub::check_hub(ctx).await,
        false => stack::check_stack(ctx).await,
    }
}

/// The `engine` subcommand: one check, the events on stdout, and the exit codes of the module doc.
pub async fn main(args: Vec<String>) -> i32 {
    let result = match EngineArgs::parse(args) {
        Ok(args) => {
            let cache = std::env::var_os("WATCH_MR_CACHE").filter(|dir| !dir.is_empty());
            let cache = cache.map(|dir| Arc::new(MrCache::new(PathBuf::from(dir))));
            match preflight(args, &StateDirs::from_env(), cache).await {
                Ok(ctx) => run_check(&ctx).await,
                Err(error) => Err(error),
            }
        }
        Err(message) => Err(EngineError::Other(message)),
    };
    match result {
        Ok(events) => {
            for event in events {
                println!("{}", serde_json::to_string(&event).expect("an event serializes"));
            }
            0
        }
        Err(error) => {
            eprintln!("watch-gitlab: {}", error.message());
            error.exit_code()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<EngineArgs, String> {
        EngineArgs::parse(args.iter().map(|a| a.to_string()).collect())
    }

    #[test]
    fn engine_args_reject_review_without_exactly_one_mr() {
        assert_eq!(parse(&["--review"]).unwrap_err(), "--review needs exactly one --mr");
        assert_eq!(
            parse(&["--review", "--mr", "5", "--mr", "6"]).unwrap_err(),
            "--review needs exactly one --mr"
        );
    }

    #[test]
    fn split_remote_gives_the_host_and_the_path_of_https_ssh_and_scp_urls() {
        assert_eq!(split_remote("https://gitlab.example.com/g/a.git"), Some(("gitlab.example.com", "g/a.git")));
        assert_eq!(split_remote("ssh://git@gitlab.example.com:22/g/a.git"), Some(("gitlab.example.com", "g/a.git")));
        assert_eq!(split_remote("git@gitlab.example.com:g/a.git"), Some(("gitlab.example.com", "g/a.git")));
        assert_eq!(split_remote("/tmp/repo"), None);
    }

    #[test]
    fn remote_url_falls_back_to_the_first_remote() {
        let repo = std::env::temp_dir().join(format!("watchd-remote-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&repo);
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q"]).unwrap();
        git(&repo, &["remote", "add", "upstream", "git@gitlab.example.com:g/a.git"]).unwrap();

        assert_eq!(remote_url(&repo).as_deref(), Some("git@gitlab.example.com:g/a.git"));
    }

    #[test]
    fn project_of_url_handles_https_ssh_and_scp_urls() {
        assert_eq!(project_of_url("https://gitlab.example.com/group/sub/app.git"), "group/sub/app");
        assert_eq!(project_of_url("ssh://git@gitlab.example.com:22/g/a.git"), "g/a");
        assert_eq!(project_of_url("git@gitlab.example.com:group/sub/app.git"), "group/sub/app");
        assert_eq!(uri_encode("group/sub app"), "group%2Fsub%20app");
    }

    #[test]
    fn engine_args_strip_the_bang_prefix_of_mr() {
        assert_eq!(parse(&["--mr", "!12"]).unwrap().mrs, vec![12]);
        assert_eq!(parse(&["--mr", "x"]).unwrap_err(), "--mr needs an MR number");
    }
}
