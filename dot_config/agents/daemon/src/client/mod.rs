//! The client commands. `watch` is the background task of a session: it starts the daemon if no
//! daemon runs, subscribes, waits for the events of the subscription, and prints one JSON line
//! for each event. The subscription stays live after the client exits: the events of the time
//! with no client wait for the next client. When the daemon closes the socket, for example at an
//! upgrade, the client connects again with the same PID.
//! Exit codes: 0 events, 1 error, 3 a new client or session replaced this one.

use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::io::BufReader;
use tokio::net::UnixStream;

use crate::core::eventlog::RouteAction;
use crate::core::subs::Mode;
use crate::core::workspaces::Kind;
use crate::daemon::store::Store;
use crate::key::{KeyMode, repo_slug, watch_key, worktree_top};
use crate::paths::StateDirs;
use crate::platform::{ancestors, local_time, now_seconds, process_alive, session_pid, spawn_detached};
use crate::protocol::{Request, Response, StatusReport, SubscribeArgs, receive, send};

/// An error of a client command: the text after `watch: `, and exit 1.
fn die(message: &str) -> i32 {
    eprintln!("watch: {message}");
    1
}

#[derive(Default)]
struct WatchArgs {
    repo: Option<PathBuf>,
    interval: u64,
    once: bool,
    fresh: bool,
    review: bool,
    mrs: Vec<u64>,
}

impl WatchArgs {
    fn parse(args: Vec<String>) -> Result<WatchArgs, String> {
        let mut parsed = WatchArgs { interval: 120, ..WatchArgs::default() };
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--repo" => parsed.repo = Some(args.next().ok_or("--repo needs a path")?.into()),
                "--interval" => {
                    let seconds = args.next().filter(|value| digits(value));
                    parsed.interval = seconds.and_then(|value| value.parse().ok()).ok_or("--interval needs seconds")?;
                }
                "--once" => parsed.once = true,
                "--fresh" => parsed.fresh = true,
                "--review" => parsed.review = true,
                "--mr" => {
                    let iid = args.next().map(|value| value.trim_start_matches('!').to_string());
                    let iid = iid.filter(|value| digits(value)).and_then(|value| value.parse().ok());
                    parsed.mrs.push(iid.ok_or("--mr needs an MR number")?);
                }
                _ => return Err(format!("unexpected argument: {arg}")),
            }
        }
        if parsed.review && parsed.mrs.len() != 1 {
            return Err("--review needs exactly one --mr".to_string());
        }
        Ok(parsed)
    }

    fn mode(&self) -> Mode {
        match (self.review, self.mrs.is_empty()) {
            (true, _) => Mode::Review,
            (false, false) => Mode::Stack,
            (false, true) => Mode::Hub,
        }
    }
}

