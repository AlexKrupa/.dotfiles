//! The watch daemon: one process for each machine. A client starts it when no daemon runs. It runs
//! one poll loop for each repo with a live subscription. A subscription is live while its session
//! process runs. Each round runs the check of each live subscription of the repo, and routes the
//! events to the client of the subscription. The hub check skips the MRs of the live review
//! subscriptions. The fetched MRs go to a cache of the round. Thus two subscriptions of one MR get
//! one fetch. The round interval is the smallest interval of the subscriptions of the repo.
//! A network error does not count: the loop waits for the network, with no limit. A permanent
//! error, or 5 other errors in a row, end the subscription, and its client gets the error text.
//! A subscription also ends when all its MRs are merged or closed, and after 30 minutes with no
//! client. The next client of its session still gets the events and the error that wait.
//! With no subscription for 10 minutes, the daemon exits. When the binary changes, it completes
//! the current round of each repo and starts the new binary with the same PID.

pub mod store;

use std::collections::{BTreeMap, HashMap};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::fs::MetadataExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::sync::{Mutex, MutexGuard, Notify, RwLock};
use tokio::task::JoinHandle;

use self::store::{Store, first_line};
use crate::core::subs::{Mode, Subscription};
use crate::engine::{Engine, EngineArgs, EngineError, GitlabEngine, MrCache, remote_url, split_remote};
use crate::nap::{NapEnd, nap};
use crate::paths::StateDirs;
use crate::platform::{full_wake, now_seconds, online};

const LOCK_FD: &str = "WATCHD_LOCK_FD";
const SOCKET_FD: &str = "WATCHD_SOCKET_FD";
/// A short nap step, so that a poke or a stop gets an answer in seconds.
const NAP_STEP: u64 = 2;

fn env_seconds(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(default)
}

/// The fake engine of the tests with `WATCHD_FAKE_ENGINE=<folder>`, in a build with the
/// `test-support` feature only.
fn engine_of(dirs: &StateDirs) -> Box<dyn Engine> {
    #[cfg(feature = "test-support")]
    if let Some(dir) = std::env::var_os("WATCHD_FAKE_ENGINE").filter(|value| !value.is_empty()) {
        return Box::new(crate::engine::fake::FakeEngine { dir: dir.into(), engine_dir: dirs.engine.clone() });
    }
    Box::new(GitlabEngine { dirs: dirs.clone() })
}

pub struct Daemon {
    pub store: Store,
    /// The state lock: each change of the state files and of `Memory` holds it.
    pub memory: Mutex<Memory>,
    /// A change for the waiting clients.
    pub changed: Notify,
    /// Read by each delivery from the removal of the inbox to the end of its send. A restart or a
    /// stop takes it for write: no delivery is lost.
    pub delivering: RwLock<()>,
    stopping: AtomicBool,
    stop: Notify,
    pub tick: u64,
    idle_seconds: u64,
    pub client_seconds: u64,
    engine: Box<dyn Engine>,
}

/// The state that a new fetch gives back: it stays in memory only.
#[derive(Default)]
pub struct Memory {
    /// The poke of each key: its slug and the token of the client.
    pokes: HashMap<String, (String, String)>,
    /// The token of the last poke that a check of the key handled.
    pub poked: HashMap<String, String>,
    pub rounds: HashMap<String, u64>,
    fails: HashMap<String, u32>,
    pub last_poll: BTreeMap<String, i64>,
    /// The end of the nap of each repo loop.
    pub next_round: BTreeMap<String, i64>,
    /// The connected `follow` clients. The daemon does not exit while one is connected.
    pub followers: usize,
    repos: HashMap<String, RepoTask>,
    /// The connected client of each key.
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

    /// A round of the repo of `key` now.
    pub fn poke(&self, memory: &mut Memory, key: &str, slug: &str, token: &str) {
        memory.pokes.insert(key.to_string(), (slug.to_string(), token.to_string()));
        if let Some(task) = memory.repos.get(slug) {
            task.wake.notify_waiters();
        }
    }

