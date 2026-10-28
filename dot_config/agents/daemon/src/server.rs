//! The socket server of the daemon: a `watch` client keeps its connection until its delivery, an
//! error, or the end.

use std::sync::Arc;
use std::time::Duration;

use serde_json::json;
use tokio::io::AsyncWriteExt;

use tokio::io::BufReader;
use tokio::net::{UnixListener, UnixStream};

use crate::core::eventlog::{LogLine, id_of, route_line};
use crate::core::subs::Mode;
use crate::core::worktrees::{ReviewLink, set_kind};
use crate::daemon::{Daemon, Memory};
use crate::key::worktree_top;
use crate::local::repo_of;
use crate::platform::now_seconds;
use crate::protocol::{
    DebugState, Envelope, RepoPoll, RepoTimes, Request, Response, StatusReport, SubscribeArgs, receive, send,
};

pub async fn serve(daemon: Arc<Daemon>, listener: UnixListener) {
    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(handle(daemon.clone(), stream));
            }
            Err(error) => {
                daemon.store.log("", "", &format!("accept: {error}"));
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}

async fn handle(daemon: Arc<Daemon>, stream: UnixStream) {
    let (read, mut write) = stream.into_split();
    let mut reader = BufReader::new(read);
    let Envelope { folder, request } = match receive(&mut reader).await {
        Ok(Some(envelope)) => envelope,
        Ok(None) => return,
        Err(error) => {
            let text = format!("watchd: bad request: {error}\n");
            let _ = send(&mut write, &Response::Error { text }).await;
            return;
        }
    };
    // A follower reads all state and uses no repo.
    let folder = folder.filter(|_| !matches!(request, Request::Follow { .. }));
    if let Some(repo) = folder.as_deref().and_then(repo_of) {
        let _memory = daemon.lock().await;
        daemon.store.add_repo(&repo);
    }
    let response = match request {
        Request::Subscribe(args) => return subscribe(daemon, args, reader, write).await,
        Request::Follow { after } => return follow(daemon, after, reader, write).await,
        Request::DebugState => {
            let memory = daemon.lock().await;
            let repos = memory
                .last_poll
                .iter()
                .map(|(slug, time)| {
                    let next_round = memory.next_round.get(slug).copied();
                    (
                        slug.clone(),
                        RepoTimes {
                            last_poll: *time,
                            next_round,
                        },
                    )
                })
                .collect();
            Response::State(Box::new(DebugState {
                pid: Some(std::process::id()),
                repos: Some(repos),
                rounds: Some(memory.rounds.iter().map(|(key, count)| (key.clone(), *count)).collect()),
                clients: Some(memory.clients.iter().map(|(key, pid)| (key.clone(), *pid)).collect()),
                followers: Some(memory.followers),
                ..daemon.store.debug_disk()
            }))
        }
        Request::ReplaceClients { repo } => {
            let memory = daemon.lock().await;
            let count = daemon.store.replace_clients(&repo);
            drop(memory);
            daemon
                .store
                .log("", "", &format!("clients of {} replaced: {count}", repo.display()));
            daemon.changed.notify_waiters();
            Response::Ok
        }
        Request::Unsubscribe {
            key,
            slug,
            mode,
            session_pid,
        } => {
            let mut memory = daemon.lock().await;
            let result = daemon.store.unsubscribe(&key, &slug, mode, session_pid);
            if result.is_ok() {
                daemon.forget(&mut memory, &key);
            }
            drop(memory);
            daemon.changed.notify_waiters();
            match result {
                Ok(()) => Response::Ok,
                Err(text) => Response::Error { text },
            }
        }
        // A client of format version 1 sends no folder: its workspace has no worktree path.
        Request::Kind { kind, .. } => {
            let top = folder.as_deref().and_then(|folder| worktree_top(folder).ok());
            if let Some(top) = top.and_then(|top| top.canonicalize().ok()) {
                let _memory = daemon.lock().await;
                let live = daemon
                    .store
                    .live_subs(None)
                    .iter()
                    .any(|agent| agent.repo.canonicalize().is_ok_and(|repo| repo == top));
                daemon.store.update_worktree(&top, |state| set_kind(state, kind, live));
                daemon.changed.notify_waiters();
            }
            Response::Ok
        }
        Request::Route { key, iid, action } => {
            let _memory = daemon.lock().await;
            daemon
                .store
                .event_log(vec![LogLine::Route(route_line(now_seconds(), &key, iid, action))]);
            daemon.changed.notify_waiters();
            Response::Ok
        }
        Request::Report { key, mode, mrs, input } => {
            let _memory = daemon.lock().await;
            match daemon.store.report(&key, mode, &mrs, &input) {
                Ok(text) => Response::Report { text },
                Err(text) => Response::Error { text },
            }
        }
        Request::Status => {
            let memory = daemon.lock().await;
            Response::Status(StatusReport {
                pid: Some(std::process::id()),
                repos: memory
                    .last_poll
                    .iter()
                    .map(|(slug, time)| RepoPoll {
                        slug: slug.clone(),
                        last_poll: *time,
                    })
                    .collect(),
                subs: daemon.store.sub_status(),
            })
        }
    };
    let _ = send(&mut write, &response).await;
}

