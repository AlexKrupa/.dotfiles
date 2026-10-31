//! The socket server of the daemon: a `wait` client keeps its connection until its delivery or an
//! error.

use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use serde_json::json;
use tokio::io::AsyncWriteExt;

use tokio::io::BufReader;
use tokio::net::{UnixListener, UnixStream};
use tokio::task::block_in_place;

use crate::core::eventlog::{LogLine, id_of, route_line};
use crate::core::subs::{Mode, SessionKey};
use crate::core::worktrees::{ReviewLink, set_kind};
use crate::daemon::Daemon;
use crate::daemon::store::Store;
use crate::key::worktree_top;
use crate::local::repo_of;
use crate::paths::session_id;
use crate::platform::{now_seconds, process_alive};
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
                daemon.log("", "", &format!("accept: {error}"));
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
    if let Some(Err(message)) = session_of(&request).map(|id| session_id(Some(id.to_string()))) {
        let text = format!("watchd: {message}\n");
        let _ = send(&mut write, &Response::Error { text }).await;
        return;
    }
    // A follower reads all state, and a waiter reads the state of its session: they use no repo.
    let folder = folder.filter(|_| {
        !matches!(
            request,
            Request::Follow { .. } | Request::Wait { .. } | Request::Subscribe(_)
        )
    });
    if let Some(repo) = folder.as_deref().and_then(|folder| block_in_place(|| repo_of(folder))) {
        daemon.lock().await.store.add_repo(&repo);
    }
    let response = match request {
        Request::Watch(request) => watch(&daemon, &request).await,
        Request::Wait {
            session,
            owner_pid,
            rename_owner_session,
        } => return wait(daemon, session, owner_pid, rename_owner_session, reader, write).await,
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
                followers: Some(daemon.followers.load(Ordering::SeqCst)),
                ..memory.store.debug_disk()
            }))
        }
        Request::Unsubscribe {
            key,
            slug,
            mode,
            session,
        } => {
            let mut memory = daemon.lock().await;
            let result = memory.store.unsubscribe(&key, &slug, mode, &session);
            if result.is_ok() {
                memory.forget(&key);
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
            let top = folder
                .as_deref()
                .and_then(|folder| block_in_place(|| worktree_top(folder)).ok());
            if let Some(top) = top.and_then(|top| top.canonicalize().ok()) {
                let memory = daemon.lock().await;
                let live = memory
                    .store
                    .live_subs(None)
                    .iter()
                    .any(|agent| agent.repo.canonicalize().is_ok_and(|repo| repo == top));
                memory.store.update_worktree(&top, |state| set_kind(state, kind, live));
                daemon.changed.notify_waiters();
            }
            Response::Ok
        }
        Request::Route { key, iid, action } => {
            daemon
                .lock()
                .await
                .store
                .event_log(vec![LogLine::Route(route_line(now_seconds(), &key, iid, action))]);
            daemon.changed.notify_waiters();
            Response::Ok
        }
        Request::Report { key, mode, mrs, input } => match daemon.lock().await.store.report(&key, mode, &mrs, &input) {
            Ok(text) => Response::Report { text },
            Err(text) => Response::Error { text },
        },
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
                subs: memory.store.sub_status(),
            })
        }
    };
    let _ = send(&mut write, &response).await;
}

/// The session ID is a file name of the daemon. A request that does not come from the client can
/// have any text.
fn session_of(request: &Request) -> Option<&str> {
    match request {
        Request::Watch(watch) => Some(&watch.session),
        Request::Wait { session, .. } | Request::Unsubscribe { session, .. } => Some(session),
        Request::Subscribe(_)
        | Request::Status
        | Request::Kind { .. }
        | Request::Route { .. }
        | Request::Report { .. }
        | Request::DebugState
        | Request::Follow { .. } => None,
    }
}

async fn watch(daemon: &Arc<Daemon>, request: &WatchRequest) -> Response {
    // `--repo` can name a repo other than the folder of the client.
    let repo = block_in_place(|| repo_of(&request.repo));
    {
        let mut memory = daemon.lock().await;
        if request.fresh {
            let _ = std::fs::remove_file(daemon.dirs.engine_state(&request.key));
        }
        memory.store.watch(request, now_seconds());
        memory.poke(&request.key, &request.slug);
        if let Some(repo) = repo.filter(|_| !daemon.stopping()) {
            memory.store.add_repo(&repo);
            daemon.ensure_managed(&mut memory, &repo);
        }
        // The polling of a reviewed MR goes on after the agent ends.
        if let (Mode::Review, Some(iid), Ok(worktree)) =
            (request.mode, request.mrs.first(), request.repo.canonicalize())
        {
            memory.store.add_review(ReviewLink { worktree, iid: *iid });
        }
    }
    daemon.changed.notify_waiters();
    Response::Ok
}