fn digits(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

/// The repo of the flags: its worktree top, slug, and key.
struct Target {
    top: PathBuf,
    slug: String,
    key: String,
}

fn target(args: &WatchArgs) -> Result<Target, String> {
    let current = std::env::current_dir().map_err(|error| error.to_string())?;
    let repo = args.repo.as_ref().map_or(current.clone(), |repo| current.join(repo));
    let shown = args.repo.clone().unwrap_or(current);
    let not_a_repo = || format!("not a git repo: {}", shown.display());
    let git_dir = std::process::Command::new("git")
        .arg("-C")
        .arg(&repo)
        .args(["rev-parse", "--git-dir"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    if !git_dir.is_ok_and(|status| status.success()) {
        return Err(not_a_repo());
    }
    let top = worktree_top(&repo)?;
    let slug = repo_slug(&repo)?;
    let mode = match args.mode() {
        Mode::Hub => KeyMode::Hub,
        Mode::Stack => KeyMode::Stack,
        Mode::Review => KeyMode::Review { iid: args.mrs[0] },
    };
    let key = watch_key(&top, &mode)?;
    Ok(Target { top, slug, key })
}

/// The socket of the daemon. With `start`, the client starts the daemon if no daemon answers.
async fn connect(dirs: &StateDirs, start: bool) -> Result<UnixStream, String> {
    if let Ok(stream) = UnixStream::connect(dirs.socket()).await {
        return Ok(stream);
    }
    let failed = format!("the daemon did not start, see {}", dirs.log().display());
    if !start {
        return Err(failed);
    }
    std::fs::create_dir_all(&dirs.watchd).map_err(|error| error.to_string())?;
    let exe = std::env::current_exe().map_err(|error| error.to_string())?;
    spawn_detached(&exe, &["daemon"], &dirs.log()).map_err(|error| format!("{failed}: {error}"))?;
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(200)).await;
        if let Ok(stream) = UnixStream::connect(dirs.socket()).await {
            return Ok(stream);
        }
    }
    Err(failed)
}

/// One request and its response.
async fn ask(dirs: &StateDirs, request: &Request, start: bool) -> Result<Response, String> {
    let stream = connect(dirs, start).await?;
    let (read, mut write) = stream.into_split();
    send(&mut write, request).await.map_err(|error| error.to_string())?;
    match receive(&mut BufReader::new(read)).await {
        Ok(Some(response)) => Ok(response),
        Ok(None) => Err("the daemon closed the socket".to_string()),
        Err(error) => Err(error.to_string()),
    }
}

fn session(store: &Store) -> u32 {
    let (pid, message) = session_pid();
    if let Some(message) = message {
        store.log("", "", &message);
    }
    pid
}

pub async fn watch(args: Vec<String>) -> i32 {
    let args = match WatchArgs::parse(args) {
        Ok(args) => args,
        Err(message) => return die(&message),
    };
    let target = match target(&args) {
        Ok(target) => target,
        Err(message) => return die(&message),
    };
    let dirs = StateDirs::from_env();
    let _ = std::fs::create_dir_all(&dirs.watchd);
    let session_pid = session(&Store::new(dirs.clone()));
    let client_pid = std::process::id();
    // The parent of the client can be a wrapper shell that stays alive after the agent is
    // killed. Thus the check covers all ancestors.
    let parents = ancestors();
    let mut subscribe = SubscribeArgs {
        key: target.key.clone(),
        slug: target.slug.clone(),
        repo: target.top.clone(),
        mode: args.mode(),
        mrs: args.mrs.clone(),
        interval: args.interval,
        session_pid,
        client_pid,
        herdr_workspace: std::env::var("HERDR_WORKSPACE_ID").ok().filter(|id| !id.is_empty()),
        once: args.once,
        fresh: args.fresh,
        again: false,
        poke_token: format!("{client_pid}-{}", now_seconds()),
    };
    let tick = std::env::var("WATCH_CLIENT_TICK").ok().and_then(|value| value.parse().ok()).unwrap_or(3);
    loop {
        let stream = match connect(&dirs, true).await {
            Ok(stream) => stream,
            Err(message) => return die(&message),
        };
        let (read, mut write) = stream.into_split();
        let mut reader = BufReader::new(read);
        if send(&mut write, &Request::Subscribe(subscribe.clone())).await.is_ok() {
            loop {
                tokio::select! {
                    response = receive::<_, Response>(&mut reader) => match response {
                        Ok(Some(response)) => return deliver(response),
                        Ok(None) | Err(_) => break,
                    },
                    _ = tokio::time::sleep(Duration::from_secs(tick)) => {
                        if let Some(code) = orphaned(&parents, &target.top) {
                            return code;
                        }
                    }
                }
            }
        }
        // The daemon closed the socket. --fresh applies once.
        subscribe.again = true;
        subscribe.fresh = false;
        if let Some(code) = orphaned(&parents, &target.top) {
            return code;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

fn orphaned(parents: &[u32], top: &Path) -> Option<i32> {
    if parents.iter().any(|pid| !process_alive(*pid)) {
        return Some(die("the parent process is gone"));
    }
    match top.is_dir() {
        true => None,
        false => Some(die(&format!("the worktree is gone: {}", top.display()))),
    }
}

fn deliver(response: Response) -> i32 {
    match response {
        Response::Events { events } => {
            for event in events {
                println!("{}", serde_json::to_string(&event).expect("an event serializes"));
            }
            0
        }
        Response::Error { text } => {
            eprint!("{text}");
            1
        }
        Response::Replaced => {
            eprintln!("watch: a new client or session replaced this one");
            3
        }
        Response::Ended => die("the subscription ended"),
        Response::Status(_) | Response::Ok | Response::Report { .. } | Response::State(_) => {
            die("unexpected answer of the daemon")
        }
    }
}

pub async fn unsubscribe(args: Vec<String>) -> i32 {
    let args = match WatchArgs::parse(args) {
        Ok(args) => args,
        Err(message) => return die(&message),
    };
    let target = match target(&args) {
        Ok(target) => target,
        Err(message) => return die(&message),
    };
    let dirs = StateDirs::from_env();
    let session_pid = session(&Store::new(dirs.clone()));
    let request = Request::Unsubscribe { key: target.key, slug: target.slug, mode: args.mode(), session_pid };
    match ask(&dirs, &request, true).await {
        Ok(Response::Ok) => 0,
        Ok(Response::Error { text }) => die(&text),
        Ok(_) => die("unexpected answer of the daemon"),
        Err(message) => die(&message),
    }
}

/// A request that gets `Ok`. The daemon starts if no daemon runs.
async fn ask_ok(request: &Request) -> i32 {
    match ask(&StateDirs::from_env(), request, true).await {
        Ok(Response::Ok) => 0,
        Ok(Response::Error { text }) => die(&text),
        Ok(_) => die("unexpected answer of the daemon"),
        Err(message) => die(&message),
    }
}

/// `kind KIND [--workspace ID]`: the kind of work of the herdr workspace, for the sidebar. The
/// workspace is ID, else `HERDR_WORKSPACE_ID`. With no workspace it does nothing.
pub async fn kind(args: Vec<String>) -> i32 {
    let mut args = args.into_iter();
    let Some(kind) = args.next() else { return die("kind needs a kind") };
    let mut workspace = std::env::var("HERDR_WORKSPACE_ID").ok().filter(|id| !id.is_empty());
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--workspace" => match args.next() {
                Some(id) => workspace = Some(id),
                None => return die("--workspace needs an ID"),
            },
            _ => return die(&format!("unexpected argument: {arg}")),
        }
    }
    let Some(kind) = Kind::parse(&kind) else { return die(&format!("unknown kind: {kind}")) };
    let Some(workspace) = workspace.filter(|id| !id.is_empty()) else { return 0 };
    ask_ok(&Request::Kind { workspace, kind }).await
}

/// `route --iid IID --action bump|review|none [--repo PATH]`: the router result of an opened
/// event of the hub goes to the event log, with the hub key of the repo.
pub async fn route(args: Vec<String>) -> i32 {
    let mut repo = None;
    let mut iid = None;
    let mut action = None;
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--repo" => match args.next() {
                Some(path) => repo = Some(PathBuf::from(path)),
                None => return die("--repo needs a path"),
            },
            "--iid" => {
                let value = args.next().map(|value| value.trim_start_matches('!').to_string());
                match value.filter(|value| digits(value)).and_then(|value| value.parse().ok()) {
                    Some(number) => iid = Some(number),
                    None => return die("--iid needs an MR number"),
                }
            }
            "--action" => match args.next() {
                Some(value) => action = Some(value),
                None => return die("--action needs an action"),
            },
            _ => return die(&format!("unexpected argument: {arg}")),
        }
    }
    let Some(iid) = iid else { return die("route needs --iid") };
    let action_text = action.unwrap_or_default();
    let Some(action) = RouteAction::parse(&action_text) else {
        return die(&format!("unknown action: {action_text}"));
    };
    let target = match target(&WatchArgs { repo, ..WatchArgs::default() }) {
        Ok(target) => target,
        Err(message) => return die(&message),
    };
    ask_ok(&Request::Route { key: target.key, iid, action }).await
}

