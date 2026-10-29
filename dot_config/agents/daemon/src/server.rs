//! The socket server of the daemon: a `wait` client keeps its connection until its delivery or an
//! error.

use std::sync::Arc;
use std::time::Duration;

use serde_json::json;
use tokio::io::AsyncWriteExt;

use tokio::io::BufReader;
use tokio::net::{UnixListener, UnixStream};

use crate::core::eventlog::{LogLine, id_of, route_line};
use crate::core::subs::{Mode, SessionKey};
use crate::core::worktrees::{ReviewLink, set_kind};
use crate::daemon::Daemon;
use crate::key::worktree_top;
use crate::local::repo_of;
use crate::platform::now_seconds;
use crate::protocol::{
    DebugState, Envelope, KeyedEvent, RepoPoll, RepoTimes, Request, Response, StatusReport, WatchRequest, receive, send,
};

const OLD_CLIENT: &str = "watchd: this watch client is older than the daemon. Start the watch again.\n";

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
    // A follower reads all state, and a waiter reads the state of its session: they use no repo.
    let folder = folder.filter(|_| {
        !matches!(
            request,
            Request::Follow { .. } | Request::Wait { .. } | Request::Subscribe(_)
        )
    });
    if let Some(repo) = folder.as_deref().and_then(repo_of) {
        let _memory = daemon.lock().await;
        daemon.store.add_repo(&repo);
    }
    let response = match request {
        Request::Watch(request) => watch(&daemon, &request).await,
        Request::Wait { session, owner_pid } => return wait(daemon, session, owner_pid, reader, write).await,
        Request::Subscribe(_) => Response::Error {
            text: OLD_CLIENT.to_string(),
        },
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
                waiters: Some(
                    memory
                        .waiters
                        .iter()
                        .map(|(id, number)| (id.clone(), *number))
                        .collect(),
                ),
                followers: Some(memory.followers),
                ..daemon.store.debug_disk()
            }))
        }
        Request::Unsubscribe {
            key,
            slug,
            mode,
            session,
        } => {
            let mut memory = daemon.lock().await;
            let result = daemon.store.unsubscribe(&key, &slug, mode, &session);
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

async fn watch(daemon: &Arc<Daemon>, request: &WatchRequest) -> Response {
    // `--repo` can name a repo other than the folder of the client.
    let repo = repo_of(&request.repo);
    {
        let mut memory = daemon.lock().await;
        if request.fresh {
            let _ = std::fs::remove_file(daemon.store.dirs.engine_state(&request.key));
        }
        daemon.store.watch(request, now_seconds());
        daemon.poke(&mut memory, &request.key, &request.slug);
        if let Some(repo) = repo.filter(|_| !daemon.stopping()) {
            daemon.store.add_repo(&repo);
            daemon.ensure_managed(&mut memory, &repo);
        }
        // The polling of a reviewed MR goes on after the agent ends.
        if let (Mode::Review, Some(iid), Ok(worktree)) =
            (request.mode, request.mrs.first(), request.repo.canonicalize())
        {
            daemon.store.add_review(ReviewLink { worktree, iid: *iid });
        }
    }
    daemon.changed.notify_waiters();
    Response::Ok
}

/// Returns `None` while the waiter waits. The keys of the session are the keys of its records and
/// the keys that ended since its last wait. A different session can have a new record of an ended
/// key: the error stays with the session of the ended record, and the inbox goes to the record.
fn delivery(daemon: &Daemon, session: &str) -> Option<Response> {
    let records = daemon.store.session_subs(session);
    let mut state = daemon.store.session(session).unwrap_or_default();
    if let Some((key, text)) = state
        .ended
        .iter()
        .find_map(|ended| Some((ended.key.clone(), daemon.store.take_error(&ended.key)?)))
    {
        state.ended.retain(|ended| ended.key != key);
        daemon.store.write_session(session, &state);
        return Some(Response::Error { text });
    }
    let ended = state
        .ended
        .iter()
        .filter(|ended| daemon.store.sub(&ended.key).is_none())
        .map(|ended| (ended.key.clone(), ended.mode, &[][..]));
    let keys: Vec<(String, Mode, &[u64])> = records
        .iter()
        .map(|sub| {
            let filter = match sub.mode {
                Mode::Author => sub.mrs.as_slice(),
                Mode::Hub | Mode::Review => &[],
            };
            (sub.key.clone(), sub.mode, filter)
        })
        .chain(ended)
        .collect();
    let mut events = Vec::new();
    for (key, mode, filter) in &keys {
        let taken = daemon.store.take_inbox_of(key, filter);
        if taken.is_empty() {
            continue;
        }
        daemon.store.write_last(key, &taken);
        // The report shows all rows, and the model gets the rows that the router did not handle.
        let handled = daemon.store.routing(key).handled;
        events.extend(
            taken
                .into_iter()
                .filter(|event| !handled.contains(&event.row))
                .map(|routed| KeyedEvent {
                    key: key.clone(),
                    mode: *mode,
                    routed,
                }),
        );
    }
    let replaced = std::mem::take(&mut state.replaced);
    if !replaced.is_empty() || !state.ended.is_empty() {
        state.ended.clear();
        daemon.store.write_session(session, &state);
    }
    match (events.is_empty() && replaced.is_empty(), records.is_empty()) {
        (false, _) | (true, true) => Some(Response::Events { events, replaced }),
        (true, false) => None,
    }
}

async fn wait(
    daemon: Arc<Daemon>,
    session: String,
    owner_pid: u32,
    mut reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    mut write: tokio::net::unix::OwnedWriteHalf,
) {
    let number = {
        let mut memory = daemon.lock().await;
        let mut state = daemon.store.session(&session).unwrap_or_default();
        state.owner_pid = Some(owner_pid);
        state.owner_gone_at = None;
        daemon.store.write_session(&session, &state);
        memory.next_waiter += 1;
        let number = memory.next_waiter;
        memory.waiters.insert(session.clone(), number);
        number
    };
    // An older waiter of the session gets its answer.
    daemon.changed.notify_waiters();
    let mut line = String::new();
    let (response, delivering) = loop {
        let changed = daemon.changed.notified();
        tokio::pin!(changed);
        changed.as_mut().enable();
        let delivering = daemon.delivering.read().await;
        let answer = {
            let memory = daemon.lock().await;
            match memory.waiters.get(&session) == Some(&number) {
                true => delivery(&daemon, &session),
                false => Some(Response::Replaced),
            }
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
    if let (Some(Response::Events { events, .. }), false) = (&response, sent) {
        put_back(&daemon, &session, events);
    }
    drop(delivering);
    if memory.waiters.get(&session) == Some(&number) {
        memory.waiters.remove(&session);
    }
}

/// The events of an ended key wait for the next wait of the session again.
fn put_back(daemon: &Daemon, session: &str, events: &[KeyedEvent]) {
    let mut keys: Vec<(&str, Mode)> = events.iter().map(|event| (event.key.as_str(), event.mode)).collect();
    keys.dedup();
    let mut state = daemon.store.session(session).unwrap_or_default();
    let count = state.ended.len();
    for (key, mode) in keys {
        let routed: Vec<_> = events
            .iter()
            .filter(|event| event.key == key)
            .map(|event| event.routed.clone())
            .collect();
        daemon.store.put_back_inbox(key, &routed);
        let ended = SessionKey {
            key: key.to_string(),
            mode,
        };
        if daemon.store.sub(key).is_none() && !state.ended.contains(&ended) {
            state.ended.push(ended);
        }
    }
    if state.ended.len() > count {
        daemon.store.write_session(session, &state);
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