/// Returns `None` while the client waits. `new` is a hub with no record before this client: it gets
/// the open items of the hub when its inbox is empty.
fn delivery(daemon: &Daemon, memory: &Memory, args: &SubscribeArgs, new: bool) -> Option<Response> {
    let key = args.key.as_str();
    let sub = daemon.store.sub(key);
    if let Some(text) = daemon.store.take_error(key) {
        return Some(Response::Error { text });
    }
    if let Some(sub) = &sub
        && (sub.client_pid, sub.session_pid) != (args.client_pid, args.session_pid)
    {
        return Some(Response::Replaced);
    }
    let ended = sub.is_none();
    // With `--once`, a check that started before the poke of the client does not count.
    let own_round = memory.poked.get(key) == Some(&args.poke_token);
    if !args.once || ended || own_round {
        let filter = match args.mode {
            Mode::Stack => args.mrs.as_slice(),
            Mode::Hub | Mode::Review => &[],
        };
        let mut events = daemon.store.take_inbox_of(key, filter);
        if events.is_empty() && new && args.mode == Mode::Hub {
            events = daemon.store.open_events(key);
        }
        if !events.is_empty() || (args.once && own_round) {
            daemon.store.write_last(key, &events);
            return Some(Response::Events { events });
        }
    }
    ended.then_some(Response::Ended)
}