fn pending(store: &Store, session: &str) -> bool {
    let state = store.session(session).unwrap_or_default();
    let records = store.session_subs(session);
    !state.ended.is_empty() || !state.replaced.is_empty() || records.iter().any(|sub| store.inbox_lines(&sub.key) > 0)
}

/// Returns `None` while the waiter waits, and the ended key of an `Error`. The session takes the
/// keys of its records and the keys that ended since its last wait. If a different session has a
/// new record of an ended key, the error stays here and the inbox goes to the record. An ended key
/// stays in `ended` after its error, so that the next delivery takes its inbox.
fn delivery(store: &Store, session: &str) -> Option<(Response, Option<SessionKey>)> {
    let records = store.session_subs(session);
    let mut state = store.session(session).unwrap_or_default();
    if let Some((ended, text)) = state
        .ended
        .iter()
        .find_map(|ended| Some((ended.clone(), store.take_error(&ended.key)?)))
    {
        return Some((Response::Error { text }, Some(ended)));
    }
    let ended = state
        .ended
        .iter()
        .filter(|ended| store.sub(&ended.key).is_none())
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
        let taken = store.take_inbox_of(key, filter);
        if taken.is_empty() {
            continue;
        }
        store.write_last(key, &taken);
        // The report shows all rows, and the model gets the rows that the router did not handle.
        let handled = store.routing(key).handled;
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
        store.write_session(session, &state);
    }
    match (events.is_empty() && replaced.is_empty(), records.is_empty()) {
        (false, _) | (true, true) => Some((Response::Events { events, replaced }, None)),
        (true, false) => None,
    }
}

async fn wait(
    daemon: Arc<Daemon>,
    session: String,
    owner_pid: u32,
    rename_owner_session: bool,
    mut reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    mut write: tokio::net::unix::OwnedWriteHalf,
) {
    let number = {
        let mut memory = daemon.lock().await;
        if rename_owner_session && let Some(old) = memory.store.rename_session(&session, owner_pid) {
            memory.waiters.remove(&old);
        }
        // A session with no watch gets no record: its next wait does not start the daemon.
        if let Some(mut state) = memory.store.session(&session) {
            state.owner_pid = Some(owner_pid);
            state.owner_gone_at = None;
            memory.store.write_session(&session, &state);
        }
        for other in memory.store.leave_other_sessions(&session, owner_pid, now_seconds()) {
            memory.waiters.remove(&other);
        }
        memory.next_waiter += 1;
        let number = memory.next_waiter;
        memory.waiters.insert(session.clone(), number);
        number
    };
    // An older waiter of the session gets its answer.
    daemon.changed.notify_waiters();
    let mut line = String::new();
    let (response, error_key, delivering) = loop {
        let changed = daemon.changed.notified();
        tokio::pin!(changed);
        changed.as_mut().enable();
        let delivering = daemon.delivering.read().await;
        let answer = {
            let memory = daemon.lock().await;
            match memory.waiters.get(&session) == Some(&number) {
                // The events of a gone owner stay in the inbox until the session is back. The
                // client exits at its next owner check.
                true if pending(&memory.store, &session) && !process_alive(owner_pid) => None,
                true => delivery(&memory.store, &session),
                false => Some((Response::Replaced, None)),
            }
        };
        if let Some((answer, error_key)) = answer {
            break (Some(answer), error_key, Some(delivering));
        }
        drop(delivering);
        tokio::select! {
            _ = &mut changed => {}
            _ = tokio::time::sleep(Duration::from_secs(1)) => {}
            // The client sends nothing more: a read is the end of its connection.
            _ = tokio::io::AsyncBufReadExt::read_line(&mut reader, &mut line) => break (None, None, None),
        }
    };
    let sent = match &response {
        Some(response) => send(&mut write, response).await.is_ok(),
        None => false,
    };
    let mut memory = daemon.lock().await;
    match (&response, &error_key, sent) {
        (Some(Response::Events { events, replaced }), _, false) => put_back(&memory.store, &session, events, replaced),
        (Some(Response::Error { text }), Some(ended), false) => memory.store.put_back_error(&session, ended, text),
        _ => {}
    }
    drop(delivering);
    if memory.waiters.get(&session) == Some(&number) {
        memory.waiters.remove(&session);
    }
}