/// `report [--repo PATH] [--review] [--mr IID]... <JSON`: the Markdown report of the last
/// delivery of the subscription and of its open items. stdin is the input of the model.
pub async fn report(args: Vec<String>) -> i32 {
    let args = match WatchArgs::parse(args) {
        Ok(args) => args,
        Err(message) => return die(&message),
    };
    let target = match target(&args) {
        Ok(target) => target,
        Err(message) => return die(&message),
    };
    let mut text = String::new();
    let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut text);
    if text.trim().is_empty() {
        text = "{}".to_string();
    }
    let value: serde_json::Value = match serde_json::from_str(&text) {
        Ok(value @ serde_json::Value::Object(_)) => value,
        _ => return die("report needs a JSON object on stdin"),
    };
    let Ok(input) = serde_json::from_value(value) else {
        return die("report: jq could not read the input or the state");
    };
    let request = Request::Report { key: target.key, mode: args.mode(), mrs: args.mrs.clone(), input };
    match ask(&StateDirs::from_env(), &request, true).await {
        Ok(Response::Report { text }) => {
            println!("{text}");
            0
        }
        Ok(Response::Error { text }) => die(&text),
        Ok(_) => die("unexpected answer of the daemon"),
        Err(message) => die(&message),
    }
}

/// The daemon PID, the last poll of each repo, and one TSV line for each subscription: key, mode,
/// MRs, live or dead session, inbox line count.
pub async fn status() -> i32 {
    let dirs = StateDirs::from_env();
    let report = match ask(&dirs, &Request::Status, false).await {
        Ok(Response::Status(report)) => report,
        _ => StatusReport { pid: None, repos: Vec::new(), subs: Store::new(dirs).sub_status() },
    };
    match report.pid {
        Some(pid) => println!("daemon {pid}"),
        None => println!("no daemon"),
    }
    for repo in &report.repos {
        let (hour, minute, second) = local_time(repo.last_poll);
        println!("{} last poll {hour:02}:{minute:02}:{second:02}", repo.slug);
    }
    for status in &report.subs {
        let sub = &status.sub;
        let mrs: Vec<String> = sub.mrs.iter().map(u64::to_string).collect();
        let mrs = if mrs.is_empty() { "-".to_string() } else { mrs.join(",") };
        let mode = serde_json::to_value(sub.mode).expect("a mode serializes");
        let live = if status.live { "live" } else { "dead" };
        println!("{}\t{}\t{mrs}\t{live}\t{}", sub.key, mode.as_str().unwrap_or_default(), status.inbox_lines);
    }
    0
}

