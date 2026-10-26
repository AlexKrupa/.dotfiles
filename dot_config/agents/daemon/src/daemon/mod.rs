//! The watch daemon: one process for each machine, with one poll loop for each repo that has a live
//! subscription.

pub mod store;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::sync::{Mutex, MutexGuard, Notify, RwLock};
use tokio::task::JoinHandle;

use self::store::{Store, first_line};
use crate::core::subs::{Mode, Subscription};
use crate::core::worktrees::{WorktreeState, top_branches};
use crate::engine::event::{Event, EventKind};
use crate::engine::{Engine, EngineArgs, EngineError, GitlabEngine, MrCache, remote_url, split_remote};
use crate::key::repo_slug;
use crate::local::{
    FetchError, conflict, fast_forward, fetch, list_worktrees, repo_of, shared_refs, spice_log, worktree_key,
};
use crate::nap::{NapEnd, nap};
use crate::paths::StateDirs;
use crate::platform::{full_wake, now_seconds, online};

const LOCK_FD: &str = "WATCHD_LOCK_FD";
const SOCKET_FD: &str = "WATCHD_SOCKET_FD";
/// Short, so that a poke or a stop gets an answer in seconds.
const NAP_STEP: u64 = 2;

fn env_seconds(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

fn engine_of(dirs: &StateDirs) -> Box<dyn Engine> {
    #[cfg(feature = "test-support")]
    if let Some(dir) = std::env::var_os("WATCHD_FAKE_ENGINE").filter(|value| !value.is_empty()) {
        return Box::new(crate::engine::fake::FakeEngine {
            dir: dir.into(),
            engine_dir: dirs.engine.clone(),
        });
    }
    Box::new(GitlabEngine { dirs: dirs.clone() })
}

pub struct Daemon {
    pub store: Store,
    /// Each change of the state files and of `Memory` holds this lock.
    pub memory: Mutex<Memory>,
    pub changed: Notify,
    /// A delivery holds it for read from the inbox removal to the end of its send: a restart or a
    /// stop that takes it for write loses no delivery.
    pub delivering: RwLock<()>,
    stopping: AtomicBool,
    stop: Notify,
    pub tick: u64,
    idle_seconds: u64,
    pub client_seconds: u64,
    /// The test value of both intervals of the managed loops.
    managed_seconds: Option<u64>,
    engine: Box<dyn Engine>,
}

#[derive(Default)]
pub struct Memory {
    /// The slug and the client token of the poke of each key.
    pokes: HashMap<String, (String, String)>,
    /// The token of the last poke that a check of the key handled.
    pub poked: HashMap<String, String>,
    pub rounds: HashMap<String, u64>,
    fails: HashMap<String, u32>,
    pub last_poll: BTreeMap<String, i64>,
    pub next_round: BTreeMap<String, i64>,
    /// The daemon does not exit while a `follow` client is connected.
    pub followers: usize,
    repos: HashMap<String, RepoTask>,
    managed: HashMap<PathBuf, RepoTask>,
    pub clients: HashMap<String, u32>,
}

struct RepoTask {
    handle: JoinHandle<()>,
    wake: Arc<Notify>,
}

impl Daemon {
    pub fn stopping(&self) -> bool {
        self.stopping.load(Ordering::SeqCst)
    }

    pub async fn lock(&self) -> MutexGuard<'_, Memory> {
        self.memory.lock().await
    }

    pub fn poke(&self, memory: &mut Memory, key: &str, slug: &str, token: &str) {
        memory
            .pokes
            .insert(key.to_string(), (slug.to_string(), token.to_string()));
        if let Some(task) = memory.repos.get(slug) {
            task.wake.notify_waiters();
        }
    }

    pub fn forget(&self, memory: &mut Memory, key: &str) {
        memory.pokes.remove(key);
        memory.poked.remove(key);
        memory.rounds.remove(key);
        memory.fails.remove(key);
    }

    pub fn ensure_repo(self: &Arc<Self>, memory: &mut Memory, slug: &str) {
        if self.stopping() || memory.repos.get(slug).is_some_and(|task| !task.handle.is_finished()) {
            return;
        }
        let wake = Arc::new(Notify::new());
        let handle = tokio::spawn(repo_loop(self.clone(), slug.to_string(), wake.clone()));
        memory.repos.insert(slug.to_string(), RepoTask { handle, wake });
    }

    pub fn ensure_managed(self: &Arc<Self>, memory: &mut Memory, repo: &Path) {
        if self.stopping() || memory.managed.get(repo).is_some_and(|task| !task.handle.is_finished()) {
            return;
        }
        let wake = Arc::new(Notify::new());
        let handle = tokio::spawn(managed_loop(self.clone(), repo.to_path_buf(), wake.clone()));
        memory.managed.insert(repo.to_path_buf(), RepoTask { handle, wake });
    }

    /// A wake that comes during a round starts the next round at once.
    pub fn wake_managed(&self, memory: &Memory, repo: &Path) {
        if let Some(task) = memory.managed.get(repo) {
            task.wake.notify_one();
        }
    }

    fn begin_stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        self.stop.notify_waiters();
    }

    async fn sleep_or_stop(&self, seconds: u64) {
        let stop = self.stop.notified();
        tokio::pin!(stop);
        stop.as_mut().enable();
        if self.stopping() {
            return;
        }
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(seconds)) => {}
            _ = stop => {}
        }
    }

    /// Returns true for a network error.
    async fn check(self: &Arc<Self>, sub: Subscription, skip: Vec<u64>, cache: Arc<MrCache>) -> bool {
        let poke = self.lock().await.pokes.remove(&sub.key).map(|(_, token)| token);
        let args = EngineArgs {
            repo: Some(sub.repo.clone()),
            fresh: false,
            review: sub.mode == Mode::Review,
            mrs: match sub.mode {
                Mode::Hub => Vec::new(),
                Mode::Stack => sub.mrs.clone(),
                Mode::Review => sub.mrs.iter().take(1).copied().collect(),
            },
            skip_mrs: match sub.mode {
                Mode::Hub => skip,
                Mode::Stack | Mode::Review => Vec::new(),
            },
        };
        let result = self.engine.check(args, cache).await;
        let mut memory = self.lock().await;
        let (slug, key) = (sub.slug.as_str(), sub.key.as_str());
        let mut network = false;
        match result {
            Ok(events) => {
                memory.fails.remove(key);
                let routed = match events.is_empty() {
                    true => Vec::new(),
                    false => self.store.route(&sub, events, now_seconds()),
                };
                self.store.prune_items(&sub);
                if self.store.end_mrs(key, &routed) {
                    self.forget(&mut memory, key);
                }
            }
            Err(EngineError::Network(text)) => {
                self.store
                    .log(slug, key, &format!("network error: {}", first_line(&text)));
                network = true;
            }
            Err(EngineError::Permanent(text)) => {
                self.store.log(slug, key, &format!("error: {}", first_line(&text)));
                if let Some(current) = self.store.sub(key) {
                    self.store.remove_record(&current, "permanent error", Some(&text));
                }
                self.forget(&mut memory, key);
            }
            Err(EngineError::Other(text)) => {
                let fails = memory.fails.get(key).copied().unwrap_or(0) + 1;
                memory.fails.insert(key.to_string(), fails);
                self.store
                    .log(slug, key, &format!("error {fails} of 5: {}", first_line(&text)));
                if fails >= 5 {
                    if let Some(current) = self.store.sub(key) {
                        self.store.remove_record(&current, "5 errors in a row", Some(&text));
                    }
                    self.forget(&mut memory, key);
                }
            }
        }
        if self.store.sub(key).is_some() {
            let rounds = memory.rounds.get(key).copied().unwrap_or(0) + 1;
            memory.rounds.insert(key.to_string(), rounds);
            if let Some(token) = poke {
                memory.poked.insert(key.to_string(), token);
            }
        }
        drop(memory);
        self.changed.notify_waiters();
        network
    }

    async fn interrupted(&self, slug: &str) -> bool {
        self.stopping() || self.lock().await.pokes.values().any(|(poked, _)| poked == slug)
    }

    async fn live_subs(&self, slug: &str) -> Vec<Subscription> {
        let _memory = self.lock().await;
        self.store.live_subs(Some(slug))
    }

    /// Two git calls for each repo. Only a worktree with a new key gets a git-spice call, so that an
    /// error of git-spice is in the log one time for each key.
    pub async fn local_round(&self) {
        let known: HashMap<PathBuf, WorktreeState> = self
            .store
            .worktrees()
            .into_iter()
            .map(|state| (state.path.clone(), state))
            .collect();
        let mut seen = HashSet::new();
        let mut changed = Vec::new();
        for repo in self.store.repos() {
            let Ok(worktrees) = list_worktrees(&repo) else {
                seen.extend(
                    known
                        .values()
                        .filter(|state| state.repo == repo)
                        .map(|state| state.path.clone()),
                );
                continue;
            };
            let refs = shared_refs(&repo);
            for worktree in worktrees {
                seen.insert(worktree.path.clone());
                let key = worktree_key(&worktree, &refs);
                if known.get(&worktree.path).is_some_and(|state| state.key == key) {
                    continue;
                }
                let branches = match refs.spice {
                    None => Vec::new(),
                    Some(_) => spice_log(&worktree.path).unwrap_or_else(|text| {
                        self.store
                            .log("", "", &format!("{}: {}", worktree.path.display(), first_line(&text)));
                        Vec::new()
                    }),
                };
                let mut state = WorktreeState::new(worktree.path, repo.clone(), worktree.branch, key, &branches);
                if let (Some(_), Some(default)) = (&refs.origin_default, &refs.default_branch) {
                    // The top branch has the commits of all branches below it.
                    let tops = match state.stack.is_empty() {
                        true => state.branch.clone().into_iter().collect(),
                        false => top_branches(&branches),
                    };
                    for top in tops {
                        match conflict(&state.path, default, &top) {
                            Ok(files) => state.conflict.extend(files),
                            Err(text) => {
                                self.store
                                    .log("", "", &format!("{}: {}", state.path.display(), first_line(&text)))
                            }
                        }
                    }
                    state.conflict.sort();
                    state.conflict.dedup();
                }
                changed.push(state);
            }
        }
        let gone: Vec<&PathBuf> = known.keys().filter(|path| !seen.contains(*path)).collect();
        if changed.is_empty() && gone.is_empty() {
            return;
        }
        let memory = self.lock().await;
        for state in &changed {
            self.store.write_worktree(state);
        }
        for path in gone {
            self.store.remove_worktree(path);
        }
        drop(memory);
        self.changed.notify_waiters();
    }

    async fn is_managed(&self, repo: &Path) -> bool {
        let _memory = self.lock().await;
        self.store.repos().iter().any(|known| known == repo)
    }

    /// 120 seconds while a hub of the repo is live, else 900.
    async fn managed_interval(&self, slug: &str) -> u64 {
        if let Some(seconds) = self.managed_seconds {
            return seconds;
        }
        let hub = self.live_subs(slug).await.iter().any(|sub| sub.mode == Mode::Hub);
        if hub { 120 } else { 900 }
    }

    /// Returns false if the loop must stop.
    async fn wait_network(&self, repo: &Path, host: Option<&str>) -> bool {
        while !online(host).await {
            self.sleep_or_stop(10).await;
            if self.stopping() || !self.is_managed(repo).await {
                return false;
            }
        }
        true
    }

    /// One open item while the fast-forward is blocked: an unchanged reason sends no new event.
    async fn pull(&self, slug: &str, repo: &Path, default: &str) {
        let (main, branch) = (repo.to_path_buf(), default.to_string());
        let result = tokio::task::spawn_blocking(move || fast_forward(&main, &branch))
            .await
            .unwrap_or(Ok(false));
        let item = format!("pull:{default}");
        let memory = self.lock().await;
        match result {
            Ok(moved) => {
                if moved {
                    self.store.log(slug, "", &format!("fast-forward: {default}"));
                }
                self.store.close_item(slug, &item);
            }
            Err(blocked) => {
                let text = blocked.text(default);
                let open = self.store.open_item(slug, &item).and_then(|open| open.event);
                if open.is_some_and(|event| event.detail == text) {
                    return;
                }
                self.store.log(slug, "", &format!("pull blocked: {text}"));
                let event = Event {
                    item: Some(item),
                    ..Event::new(EventKind::PullBlocked, None, None, "", "", &text, default)
                };
                self.store.pull_blocked(slug, event);
            }
        }
        drop(memory);
        self.changed.notify_waiters();
    }

    /// Returns false if the loop must stop.
    async fn wait_online(&self, slug: &str, host: Option<&str>) -> bool {
        while !online(host).await {
            self.sleep_or_stop(10).await;
            if self.stopping() || self.live_subs(slug).await.is_empty() {
                return false;
            }
        }
        true
    }
}

