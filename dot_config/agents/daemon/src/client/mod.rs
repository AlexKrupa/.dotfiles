//! The client commands, with the exit codes 0 for events, 1 for an error, and 3 when a new client
//! or session replaced this one.

use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::io::BufReader;
use tokio::net::UnixStream;

use crate::core::eventlog::RouteAction;
use crate::core::subs::Mode;
use crate::core::worktrees::Kind;
use crate::daemon::store::Store;
use crate::engine::mr_number;
use crate::key::{KeyMode, digits, repo_slug, watch_key, worktree_top};
use crate::local::{git, repo_of, shared_refs};
use crate::paths::StateDirs;
use crate::platform::{ancestors, local_time, now_seconds, process_alive, session_pid, spawn_detached};
use crate::protocol::{Envelope, Request, Response, StatusReport, SubscribeArgs, receive, send};

fn die(message: &str) -> i32 {
    eprintln!("watchd: {message}");
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
        let mut parsed = WatchArgs {
            interval: 120,
            ..WatchArgs::default()
        };
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--repo" => parsed.repo = Some(args.next().ok_or("--repo needs a path")?.into()),
                "--interval" => {
                    let seconds = args.next().filter(|value| digits(value));
                    parsed.interval = seconds
                        .and_then(|value| value.parse().ok())
                        .ok_or("--interval needs seconds")?;
                }
                "--once" => parsed.once = true,
                "--fresh" => parsed.fresh = true,
                "--review" => parsed.review = true,
                "--mr" => parsed
                    .mrs
                    .push(mr_number(args.next()).ok_or("--mr needs an MR number")?),
                _ => return Err(format!("unexpected argument: {arg}")),
            }
        }
        if parsed.review && parsed.mrs.len() != 1 {
            return Err("--review needs exactly one --mr".to_string());
        }
        Ok(parsed)
    }
}

struct Target {
    top: PathBuf,
    slug: String,
    key: String,
    mode: Mode,
}

/// A linked worktree, or the main checkout on a branch that is not the default branch.
fn has_stack(top: &Path) -> bool {
    let main = repo_of(top);
    if main.is_some() && main != top.canonicalize().ok() {
        return true;
    }
    let branch = git(top, &["symbolic-ref", "--short", "-q", "HEAD"]).ok();
    let branch = branch.as_deref().map(str::trim_end);
    let default = shared_refs(top).default_branch;
    branch.is_some() && default.is_some() && branch != default.as_deref()
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
    // A stack watch with no `--mr` waits for the events of all MRs of the worktree.
    let mode = match (args.review, args.mrs.is_empty()) {
        (true, _) => Mode::Review,
        (false, false) => Mode::Stack,
        (false, true) if has_stack(&top) => Mode::Stack,
        (false, true) => Mode::Hub,
    };
    let key_mode = match mode {
        Mode::Hub => KeyMode::Hub,
        Mode::Stack => KeyMode::Stack,
        Mode::Review => KeyMode::Review { iid: args.mrs[0] },
    };
    let key = watch_key(&top, &key_mode)?;
    Ok(Target { top, slug, key, mode })
}

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

fn envelope(request: Request) -> Envelope {
    Envelope {
        folder: std::env::current_dir().ok(),
        request,
    }
}