/// All state as JSON, also the parts in memory only. With no daemon, the state on disk, with
/// `null` for the memory fields.
pub async fn debug_state() -> i32 {
    let dirs = StateDirs::from_env();
    let state = match ask(&dirs, &Request::DebugState, false).await {
        Ok(Response::State(state)) => *state,
        _ => Store::new(dirs).debug_disk(),
    };
    println!("{}", serde_json::to_string_pretty(&state).expect("the state serializes"));
    0
}

/// The waiting clients of the repo stop with exit 3. Only for the eval shims, so that an eval
/// run does not wait for its watch.
pub async fn replace_clients(repo: &Path) -> i32 {
    let top = worktree_top(repo).unwrap_or_else(|_| repo.to_path_buf());
    ask_ok(&Request::ReplaceClients { repo: top }).await
}

/// Removes the workspace record of a closed herdr workspace.
pub async fn forget_workspace(id: String) -> i32 {
    ask_ok(&Request::WorkspaceForget { id }).await
}

/// Prints the sidebar state, the event log lines after `after`, then each new line and each
/// sidebar change, until the daemon closes the socket.
pub async fn follow(after: Option<u64>) -> i32 {
    let dirs = StateDirs::from_env();
    let stream = match connect(&dirs, true).await {
        Ok(stream) => stream,
        Err(message) => return die(&message),
    };
    let (read, mut write) = stream.into_split();
    if let Err(error) = send(&mut write, &Request::Follow { after }).await {
        return die(&error.to_string());
    }
    let mut reader = BufReader::new(read);
    let mut line = String::new();
    loop {
        line.clear();
        match tokio::io::AsyncBufReadExt::read_line(&mut reader, &mut line).await {
            Ok(0) | Err(_) => return 0,
            Ok(_) => {
                use std::io::Write;
                let mut stdout = std::io::stdout().lock();
                if stdout.write_all(line.as_bytes()).and_then(|()| stdout.flush()).is_err() {
                    return 0;
                }
            }
        }
    }
}