async fn repo_loop(daemon: Arc<Daemon>, slug: String, wake: Arc<Notify>) {
    daemon.store.log(&slug, "", "repo loop start");
    loop {
        if daemon.stopping() {
            break;
        }
        let subs = daemon.live_subs(&slug).await;
        if subs.is_empty() {
            break;
        }
        let mut skip = Vec::new();
        {
            let _memory = daemon.lock().await;
            for sub in subs.iter().filter(|sub| sub.mode == Mode::Review) {
                if let Some(iid) = sub.mrs.first() {
                    skip.push(*iid);
                    daemon.store.move_items(&slug, &sub.key, Some(*iid));
                }
            }
        }
        let round = std::env::temp_dir().join(format!("watchd-round-{}-{slug}-{}", std::process::id(), now_seconds()));
        let _ = std::fs::create_dir_all(&round);
        let cache = Arc::new(MrCache::new(round.clone()));
        let mut checks = tokio::task::JoinSet::new();
        for sub in subs.clone() {
            let (daemon, skip, cache) = (daemon.clone(), skip.clone(), cache.clone());
            checks.spawn(async move { daemon.check(sub, skip, cache).await });
        }
        let mut network = false;
        while let Some(result) = checks.join_next().await {
            network |= result.unwrap_or(false);
        }
        let _ = std::fs::remove_dir_all(&round);
        {
            let mut memory = daemon.lock().await;
            memory.last_poll.insert(slug.clone(), now_seconds());
            daemon
                .store
                .log(&slug, "", &format!("round done: {} subscription(s)", subs.len()));
        }
        if daemon.stopping() {
            break;
        }
        let remote = remote_url(&subs[0].repo);
        let host = remote
            .as_deref()
            .and_then(split_remote)
            .map(|(host, _)| host.to_string());
        // A network error with the network up, as for HTTP 502, gets the normal wait.
        if network && !online(host.as_deref()).await {
            match daemon.wait_online(&slug, host.as_deref()).await {
                true => continue,
                false => break,
            }
        }
        let interval = subs.iter().map(|sub| sub.interval).min().unwrap_or(120);
        daemon
            .lock()
            .await
            .next_round
            .insert(slug.clone(), now_seconds() + interval as i64);
        let sleep = |step: u64| {
            let (daemon, wake, slug) = (daemon.clone(), wake.clone(), slug.clone());
            async move {
                let woken = wake.notified();
                let stop = daemon.stop.notified();
                tokio::pin!(woken, stop);
                woken.as_mut().enable();
                stop.as_mut().enable();
                if daemon.interrupted(&slug).await {
                    return true;
                }
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(step)) => false,
                    _ = woken => true,
                    _ = stop => true,
                }
            }
        };
        let end = nap(interval, NAP_STEP, now_seconds, |step| {
            let sleep = sleep(step);
            async move { (sleep.await, full_wake().await) }
        })
        .await;
        if end == NapEnd::Asleep && !daemon.wait_online(&slug, host.as_deref()).await {
            break;
        }
    }
    let mut memory = daemon.lock().await;
    memory.last_poll.remove(&slug);
    memory.next_round.remove(&slug);
    daemon.store.log(&slug, "", "repo loop stop");
}

