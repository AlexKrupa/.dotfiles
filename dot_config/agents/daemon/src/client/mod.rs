//! The client commands. `watch` saves the watch of a session and exits. `wait` waits for the events
//! of the watches of the session, with the exit codes 0 for events or no watch, and 1 for an error.

use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::io::BufReader;
use tokio::net::UnixStream;

use crate::board::Board;
use crate::core::eventlog::RouteAction;
use crate::core::subs::Mode;
use crate::core::worktrees::Kind;
use crate::daemon::store::Store;
use crate::engine::mr_number;
use crate::key::{KeyMode, digits, repo_slug, watch_key, worktree_top};
use crate::local::{git, repo_of, shared_refs};
use crate::paths::{ClientDirs, StateDirs};
use crate::platform::{local_time, process_alive, spawn_detached, terminal_columns};
use crate::protocol::{Envelope, Request, Response, StatusReport, WatchRequest, receive, send};
use crate::workspaces::workspaces_of;

fn die(message: &str) -> i32 {
    eprintln!("watchd: {message}");
    1
}

/// The ID is also a file name of the daemon.
fn session_id(value: Option<String>) -> Result<String, String> {
    let valid = |id: &String| {
        !id.is_empty()
            && !id.starts_with('.')
            && id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
    };
    value.filter(valid).ok_or_else(|| "--session needs an ID".to_string())
}