fn put_back(store: &Store, session: &str, events: &[KeyedEvent], replaced: &[SessionKey]) {
    let mut keys: Vec<(&str, Mode)> = events.iter().map(|event| (event.key.as_str(), event.mode)).collect();
    keys.dedup();
    let mut state = store.session(session).unwrap_or_default();
    let count = state.ended.len();
    let moved = state.replaced.len();
    for taken in replaced {
        if !state.replaced.contains(taken) {
            state.replaced.push(taken.clone());
        }
    }
    for (key, mode) in keys {
        let routed: Vec<_> = events
            .iter()
            .filter(|event| event.key == key)
            .map(|event| event.routed.clone())
            .collect();
        store.put_back_inbox(key, &routed);
        let ended = SessionKey {
            key: key.to_string(),
            mode,
        };
        if store.sub(key).is_none() && !state.ended.contains(&ended) {
            state.ended.push(ended);
        }
    }
    if state.ended.len() > count || state.replaced.len() > moved {
        store.write_session(session, &state);
    }
}

async fn write_line(write: &mut tokio::net::unix::OwnedWriteHalf, line: &str) -> std::io::Result<()> {
    write.write_all(format!("{line}\n").as_bytes()).await?;
    write.flush().await
}

/// The inode and the byte offset of the end of the last read of the event log.
#[derive(Default)]
struct LogCursor {
    inode: u64,
    offset: u64,
}

/// The complete lines after the cursor. A prune writes a new file: with a new inode, the read starts
/// at the top again.
fn new_lines(path: &Path, cursor: &mut LogCursor) -> Vec<String> {
    let Ok(mut file) = std::fs::File::open(path) else {
        return Vec::new();
    };
    let Ok(meta) = file.metadata() else {
        return Vec::new();
    };
    if meta.ino() != cursor.inode {
        *cursor = LogCursor {
            inode: meta.ino(),
            offset: 0,
        };
    }
    let mut text = String::new();
    if file.seek(SeekFrom::Start(cursor.offset)).is_err() || file.read_to_string(&mut text).is_err() {
        return Vec::new();
    }
    // A line with no newline is not completely written yet.
    let complete = text.rfind('\n').map_or(0, |index| index + 1);
    cursor.offset += complete as u64;
    text[..complete].lines().map(str::to_string).collect()
}

/// Counts a connected follower until its task ends, also with a panic.
struct Follower<'a>(&'a AtomicUsize);

impl<'a> Follower<'a> {
    fn new(count: &'a AtomicUsize) -> Follower<'a> {
        count.fetch_add(1, Ordering::SeqCst);
        Follower(count)
    }
}

impl Drop for Follower<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
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
    let _follower = Follower::new(&daemon.followers);
    let (mut sidebar, newest) = {
        let memory = daemon.lock().await;
        (memory.store.sidebar(), memory.store.last_id())
    };
    let mut first = sidebar.clone();
    first["last_id"] = json!(newest);
    let mut last = after.unwrap_or(newest);
    let mut ok = write_line(&mut write, &first.to_string()).await.is_ok();
    let mut closed = String::new();
    let mut cursor = LogCursor::default();
    while ok {
        // Before the read, so that a line that comes during the read wakes the client up.
        let changed = daemon.changed.notified();
        tokio::pin!(changed);
        changed.as_mut().enable();
        let after = last;
        for line in new_lines(&daemon.dirs.events(), &mut cursor)
            .into_iter()
            .filter(|line| id_of(line) > after)
        {
            last = last.max(id_of(&line));
            ok = ok && write_line(&mut write, &line).await.is_ok();
        }
        let now = daemon.lock().await.store.sidebar();
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_lines_skips_a_partial_line_and_reads_a_new_file_from_the_top() {
        let dir = std::env::temp_dir().join(format!("watchd-server-{}-cursor", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("events.jsonl");
        let mut cursor = LogCursor::default();
        std::fs::write(&path, "a\nb").unwrap();

        let first = new_lines(&path, &mut cursor);
        std::fs::write(dir.join("new"), "c\n").unwrap();
        std::fs::rename(dir.join("new"), &path).unwrap();
        let after_prune = new_lines(&path, &mut cursor);

        assert_eq!(first, ["a"]);
        assert_eq!(after_prune, ["c"]);
    }
}