/// The fetch of the default branch and the fast-forward of the main checkout.
async fn managed_loop(daemon: Arc<Daemon>, repo: PathBuf, wake: Arc<Notify>) {
    let slug = match repo_slug(&repo) {
        Ok(slug) => slug,
        Err(text) => {
            daemon
                .store
                .log("", "", &format!("no managed loop for {}: {text}", repo.display()));
            return;
        }
    };
    daemon
        .store
        .log(&slug, "", &format!("managed loop start: {}", repo.display()));
    let host = remote_url(&repo)
        .as_deref()
        .and_then(split_remote)
        .map(|(host, _)| host.to_string());
    let mut no_default_logged = false;
    loop {
        if daemon.stopping() || !daemon.is_managed(&repo).await {
            break;
        }
        match shared_refs(&repo).default_branch {
            None if no_default_logged => {}
            None => {
                daemon.store.log(&slug, "", "no default branch: origin/HEAD is not set");
                no_default_logged = true;
            }
            Some(default) => {
                no_default_logged = false;
                let (folder, branch) = (repo.clone(), default.clone());
                let fetched = tokio::task::spawn_blocking(move || fetch(&folder, &branch))
                    .await
                    .unwrap_or_else(|error| Err(FetchError::Other(error.to_string())));
                match fetched {
                    Ok(()) => daemon.pull(&slug, &repo, &default).await,
                    Err(FetchError::Network(text)) if !online(host.as_deref()).await => {
                        daemon
                            .store
                            .log(&slug, "", &format!("network down: {}", first_line(&text)));
                        match daemon.wait_network(&repo, host.as_deref()).await {
                            true => continue,
                            false => break,
                        }
                    }
                    Err(FetchError::Network(text) | FetchError::Other(text)) => {
                        daemon.store.log(&slug, "", first_line(&text));
                    }
                }
            }
        }
        let interval = daemon.managed_interval(&slug).await;
        let sleep = |step: u64| {
            let (daemon, wake) = (daemon.clone(), wake.clone());
            async move {
                let woken = wake.notified();
                let stop = daemon.stop.notified();
                tokio::pin!(woken, stop);
                stop.as_mut().enable();
                if daemon.stopping() {
                    return true;
                }
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(step)) => false,
                    _ = woken => true,
                    _ = stop => true,
                }
            }
        };
        let end = nap(interval, NAP_STEP, now_seconds, |step| {
            let sleep = sleep(step);
            async move { (sleep.await, full_wake().await) }
        })
        .await;
        if end == NapEnd::Asleep && !daemon.wait_network(&repo, host.as_deref()).await {
            break;
        }
    }
    daemon
        .store
        .log(&slug, "", &format!("managed loop stop: {}", repo.display()));
}