async fn subscribe(
    daemon: Arc<Daemon>,
    args: SubscribeArgs,
    mut reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    mut write: tokio::net::unix::OwnedWriteHalf,
) {
    // `--repo` can name a repo other than the folder of the client.
    let repo = repo_of(&args.repo);
    let new = {
        let mut memory = daemon.lock().await;
        if args.fresh {
            let _ = std::fs::remove_file(daemon.store.dirs.engine_state(&args.key));
        }
        let old = daemon.store.sub(&args.key);
        if old
            .as_ref()
            .is_some_and(|old| old.replaced_sessions.contains(&args.session_pid))
        {
            drop(memory);
            let _ = send(&mut write, &Response::Replaced).await;
            return;
        }
        // No record, but an error or events: the subscription ended with no client, and this client
        // gives the result.
        let ended_with_result = old.is_none() && daemon.store.ended_with_result(&args.key, args.session_pid);
        if !ended_with_result && daemon.store.subscribe(&args, old.as_ref(), now_seconds()) {
            daemon.poke(&mut memory, &args.key, &args.slug, &args.poke_token);
        }
        memory.clients.insert(args.key.clone(), args.client_pid);
        if let Some(repo) = repo.filter(|_| !daemon.stopping()) {
            daemon.store.add_repo(&repo);
            daemon.ensure_managed(&mut memory, &repo);
        }
        // The polling of a reviewed MR goes on after the agent ends.
        if let (Mode::Review, Some(iid), Ok(worktree)) = (args.mode, args.mrs.first(), args.repo.canonicalize()) {
            daemon.store.add_review(ReviewLink { worktree, iid: *iid });
        }
        old.is_none()
    };
    daemon.changed.notify_waiters();
    let mut line = String::new();
    let (response, delivering) = loop {
        let changed = daemon.changed.notified();
        tokio::pin!(changed);
        changed.as_mut().enable();
        let delivering = daemon.delivering.read().await;
        let answer = {
            let memory = daemon.lock().await;
            delivery(&daemon, &memory, &args, new)
        };
        if let Some(answer) = answer {
            break (Some(answer), Some(delivering));
        }
        drop(delivering);
        tokio::select! {
            _ = &mut changed => {}
            _ = tokio::time::sleep(Duration::from_secs(1)) => {}
            // The client sends nothing more: a read is the end of its connection.
            _ = tokio::io::AsyncBufReadExt::read_line(&mut reader, &mut line) => break (None, None),
        }
    };
    let sent = match &response {
        Some(response) => send(&mut write, response).await.is_ok(),
        None => false,
    };
    let mut memory = daemon.lock().await;
    if let Some(Response::Events { events }) = &response {
        match sent {
            true if daemon.store.sub(&args.key).is_none() => daemon.store.remove_owner(&args.key),
            true => {}
            false => daemon.store.put_back_inbox(&args.key, events),
        }
    }
    drop(delivering);
    if memory.clients.get(&args.key) == Some(&args.client_pid) {
        memory.clients.remove(&args.key);
    }
    // The limit of the time with no client starts now.
    if let Some(mut sub) = daemon.store.sub(&args.key)
        && sub.client_pid == args.client_pid
    {
        sub.client_at = now_seconds();
        daemon.store.write_sub(&sub);
    }
}

async fn write_line(write: &mut tokio::net::unix::OwnedWriteHalf, line: &str) -> std::io::Result<()> {
    write.write_all(format!("{line}\n").as_bytes()).await?;
    write.flush().await
}

fn lines_after(daemon: &Daemon, after: u64) -> Vec<String> {
    let text = std::fs::read_to_string(daemon.store.dirs.events()).unwrap_or_default();
    text.lines()
        .filter(|line| id_of(line) > after)
        .map(str::to_string)
        .collect()
}

/// A `follow` client gets the sidebar state with the newest log id, the log lines after `after`,
/// then each new log line and each sidebar change. The lines come from the file: `changed` only
/// wakes the client up.
async fn follow(
    daemon: Arc<Daemon>,
    after: Option<u64>,
    mut reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    mut write: tokio::net::unix::OwnedWriteHalf,
) {
    let (mut sidebar, newest) = {
        let mut memory = daemon.lock().await;
        memory.followers += 1;
        (daemon.store.sidebar(), daemon.store.last_id())
    };
    let mut first = sidebar.clone();
    first["last_id"] = json!(newest);
    let mut last = after.unwrap_or(newest);
    let mut ok = write_line(&mut write, &first.to_string()).await.is_ok();
    let mut closed = String::new();
    while ok {
        // Before the read, so that a line that comes during the read wakes the client up.
        let changed = daemon.changed.notified();
        tokio::pin!(changed);
        changed.as_mut().enable();
        for line in lines_after(&daemon, last) {
            last = last.max(id_of(&line));
            ok = ok && write_line(&mut write, &line).await.is_ok();
        }
        let now = {
            let _memory = daemon.lock().await;
            daemon.store.sidebar()
        };
        if now != sidebar {
            sidebar = now;
            ok = ok && write_line(&mut write, &sidebar.to_string()).await.is_ok();
        }
        if !ok {
            break;
        }
        tokio::select! {
            _ = &mut changed => {}
            _ = tokio::time::sleep(daemon.tick) => {}
            _ = tokio::io::AsyncBufReadExt::read_line(&mut reader, &mut closed) => break,
        }
    }
    daemon.lock().await.followers -= 1;
}