async fn ask(dirs: &StateDirs, request: &Request, start: bool) -> Result<Response, String> {
    let stream = connect(dirs, start).await?;
    let (read, mut write) = stream.into_split();
    send(&mut write, &envelope(request.clone()))
        .await
        .map_err(|error| error.to_string())?;
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
    // The check covers all ancestors: the parent can be a wrapper shell that stays alive after the
    // agent is killed.
    let parents = ancestors();
    let mut subscribe = SubscribeArgs {
        key: target.key.clone(),
        slug: target.slug.clone(),
        repo: target.top.clone(),
        mode: target.mode,
        mrs: args.mrs.clone(),
        interval: args.interval,
        session_pid,
        client_pid,
        once: args.once,
        fresh: args.fresh,
        again: false,
        poke_token: format!("{client_pid}-{}", now_seconds()),
    };
    let tick = std::env::var("WATCH_CLIENT_TICK")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(3);
    loop {
        let stream = match connect(&dirs, true).await {
            Ok(stream) => stream,
            Err(message) => return die(&message),
        };
        let (read, mut write) = stream.into_split();
        let mut reader = BufReader::new(read);
        if send(&mut write, &envelope(Request::Subscribe(subscribe.clone())))
            .await
            .is_ok()
        {
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
        // The daemon closed the socket: `--fresh` applies to the first subscribe only.
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
            let lines: String = events
                .iter()
                .map(|event| serde_json::to_string(event).expect("an event serializes") + "\n")
                .collect();
            match std::io::Write::write_all(&mut std::io::stdout(), lines.as_bytes()) {
                Ok(()) => 0,
                Err(error) => die(&format!("stdout: {error}")),
            }
        }
        Response::Error { text } => {
            eprint!("{text}");
            1
        }
        Response::Replaced => {
            eprintln!("watchd: a new client or session replaced this one");
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
    let session_pid = session(&Store::new(StateDirs::from_env()));
    ask_ok(&Request::Unsubscribe {
        key: target.key,
        slug: target.slug,
        mode: target.mode,
        session_pid,
    })
    .await
}

async fn ask_ok(request: &Request) -> i32 {
    match ask(&StateDirs::from_env(), request, true).await {
        Ok(Response::Ok) => 0,
        Ok(Response::Error { text }) => die(&text),
        Ok(_) => die("unexpected answer of the daemon"),
        Err(message) => die(&message),
    }
}

pub async fn kind(args: Vec<String>) -> i32 {
    let mut args = args.into_iter();
    let Some(kind) = args.next() else {
        return die("kind needs a kind");
    };
    if let Some(arg) = args.next() {
        return die(&format!("unexpected argument: {arg}"));
    }
    let Some(kind) = Kind::parse(&kind) else {
        return die(&format!("unknown kind: {kind}"));
    };
    ask_ok(&Request::Kind { kind }).await
}

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
            "--iid" => match mr_number(args.next()) {
                Some(number) => iid = Some(number),
                None => return die("--iid needs an MR number"),
            },
            "--action" => match args.next() {
                Some(value) => action = Some(value),
                None => return die("--action needs an action"),
            },
            _ => return die(&format!("unexpected argument: {arg}")),
        }
    }
    let Some(iid) = iid else {
        return die("route needs --iid");
    };
    let action_text = action.unwrap_or_default();
    let Some(action) = RouteAction::parse(&action_text) else {
        return die(&format!("unknown action: {action_text}"));
    };
    let target = match target(&WatchArgs {
        repo,
        ..WatchArgs::default()
    }) {
        Ok(target) => target,
        Err(message) => return die(&message),
    };
    ask_ok(&Request::Route {
        key: target.key,
        iid,
        action,
    })
    .await
}

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
    let request = Request::Report {
        key: target.key,
        mode: target.mode,
        mrs: args.mrs.clone(),
        input,
    };
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

pub async fn status() -> i32 {
    let dirs = StateDirs::from_env();
    let report = match ask(&dirs, &Request::Status, false).await {
        Ok(Response::Status(report)) => report,
        _ => StatusReport {
            pid: None,
            repos: Vec::new(),
            subs: Store::new(dirs).sub_status(),
        },
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
        let live = if status.live { "live" } else { "dead" };
        println!(
            "{}\t{}\t{mrs}\t{live}\t{}",
            sub.key,
            sub.mode.as_str(),
            status.inbox_lines
        );
    }
    0
}

pub async fn debug_state() -> i32 {
    let dirs = StateDirs::from_env();
    let state = match ask(&dirs, &Request::DebugState, false).await {
        Ok(Response::State(state)) => *state,
        _ => Store::new(dirs).debug_disk(),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&state).expect("the state serializes")
    );
    0
}

/// Only for the eval shims, so that an eval run does not wait for its watch.
pub async fn replace_clients(repo: &Path) -> i32 {
    let top = worktree_top(repo).unwrap_or_else(|_| repo.to_path_buf());
    ask_ok(&Request::ReplaceClients { repo: top }).await
}

pub async fn follow(after: Option<u64>) -> i32 {
    let dirs = StateDirs::from_env();
    let stream = match connect(&dirs, true).await {
        Ok(stream) => stream,
        Err(message) => return die(&message),
    };
    let (read, mut write) = stream.into_split();
    if let Err(error) = send(&mut write, &envelope(Request::Follow { after })).await {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mr_flag_takes_one_bang_prefix() {
        let parse = |value: &str| WatchArgs::parse(vec!["--mr".into(), value.into()]).map(|args| args.mrs);

        assert_eq!(parse("!5"), Ok(vec![5]));
        assert_eq!(parse("!!5"), Err("--mr needs an MR number".to_string()));
    }
}