fn inode(path: &std::path::Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|meta| meta.ino())
}

fn inherited_fd(name: &str) -> Option<RawFd> {
    let fd = std::env::var(name).ok()?.parse().ok()?;
    // SAFETY: the daemon removes the variable before it starts a child.
    unsafe { std::env::remove_var(name) };
    // SAFETY: fcntl on an open descriptor.
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    Some(fd)
}

/// A `flock` goes away with the process, also after `kill -9`.
fn take_lock(dirs: &StateDirs) -> Option<std::fs::File> {
    if let Some(fd) = inherited_fd(LOCK_FD) {
        // SAFETY: the image before the exec left this descriptor open for this image.
        return Some(unsafe { std::fs::File::from_raw_fd(fd) });
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dirs.lock())
        .ok()?;
    // SAFETY: flock on an open descriptor.
    match unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } {
        0 => Some(file),
        _ => None,
    }
}

fn listen(dirs: &StateDirs) -> std::io::Result<std::os::unix::net::UnixListener> {
    if let Some(fd) = inherited_fd(SOCKET_FD) {
        // SAFETY: the image before the exec left this listener open for this image.
        return Ok(unsafe { std::os::unix::net::UnixListener::from_raw_fd(fd) });
    }
    // With the lock held, a socket file is from a daemon that died.
    let _ = std::fs::remove_file(dirs.socket());
    std::os::unix::net::UnixListener::bind(dirs.socket())
}