#[derive(Default)]
struct WatchArgs {
    repo: Option<PathBuf>,
    interval: u64,
    session: Option<String>,
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
                "--session" => parsed.session = Some(session_id(args.next())?),
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
fn is_author_worktree(top: &Path) -> bool {
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
    // An author watch with no `--mr` waits for the events of all MRs of the worktree.
    let mode = match (args.review, args.mrs.is_empty()) {
        (true, _) => Mode::Review,
        (false, false) => Mode::Author,
        (false, true) if is_author_worktree(&top) => Mode::Author,
        (false, true) => Mode::Hub,
    };
    let key_mode = match mode {
        Mode::Hub => KeyMode::Hub,
        Mode::Author => KeyMode::Author,
        Mode::Review => KeyMode::Review { iid: args.mrs[0] },
    };
    let key = watch_key(&top, &key_mode)?;
    Ok(Target { top, slug, key, mode })
}

fn current_client() -> ClientDirs {
    StateDirs::for_client(&std::env::current_dir().unwrap_or_default())
}

async fn connect(client: &ClientDirs, start: bool) -> Result<UnixStream, String> {
    let dirs = &client.dirs;
    if let Ok(stream) = UnixStream::connect(dirs.socket()).await {
        return Ok(stream);
    }
    if !client.start {
        let base = dirs.watchd.parent().unwrap_or(&dirs.watchd);
        return Err(format!(
            "no watchd daemon in {}, run: daemon/sample/sample start",
            base.display()
        ));
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

async fn ask(client: &ClientDirs, request: &Request, start: bool) -> Result<Response, String> {
    let stream = connect(client, start).await?;
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

pub async fn watch(args: Vec<String>) -> i32 {
    let args = match WatchArgs::parse(args) {
        Ok(args) => args,
        Err(message) => return die(&message),
    };
    let Some(session) = args.session.clone() else {
        return die("watch needs --session");
    };
    let target = match target(&args) {
        Ok(target) => target,
        Err(message) => return die(&message),
    };
    let client = StateDirs::for_client(&target.top);
    let request = Request::Watch(WatchRequest {
        key: target.key,
        slug: target.slug,
        repo: target.top,
        mode: target.mode,
        mrs: args.mrs,
        interval: args.interval,
        session,
        fresh: args.fresh,
    });
    ask_ok(&client, &request).await
}

pub async fn wait(args: Vec<String>) -> i32 {
    let mut session = None;
    let mut owner_pid = None;
    let mut rename_owner_session = false;
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--session" => match session_id(args.next()) {
                Ok(id) => session = Some(id),
                Err(message) => return die(&message),
            },
            "--owner-pid" => match args
                .next()
                .filter(|value| digits(value))
                .and_then(|value| value.parse().ok())
            {
                Some(pid) => owner_pid = Some(pid),
                None => return die("--owner-pid needs a PID"),
            },
            "--rename-owner-session" => rename_owner_session = true,
            _ => return die(&format!("unexpected argument: {arg}")),
        }
    }
    let Some(session) = session else {
        return die("wait needs --session");
    };
    let Some(owner_pid) = owner_pid else {
        return die("wait needs --owner-pid");
    };
    let tick = std::env::var("WATCH_CLIENT_TICK")
        .ok()
        .and_then(|value| value.parse().ok())
        .map_or(Duration::from_secs(3), Duration::from_secs);
    let client = current_client();
    let request = envelope(Request::Wait {
        session,
        owner_pid,
        rename_owner_session,
    });
    loop {
        // A gone owner reads no events: they stay in the inbox for the next waiter.
        if !process_alive(owner_pid) {
            return 0;
        }
        let stream = match connect(&client, true).await {
            Ok(stream) => stream,
            Err(message) => return die(&message),
        };
        let (read, mut write) = stream.into_split();
        if send(&mut write, &request).await.is_ok() {
            let mut reader = BufReader::new(read);
            let receiving = receive(&mut reader);
            tokio::pin!(receiving);
            let mut ticks = tokio::time::interval(tick);
            ticks.tick().await;
            let received = loop {
                // An answer that came is not lost: the daemon took its events from the inbox.
                tokio::select! {
                    biased;
                    received = &mut receiving => break received,
                    _ = ticks.tick() => {
                        if !process_alive(owner_pid) {
                            return 0;
                        }
                    }
                }
            };
            if let Ok(Some(response)) = received {
                return deliver(response);
            }
        }
        // The daemon closed the socket, for example for a restart.
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

fn deliver(response: Response) -> i32 {
    match response {
        Response::Events { events, replaced } => {
            let replaced = replaced.iter().map(|key| {
                let name = serde_json::to_string(&key.key).expect("a key serializes");
                format!(r#"{{"kind":"replaced","key":{name},"mode":"{}"}}"#, key.mode.as_str())
            });
            let events = events
                .iter()
                .map(|event| serde_json::to_string(event).expect("an event serializes"));
            let lines: String = replaced.chain(events).map(|line| line + "\n").collect();
            match std::io::Write::write_all(&mut std::io::stdout(), lines.as_bytes()) {
                Ok(()) => 0,
                Err(error) => die(&format!("stdout: {error}")),
            }
        }
        Response::Error { text } => {
            eprint!("{text}");
            1
        }
        Response::Replaced => 0,
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
    let Some(session) = args.session.clone() else {
        return die("unsubscribe needs --session");
    };
    let target = match target(&args) {
        Ok(target) => target,
        Err(message) => return die(&message),
    };
    let client = StateDirs::for_client(&target.top);
    let request = Request::Unsubscribe {
        key: target.key,
        slug: target.slug,
        mode: target.mode,
        session,
    };
    ask_ok(&client, &request).await
}

async fn ask_ok(client: &ClientDirs, request: &Request) -> i32 {
    match ask(client, request, true).await {
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
    let code = ask_ok(&current_client(), &Request::Kind { kind }).await;
    if code == 0 && kind == Kind::Hub {
        // The board is display only: its error does not fail the command.
        let opened = std::env::current_dir()
            .map_err(|error| error.to_string())
            .and_then(|folder| worktree_top(&folder))
            .and_then(|top| workspaces_of().open_board(&top));
        if let Err(text) = opened {
            eprintln!("watchd: board pane: {text}");
        }
    }
    code
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
            // The host file gives the flags of the watch command.
            "--session" => {
                if let Err(message) = session_id(args.next()) {
                    return die(&message);
                }
            }
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
    let client = StateDirs::for_client(&target.top);
    let request = Request::Route {
        key: target.key,
        iid,
        action,
    };
    ask_ok(&client, &request).await
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
    match ask(&StateDirs::for_client(&target.top), &request, true).await {
        Ok(Response::Report { text }) => {
            println!("{text}");
            0
        }
        Ok(Response::Error { text }) => die(&text),
        Ok(_) => die("unexpected answer of the daemon"),
        Err(message) => die(&message),
    }
}

pub async fn board(args: Vec<String>) -> i32 {
    let mut repo = None;
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--repo" => match args.next() {
                Some(path) => repo = Some(PathBuf::from(path)),
                None => return die("--repo needs a path"),
            },
            // The host file gives the flags of the watch command.
            "--session" => {
                if let Err(message) = session_id(args.next()) {
                    return die(&message);
                }
            }
            _ => return die(&format!("unexpected argument: {arg}")),
        }
    }
    let target = match target(&WatchArgs {
        repo,
        ..WatchArgs::default()
    }) {
        Ok(target) => target,
        Err(message) => return die(&message),
    };
    let client = StateDirs::for_client(&target.top);
    let path = client.dirs.board(&target.slug);
    let mut shown = None;
    loop {
        let stream = match connect(&client, true).await {
            Ok(stream) => stream,
            Err(message) => return die(&message),
        };
        let (read, mut write) = stream.into_split();
        if send(&mut write, &envelope(Request::Follow { after: None }))
            .await
            .is_ok()
        {
            let mut reader = BufReader::new(read);
            let mut line = String::new();
            loop {
                draw_board(&path, &mut shown);
                line.clear();
                // The board also reads its file and the pane width each second: a report writes no
                // log line, and a resize sends no line.
                tokio::select! {
                    read = tokio::io::AsyncBufReadExt::read_line(&mut reader, &mut line) => match read {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    },
                    _ = tokio::time::sleep(Duration::from_secs(1)) => {}
                }
            }
        }
        // The daemon closed the socket, for example for a restart.
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

fn draw_board(path: &Path, shown: &mut Option<(String, usize)>) {
    let file = std::fs::read_to_string(path).unwrap_or_default();
    let columns = terminal_columns().unwrap_or(80);
    let state = (file, columns);
    if shown.as_ref() == Some(&state) {
        return;
    }
    let text = match serde_json::from_str::<Board>(&state.0) {
        Ok(board) => board.draw(columns),
        Err(_) => "No report yet.".to_string(),
    };
    use std::io::Write;
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "\x1b[H\x1b[2J{text}").and_then(|()| stdout.flush());
    *shown = Some(state);
}

pub async fn status() -> i32 {
    let client = current_client();
    let report = match ask(&client, &Request::Status, false).await {
        Ok(Response::Status(report)) => report,
        Err(message) if !client.start => return die(&message),
        _ => StatusReport {
            pid: None,
            repos: Vec::new(),
            subs: Store::new(client.dirs).sub_status(),
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
        let live = if status.live { "live" } else { "away" };
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
    let client = current_client();
    let state = match ask(&client, &Request::DebugState, false).await {
        Ok(Response::State(state)) => *state,
        Err(message) if !client.start => return die(&message),
        _ => Store::new(client.dirs).debug_disk(),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&state).expect("the state serializes")
    );
    0
}

pub async fn follow(after: Option<u64>) -> i32 {
    // A follower has no repo. The sample watcher selects its daemon with `XDG_STATE_HOME`.
    let client = ClientDirs {
        dirs: StateDirs::from_env(),
        start: true,
    };
    let stream = match connect(&client, true).await {
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

    #[test]
    fn watch_flags_with_session_parse_for_report() {
        let args = WatchArgs::parse(["--session", "s", "--mr", "5"].map(String::from).to_vec());

        assert_eq!(args.map(|args| args.mrs), Ok(vec![5]));
    }
}