    /// Removes the memory of an ended subscription.
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

    /// One check of the subscription `sub`. True for a network error.
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
                self.store.log(slug, key, &format!("network error: {}", first_line(&text)));
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
                self.store.log(slug, key, &format!("error {fails} of 5: {}", first_line(&text)));
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

    /// True if a subscription of the repo asks for a round now, or the daemon stops.
    async fn interrupted(&self, slug: &str) -> bool {
        self.stopping() || self.lock().await.pokes.values().any(|(poked, _)| poked == slug)
    }

    async fn live_subs(&self, slug: &str) -> Vec<Subscription> {
        let _memory = self.lock().await;
        self.store.live_subs(Some(slug))
    }

    /// The wait for the network has no limit, but a stop, or the end of the subscriptions of the
    /// repo, ends it. False if the loop must stop.
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
        // A live review key takes the open hub items of its MR.
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
        let round = std::env::temp_dir().join(format!(
            "watchd-round-{}-{slug}-{}",
            std::process::id(),
            now_seconds()
        ));
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
            daemon.store.log(&slug, "", &format!("round done: {} subscription(s)", subs.len()));
        }
        if daemon.stopping() {
            break;
        }
        let remote = remote_url(&subs[0].repo);
        let host = remote.as_deref().and_then(split_remote).map(|(host, _)| host.to_string());
        // With the network up, as for HTTP 502, the normal wait follows.
        if network && !online(host.as_deref()).await {
            match daemon.wait_online(&slug, host.as_deref()).await {
                true => continue,
                false => break,
            }
        }
        let interval = subs.iter().map(|sub| sub.interval).min().unwrap_or(120);
        daemon.lock().await.next_round.insert(slug.clone(), now_seconds() + interval as i64);
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

fn inode(path: &std::path::Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|meta| meta.ino())
}

/// An open file descriptor of the image before an `exec`, or `None`.
fn inherited_fd(name: &str) -> Option<RawFd> {
    let fd = std::env::var(name).ok()?.parse().ok()?;
    // SAFETY: the daemon removes the variable before it starts a child.
    unsafe { std::env::remove_var(name) };
    // The children of this image must not hold the lock or the listener.
    // SAFETY: fcntl on an open descriptor.
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    Some(fd)
}

/// The lock of the one daemon: it goes away with the process, also after `kill -9`.
fn take_lock(dirs: &StateDirs) -> Option<std::fs::File> {
    if let Some(fd) = inherited_fd(LOCK_FD) {
        // SAFETY: the image before the exec left this descriptor open for this image.
        return Some(unsafe { std::fs::File::from_raw_fd(fd) });
    }
    let file = std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(dirs.lock()).ok()?;
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
    // The lock makes sure that no daemon listens: a socket file is of a daemon that died.
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

/// The `daemon` subcommand.
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
        engine: engine_of(&dirs),
    });
    let socket_fd = listener.as_raw_fd();
    let _ = listener.set_nonblocking(true);
    let listener = tokio::net::UnixListener::from_std(listener).expect("a listener in the runtime");
    tokio::spawn(crate::server::serve(daemon.clone(), listener));
    let end = run(&daemon).await;
    daemon.begin_stop();
    let tasks: Vec<JoinHandle<()>> = daemon.lock().await.repos.drain().map(|(_, task)| task.handle).collect();
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
            daemon.store.log("", "", &format!("restart failed: {}: {error}", exe.display()));
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
    let (Ok(mut terminate), Ok(mut interrupt)) =
        (signal(SignalKind::terminate()), signal(SignalKind::interrupt()))
    else {
        daemon.store.log("", "", "no signal handlers");
        return End::Stop;
    };
    let exe = std::env::current_exe().unwrap_or_default();
    let start = inode(&exe);
    let mut seen = start;
    let mut idle_since = now_seconds();
    let mut pruned_at = 0;
    loop {
        // The install renames a new file over the binary: a new inode that stays for one tick is
        // the full update.
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
        drop(memory);
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