fn keep_open(fd: RawFd) {
    // SAFETY: fcntl on an open descriptor.
    unsafe { libc::fcntl(fd, libc::F_SETFD, 0) };
}

enum End {
    Stop,
    Restart,
}

pub async fn main() -> i32 {
    let _ = std::env::set_current_dir("/");
    let dirs = StateDirs::from_env();
    let store = Store::new(dirs.clone());
    if let Err(error) = store.ensure_dirs() {
        eprintln!("watchd: {}: {error}", dirs.watchd.display());
        return 1;
    }
    let Some(lock) = take_lock(&dirs) else { return 0 };
    store.trim_log();
    let listener = match listen(&dirs) {
        Ok(listener) => listener,
        Err(error) => {
            store.log("", "", &format!("no socket: {error}"));
            return 1;
        }
    };
    let pid = std::process::id();
    let _ = std::fs::write(dirs.pid(), format!("{pid}\n"));
    store.log("", "", &format!("daemon start {pid}"));
    let daemon = Arc::new(Daemon {
        store,
        memory: Mutex::default(),
        changed: Notify::new(),
        delivering: RwLock::new(()),
        stopping: AtomicBool::new(false),
        stop: Notify::new(),
        tick: env_seconds("WATCHD_TICK", 5),
        idle_seconds: env_seconds("WATCHD_IDLE_SECONDS", 600),
        client_seconds: env_seconds("WATCHD_CLIENT_SECONDS", 1800),
        managed_seconds: std::env::var("WATCHD_MANAGED_SECONDS")
            .ok()
            .and_then(|value| value.parse().ok()),
        engine: engine_of(&dirs),
    });
    let socket_fd = listener.as_raw_fd();
    let _ = listener.set_nonblocking(true);
    let listener = tokio::net::UnixListener::from_std(listener).expect("a listener in the runtime");
    tokio::spawn(crate::server::serve(daemon.clone(), listener));
    let end = run(&daemon).await;
    daemon.begin_stop();
    let tasks: Vec<JoinHandle<()>> = {
        let mut memory = daemon.lock().await;
        let repos = memory.repos.drain().map(|(_, task)| task.handle).collect::<Vec<_>>();
        repos
            .into_iter()
            .chain(memory.managed.drain().map(|(_, task)| task.handle))
            .collect()
    };
    for task in tasks {
        let _ = task.await;
    }
    let _deliveries = daemon.delivering.write().await;
    match end {
        End::Restart => {
            let _memory = daemon.lock().await;
            keep_open(lock.as_raw_fd());
            keep_open(socket_fd);
            let exe = std::env::current_exe().unwrap_or_default();
            let error = std::os::unix::process::CommandExt::exec(
                std::process::Command::new(&exe)
                    .arg("daemon")
                    .env(LOCK_FD, lock.as_raw_fd().to_string())
                    .env(SOCKET_FD, socket_fd.to_string()),
            );
            daemon
                .store
                .log("", "", &format!("restart failed: {}: {error}", exe.display()));
            1
        }
        End::Stop => {
            let _memory = daemon.lock().await;
            let pid_file = std::fs::read_to_string(dirs.pid()).unwrap_or_default();
            if pid_file.trim() == pid.to_string() {
                let _ = std::fs::remove_file(dirs.pid());
            }
            daemon.store.log("", "", &format!("daemon stop {pid}"));
            0
        }
    }
}

async fn run(daemon: &Arc<Daemon>) -> End {
    use tokio::signal::unix::{SignalKind, signal};
    let (Ok(mut terminate), Ok(mut interrupt)) = (signal(SignalKind::terminate()), signal(SignalKind::interrupt()))
    else {
        daemon.store.log("", "", "no signal handlers");
        return End::Stop;
    };
    let exe = std::env::current_exe().unwrap_or_default();
    let start = inode(&exe);
    let mut seen = start;
    let mut idle_since = now_seconds();
    let mut pruned_at = 0;
    {
        let _memory = daemon.lock().await;
        for sub in daemon.store.subs() {
            if let Some(repo) = repo_of(&sub.repo) {
                daemon.store.add_repo(&repo);
            }
        }
    }
    loop {
        // An install renames a new file over the binary: a new inode that stays for one tick is a
        // complete update.
        let current = inode(&exe);
        if current.is_some() && current != start && current == seen {
            daemon.store.log("", "", "restart: waiting for the repo loops");
            return End::Restart;
        }
        seen = current;
        let now = now_seconds();
        let mut memory = daemon.lock().await;
        if now - pruned_at >= 3600 {
            daemon.store.prune(now);
            pruned_at = now;
        }
        for sub in daemon.store.subs() {
            if daemon.store.end_if_due(&sub, now, daemon.client_seconds as i64) {
                daemon.forget(&mut memory, &sub.key);
            }
        }
        daemon.store.sweep();
        for repo in daemon.store.drop_gone_repos() {
            daemon.store.log("", "", &format!("repo gone: {}", repo.display()));
        }
        let mut slugs: Vec<String> = daemon.store.live_subs(None).into_iter().map(|sub| sub.slug).collect();
        slugs.sort();
        slugs.dedup();
        if !slugs.is_empty() || memory.followers > 0 {
            idle_since = now;
        } else if now - idle_since >= daemon.idle_seconds as i64 {
            daemon.store.log("", "", "idle stop");
            return End::Stop;
        }
        for slug in &slugs {
            daemon.ensure_repo(&mut memory, slug);
        }
        for repo in daemon.store.repos() {
            daemon.ensure_managed(&mut memory, &repo);
        }
        drop(memory);
        daemon.local_round().await;
        daemon.changed.notify_waiters();
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(daemon.tick)) => {}
            _ = terminate.recv() => return End::Stop,
            _ = interrupt.recv() => return End::Stop,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inherited_fd_closes_on_the_next_exec() {
        let file = std::fs::File::open("/dev/null").unwrap();
        keep_open(file.as_raw_fd());
        // SAFETY: no other test reads this variable.
        unsafe { std::env::set_var("WATCHD_TEST_INHERITED_FD", file.as_raw_fd().to_string()) };

        let fd = inherited_fd("WATCHD_TEST_INHERITED_FD").unwrap();

        // SAFETY: fcntl on an open descriptor.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        assert_eq!(flags & libc::FD_CLOEXEC, libc::FD_CLOEXEC);
    }
}
