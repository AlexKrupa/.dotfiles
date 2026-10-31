//! The watch daemon: one process for each machine, with one managed loop for each managed repo.

pub mod store;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use tokio::sync::{Mutex, MutexGuard, Notify, RwLock};
use tokio::task::{JoinHandle, JoinSet, block_in_place};

use self::store::{Store, first_line};
use crate::core::items::RoutedEvent;
use crate::core::subs::{Agent, Mode};
use crate::core::worktrees::{ReviewLink, Target, WorktreeState, conflict_tests, lookup_branch, targets};
use crate::engine::event::{Event, EventKind};
use crate::engine::router::execute::{ExecuteContext, execute};
use crate::engine::router::retry::Retry;
use crate::engine::router::{self, Facts, Routing};
use crate::engine::state::OwnMr;
use crate::engine::{Engine, EngineArgs, EngineError, GitlabEngine, MrCache, remote_url, split_remote};
use crate::key::{author_key, is_worktree_key, repo_slug};
use crate::local::{
    FETCH_TIMEOUT, FetchError, conflict, fast_forward, fetch, list_worktrees, repo_of, shared_refs, spice_log,
    worktree_key,
};
use crate::nap::{NapEnd, nap};
use crate::paths::{StateDirs, home};
use crate::platform::{full_wake, now_seconds, online};
use crate::workspaces::{Workspaces, workspaces_of};

const LOCK_FD: &str = "WATCHD_LOCK_FD";
const SOCKET_FD: &str = "WATCHD_SOCKET_FD";
/// Short, so that a poke or a stop gets an answer in seconds.
pub(crate) const NAP_STEP: Duration = Duration::from_secs(2);

fn env_seconds(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

/// Fractional seconds, as `0.2`, for the short rounds of the tests.
fn env_duration(name: &str) -> Option<Duration> {
    let seconds: f64 = std::env::var(name).ok()?.parse().ok()?;
    Duration::try_from_secs_f64(seconds).ok()
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
    /// Each read and change of the state files holds this lock: `Memory` has the `Store`.
    memory: Mutex<Memory>,
    /// The paths of the state files, for the log and the event log reads.
    pub dirs: StateDirs,
    pub changed: Notify,
    /// A delivery holds it for read from the inbox removal to the end of its send: a restart or a
    /// stop that takes it for write loses no delivery.
    pub delivering: RwLock<()>,
    stopping: AtomicBool,
    stop: Notify,
    /// The daemon does not exit while a `follow` client is connected.
    pub followers: AtomicUsize,
    /// A stop waits for the retry tasks, so that each retry gets its last row.
    retries: std::sync::Mutex<JoinSet<()>>,
    pub tick: Duration,
    idle_seconds: u64,
    /// An away session ends after this time with no waiter.
    grace_seconds: u64,
    /// The test value of both intervals of the managed loops.
    test_interval: Option<Duration>,
    pub engine: Box<dyn Engine>,
    workspaces: Box<dyn Workspaces>,
    /// The wait between two status reads of a retried job.
    pub retry_interval: Duration,
    /// The longest wait for a retried job, with no sleep time and no network outages.
    pub retry_timeout: Duration,
}

pub struct Memory {
    pub store: Store,
    /// The slug of each poked key.
    pokes: HashMap<String, String>,
    pub rounds: HashMap<String, u64>,
    fails: HashMap<String, u32>,
    pub last_poll: BTreeMap<String, i64>,
    pub next_round: BTreeMap<String, i64>,
    managed: HashMap<PathBuf, ManagedTask>,
    /// The number of the connected waiter of each session.
    pub waiters: HashMap<String, u64>,
    pub next_waiter: u64,
}

struct ManagedTask {
    handle: JoinHandle<()>,
    wake: Arc<Notify>,
    slug: String,
}

impl Memory {
    fn new(store: Store) -> Memory {
        Memory {
            store,
            pokes: HashMap::new(),
            rounds: HashMap::new(),
            fails: HashMap::new(),
            last_poll: BTreeMap::new(),
            next_round: BTreeMap::new(),
            managed: HashMap::new(),
            waiters: HashMap::new(),
            next_waiter: 0,
        }
    }

    pub fn poke(&mut self, key: &str, slug: &str) {
        self.pokes.insert(key.to_string(), slug.to_string());
        for task in self.managed.values().filter(|task| task.slug == slug) {
            task.wake.notify_one();
        }
    }

    pub fn forget(&mut self, key: &str) {
        self.pokes.remove(key);
        self.rounds.remove(key);
        self.fails.remove(key);
    }
}

impl Daemon {
    pub fn new(store: Store, engine: Box<dyn Engine>, workspaces: Box<dyn Workspaces>) -> Daemon {
        Daemon {
            dirs: store.dirs.clone(),
            memory: Mutex::new(Memory::new(store)),
            changed: Notify::new(),
            delivering: RwLock::new(()),
            stopping: AtomicBool::new(false),
            stop: Notify::new(),
            followers: AtomicUsize::new(0),
            retries: std::sync::Mutex::new(JoinSet::new()),
            tick: env_duration("WATCHD_TICK").unwrap_or(Duration::from_secs(5)),
            idle_seconds: env_seconds("WATCHD_IDLE_SECONDS", 600),
            grace_seconds: env_seconds("WATCHD_GRACE_SECONDS", 1800),
            test_interval: env_duration("WATCHD_MANAGED_SECONDS"),
            engine,
            workspaces,
            retry_interval: Duration::from_secs(env_seconds("WATCHD_RETRY_INTERVAL", 30)),
            retry_timeout: Duration::from_secs(3600),
        }
    }

    pub fn stopping(&self) -> bool {
        self.stopping.load(Ordering::SeqCst)
    }

    pub async fn lock(&self) -> MutexGuard<'_, Memory> {
        self.memory.lock().await
    }

    pub fn log(&self, slug: &str, key: &str, message: &str) {
        store::log(&self.dirs, slug, key, message);
    }

    pub fn ensure_managed(self: &Arc<Self>, memory: &mut Memory, repo: &Path) {
        if self.stopping() || memory.managed.get(repo).is_some_and(|task| !task.handle.is_finished()) {
            return;
        }
        let slug = match block_in_place(|| repo_slug(repo)) {
            Ok(slug) => slug,
            Err(text) => {
                self.log("", "", &format!("no managed loop for {}: {text}", repo.display()));
                return;
            }
        };
        let wake = Arc::new(Notify::new());
        let handle = tokio::spawn(managed_loop(
            self.clone(),
            repo.to_path_buf(),
            slug.clone(),
            wake.clone(),
        ));
        memory
            .managed
            .insert(repo.to_path_buf(), ManagedTask { handle, wake, slug });
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

    /// Returns true for a network error. A permanent error, or 5 other errors in a row, ends the agent
    /// record of the key, if any.
    async fn check(self: &Arc<Self>, target: Target, skip: Vec<u64>, cache: Arc<MrCache>) -> bool {
        self.lock().await.pokes.remove(&target.key);
        let args = EngineArgs {
            repo: Some(target.repo.clone()),
            fresh: false,
            review: target.mode == Mode::Review,
            mrs: match target.mode {
                Mode::Hub => Vec::new(),
                Mode::Author | Mode::Review => target.mrs.clone(),
            },
            skip_mrs: match target.mode {
                Mode::Hub => skip,
                Mode::Author | Mode::Review => Vec::new(),
            },
            key: Some(target.key.clone()),
            lookup: None,
        };
        let result = self.engine.check(args, cache).await;
        let mut memory = self.lock().await;
        let (slug, key) = (target.slug.as_str(), target.key.as_str());
        let mut network = false;
        match result {
            Ok(events) => {
                memory.fails.remove(key);
                let routed = match events.is_empty() {
                    true => Vec::new(),
                    false => {
                        let (relocked, routed) = self.route(memory, &target, events).await;
                        memory = relocked;
                        routed
                    }
                };
                memory.store.prune_items(&target);
                if is_worktree_key(key) {
                    memory.store.write_needs(&target);
                }
                if memory.store.end_mrs(&target, &routed) {
                    memory.forget(key);
                }
            }
            Err(EngineError::Network(text)) => {
                self.log(slug, key, &format!("network error: {}", first_line(&text)));
                network = true;
            }
            Err(EngineError::Permanent(text)) => {
                self.log(slug, key, &format!("error: {}", first_line(&text)));
                if let Some(current) = memory.store.sub(key) {
                    memory.store.remove_record(&current, "permanent error", Some(&text));
                }
                memory.forget(key);
            }
            Err(EngineError::Other(text)) => {
                let fails = memory.fails.get(key).copied().unwrap_or(0) + 1;
                memory.fails.insert(key.to_string(), fails);
                self.log(slug, key, &format!("error {fails} of 5: {}", first_line(&text)));
                if fails >= 5 {
                    if let Some(current) = memory.store.sub(key) {
                        memory.store.remove_record(&current, "5 errors in a row", Some(&text));
                    }
                    memory.forget(key);
                }
            }
        }
        if memory.store.sub(key).is_some() {
            let rounds = memory.rounds.get(key).copied().unwrap_or(0) + 1;
            memory.rounds.insert(key.to_string(), rounds);
        }
        drop(memory);
        self.changed.notify_waiters();
        network
    }

    /// The lock is free while the router runs, because an agent start takes seconds.
    async fn route<'a>(
        self: &'a Arc<Self>,
        memory: MutexGuard<'a, Memory>,
        target: &Target,
        events: Vec<Event>,
    ) -> (MutexGuard<'a, Memory>, Vec<RoutedEvent>) {
        let mut routed = memory.store.assign(target, events, now_seconds());
        let recipient = memory.store.recipient(target, &routed);
        drop(memory);
        let (routing, lines) = match recipient {
            Some((key, events)) if key == target.slug => {
                let reviews = home().join(".ai").join(&target.slug).join("reviews");
                let facts = Facts {
                    worktree: match target.mode {
                        Mode::Hub => false,
                        Mode::Author | Mode::Review => true,
                    },
                    ..router::read_facts(&reviews, &events)
                };
                let spawn_retry = |retry: Retry| {
                    let mut retries = self.retries.lock().expect("the retry lock is never poisoned");
                    while retries.try_join_next().is_some() {}
                    retries.spawn(router::retry::retry(self.clone(), target.clone(), retry));
                };
                let ctx = ExecuteContext {
                    repo: &target.repo,
                    key: &target.slug,
                    workspaces: self.workspaces.as_ref(),
                    dirs: &self.dirs,
                    spawn_retry: &spawn_retry,
                };
                execute(router::decide(&events, &facts), &events, &ctx).await
            }
            _ => (Routing::default(), Vec::new()),
        };
        router::narrow(&mut routed, &routing.handled);
        let memory = self.lock().await;
        memory.store.event_log(lines);
        memory.store.deliver(target, &routed, &routing);
        (memory, routed)
    }

    async fn interrupted(&self, slug: &str) -> bool {
        self.stopping() || self.lock().await.pokes.values().any(|poked| poked == slug)
    }

    async fn live_subs(&self, slug: &str) -> Vec<Agent> {
        self.lock().await.store.live_subs(Some(slug))
    }

    /// Only a worktree with a new key gets a git-spice call and the conflict test: an error of these
    /// calls is in the log one time for each key.
    pub async fn local_round(&self) {
        let (known, repos) = {
            let memory = self.lock().await;
            let known: HashMap<PathBuf, WorktreeState> = memory
                .store
                .worktrees()
                .into_iter()
                .map(|state| (state.path.clone(), state))
                .collect();
            (known, memory.store.repos())
        };
        let (changed, seen) = block_in_place(|| self.scan_worktrees(&known, repos));
        let gone: Vec<&PathBuf> = known.keys().filter(|path| !seen.contains(*path)).collect();
        if changed.is_empty() && gone.is_empty() {
            return;
        }
        // The git calls ran with no lock: other writers can have changed the state since then.
        let memory = self.lock().await;
        for state in changed {
            memory
                .store
                .update_worktree(&state.path.clone(), |current| current.set_local(state));
        }
        for path in gone {
            memory.store.remove_worktree(path);
        }
        drop(memory);
        self.changed.notify_waiters();
    }

    /// The git calls of a local round. Returns the new states and the paths of all worktrees.
    fn scan_worktrees(
        &self,
        known: &HashMap<PathBuf, WorktreeState>,
        repos: Vec<PathBuf>,
    ) -> (Vec<WorktreeState>, HashSet<PathBuf>) {
        let mut seen = HashSet::new();
        let mut changed = Vec::new();
        for repo in repos {
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
                        self.log("", "", &format!("{}: {}", worktree.path.display(), first_line(&text)));
                        Vec::new()
                    }),
                };
                let ended_branches = known
                    .get(&worktree.path)
                    .map_or_else(Vec::new, |state| state.ended_branches.clone());
                let mut state = WorktreeState::new(worktree.path, repo.clone(), worktree.branch, key, &branches);
                state.ended_branches = ended_branches;
                if let Some(default) = &refs.default_branch {
                    for test in conflict_tests(state.branch.as_deref(), &branches, &state.ended_branches) {
                        match conflict(&state.path, default, test.base.as_deref(), &test.tip) {
                            Ok(files) => state.conflict.extend(files),
                            Err(text) => self.log("", "", &format!("{}: {}", state.path.display(), first_line(&text))),
                        }
                    }
                    state.conflict.sort();
                    state.conflict.dedup();
                }
                changed.push(state);
            }
        }
        (changed, seen)
    }

    async fn is_managed(&self, repo: &Path) -> bool {
        self.lock().await.store.repos().iter().any(|known| known == repo)
    }

    fn managed_interval(&self, agents: &[Agent]) -> Duration {
        if let Some(interval) = self.test_interval {
            return interval;
        }
        let hub = agents.iter().any(|agent| agent.mode == Mode::Hub);
        Duration::from_secs(if hub { 120 } else { 900 })
    }

    /// Returns false if the loop must stop.
    pub async fn wait_network(&self, repo: &Path, host: Option<&str>) -> bool {
        while !online(host).await {
            self.sleep_or_stop(10).await;
            if self.stopping() || !self.is_managed(repo).await {
                return false;
            }
        }
        true
    }

    /// One open item while the fast-forward is blocked: an unchanged reason sends no new event.
    async fn pull(self: &Arc<Self>, slug: &str, repo: &Path, default: &str) {
        let (main, branch) = (repo.to_path_buf(), default.to_string());
        let result = match tokio::task::spawn_blocking(move || fast_forward(&main, &branch)).await {
            Ok(result) => result,
            Err(error) => {
                self.log(slug, "", &format!("fast-forward of {default}: {error}"));
                return;
            }
        };
        let item = format!("pull:{default}");
        let memory = self.lock().await;
        match result {
            Ok(moved) => {
                if moved {
                    self.log(slug, "", &format!("fast-forward: {default}"));
                }
                memory.store.close_item(slug, &item);
            }
            Err(blocked) => {
                let text = blocked.text(default);
                let open = memory.store.open_item(slug, &item).and_then(|open| open.event);
                if open.is_some_and(|event| event.detail == text) {
                    return;
                }
                self.log(slug, "", &format!("pull blocked: {text}"));
                let event = Event {
                    item: Some(item),
                    ..Event::new(EventKind::PullBlocked, None, None, "", "", &text, default)
                };
                let hub = Target {
                    key: slug.to_string(),
                    slug: slug.to_string(),
                    mode: Mode::Hub,
                    repo: repo.to_path_buf(),
                    mrs: Vec::new(),
                };
                let (memory, _) = self.route(memory, &hub, vec![event]).await;
                drop(memory);
                self.changed.notify_waiters();
                return;
            }
        }
        drop(memory);
        self.changed.notify_waiters();
    }

    /// The targets of one round, and the review MRs that the hub check skips.
    async fn round_targets(&self, repo: &Path, slug: &str) -> (Vec<Target>, Vec<u64>) {
        let memory = self.lock().await;
        let worktrees: Vec<WorktreeState> = memory
            .store
            .worktrees()
            .into_iter()
            .filter(|state| state.repo == repo)
            .collect();
        let own: Vec<OwnMr> = memory
            .store
            .engine_value(slug)
            .and_then(|engine| serde_json::from_value(engine["own_mrs"].clone()).ok())
            .unwrap_or_default();
        let agents = memory.store.live_subs(Some(slug));
        let all_reviews = memory.store.reviews();
        let (kept, gone): (Vec<ReviewLink>, Vec<ReviewLink>) =
            all_reviews.into_iter().partition(|link| link.worktree.is_dir());
        if !gone.is_empty() {
            memory.store.write_reviews(kept.clone());
        }
        let reviews: Vec<ReviewLink> = kept
            .into_iter()
            .filter(|link| worktrees.iter().any(|state| state.path == link.worktree))
            .collect();
        let key_of = |path: &Path| author_key(slug, path);
        let targets = targets(repo, slug, &worktrees, &own, &reviews, &agents, &key_of);
        let mut skip = Vec::new();
        for target in targets.iter().filter(|target| target.mode == Mode::Review) {
            skip.extend(&target.mrs);
            if memory.store.live_agent(&target.key) {
                memory.store.move_items(slug, &target.key, target.mrs.first().copied());
            }
        }
        memory.store.prune_needs(repo, &targets);
        (targets, skip)
    }

    async fn lookups(&self, repo: &Path, slug: &str, default: Option<&str>) {
        let (states, reviews) = {
            let memory = self.lock().await;
            let states: Vec<WorktreeState> = memory
                .store
                .worktrees()
                .into_iter()
                .filter(|state| state.repo == repo)
                .collect();
            (states, memory.store.reviews())
        };
        for state in &states {
            let Some(branch) = lookup_branch(state, default, &reviews) else {
                continue;
            };
            let result = self.engine.lookup(state.path.clone(), branch.to_string()).await;
            let memory = self.lock().await;
            let iid = match result {
                Ok(iid) => iid,
                Err(error) => {
                    self.log(
                        slug,
                        "",
                        &format!("lookup of {branch}: {}", first_line(error.message())),
                    );
                    continue;
                }
            };
            if let Some(mut current) = memory.store.worktree(&state.path) {
                current.lookup_branch = Some(branch.to_string());
                memory.store.write_worktree(&current);
            }
            if let Some(iid) = iid {
                memory.store.add_review(ReviewLink {
                    worktree: state.path.clone(),
                    iid,
                });
            }
        }
    }

    async fn gitlab_round(self: &Arc<Self>, repo: &Path, slug: &str) -> bool {
        let (targets, skip) = self.round_targets(repo, slug).await;
        let round = std::env::temp_dir().join(format!("watchd-round-{}-{slug}-{}", std::process::id(), now_seconds()));
        let _ = std::fs::create_dir_all(&round);
        let cache = Arc::new(MrCache::new(round.clone()));
        let mut checks = tokio::task::JoinSet::new();
        for target in targets.iter().cloned() {
            let (daemon, skip, cache) = (self.clone(), skip.clone(), cache.clone());
            checks.spawn(async move { daemon.check(target, skip, cache).await });
        }
        let mut network = false;
        while let Some(result) = checks.join_next().await {
            match result {
                Ok(failed) => network |= failed,
                Err(error) => self.log(slug, "", &format!("check task: {error}")),
            }
        }
        let _ = std::fs::remove_dir_all(&round);
        let mut memory = self.lock().await;
        // No check takes the poke of a key with no target: the round is its answer.
        memory
            .pokes
            .retain(|key, poked| poked != slug || targets.iter().any(|target| target.key == *key));
        memory.last_poll.insert(slug.to_string(), now_seconds());
        self.log(slug, "", &format!("round done: {} target(s)", targets.len()));
        network
    }
}

async fn managed_loop(daemon: Arc<Daemon>, repo: PathBuf, slug: String, wake: Arc<Notify>) {
    daemon.log(&slug, "", &format!("managed loop start: {}", repo.display()));
    let host = block_in_place(|| remote_url(&repo))
        .as_deref()
        .and_then(split_remote)
        .map(|(host, _)| host.to_string());
    let mut no_default_logged = false;
    loop {
        if daemon.stopping() || !daemon.is_managed(&repo).await {
            break;
        }
        let default = block_in_place(|| shared_refs(&repo)).default_branch;
        match default.clone() {
            None if no_default_logged => {}
            None => {
                daemon.log(&slug, "", "no default branch: origin/HEAD is not set");
                no_default_logged = true;
            }
            Some(default) => {
                no_default_logged = false;
                match fetch(&repo, &default, FETCH_TIMEOUT).await {
                    Ok(()) => daemon.pull(&slug, &repo, &default).await,
                    Err(FetchError::Network(text)) if !online(host.as_deref()).await => {
                        daemon.log(&slug, "", &format!("network down: {}", first_line(&text)));
                        match daemon.wait_network(&repo, host.as_deref()).await {
                            true => continue,
                            false => break,
                        }
                    }
                    Err(FetchError::Network(text) | FetchError::Other(text)) => {
                        daemon.log(&slug, "", first_line(&text));
                    }
                }
            }
        }
        daemon.lookups(&repo, &slug, default.as_deref()).await;
        let network = daemon.gitlab_round(&repo, &slug).await;
        if daemon.stopping() {
            break;
        }
        // A network error with the network up, as for HTTP 502, gets the normal wait.
        if network && !online(host.as_deref()).await {
            match daemon.wait_network(&repo, host.as_deref()).await {
                true => continue,
                false => break,
            }
        }
        let agents = daemon.live_subs(&slug).await;
        let interval = agents
            .iter()
            .map(|agent| Duration::from_secs(agent.interval))
            .fold(daemon.managed_interval(&agents), Duration::min);
        daemon
            .lock()
            .await
            .next_round
            .insert(slug.clone(), now_seconds() + interval.as_secs() as i64);
        let sleep = |step: Duration| {
            let (daemon, wake, slug) = (daemon.clone(), wake.clone(), slug.clone());
            async move {
                let woken = wake.notified();
                let stop = daemon.stop.notified();
                tokio::pin!(woken, stop);
                stop.as_mut().enable();
                if daemon.interrupted(&slug).await {
                    return true;
                }
                tokio::select! {
                    _ = tokio::time::sleep(step) => false,
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
    let mut memory = daemon.lock().await;
    memory.last_poll.remove(&slug);
    memory.next_round.remove(&slug);
    daemon.log(&slug, "", &format!("managed loop stop: {}", repo.display()));
}

fn inode(path: &std::path::Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|meta| meta.ino())
}

/// Returns `None` if the descriptor is not open.
fn inherited_fd(name: &str) -> Option<RawFd> {
    let fd = std::env::var(name).ok()?.parse().ok()?;
    // SAFETY: no other thread reads or writes the environment: the runtime runs no task but this
    // one yet.
    unsafe { std::env::remove_var(name) };
    // SAFETY: fcntl reads no memory, and it fails on a descriptor that is not open.
    match unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } {
        -1 => None,
        _ => Some(fd),
    }
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

fn keep_open(fd: RawFd) -> std::io::Result<()> {
    // SAFETY: fcntl reads no memory, and it fails on a descriptor that is not open.
    match unsafe { libc::fcntl(fd, libc::F_SETFD, 0) } {
        -1 => Err(std::io::Error::last_os_error()),
        _ => Ok(()),
    }
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
    let daemon = Arc::new(Daemon::new(store, engine_of(&dirs), workspaces_of()));
    let socket_fd = listener.as_raw_fd();
    let _ = listener.set_nonblocking(true);
    let listener = tokio::net::UnixListener::from_std(listener).expect("a listener in the runtime");
    tokio::spawn(crate::server::serve(daemon.clone(), listener));
    let end = run(&daemon).await;
    daemon.begin_stop();
    let tasks: Vec<JoinHandle<()>> = daemon
        .lock()
        .await
        .managed
        .drain()
        .map(|(_, task)| task.handle)
        .collect();
    for task in tasks {
        let _ = task.await;
    }
    let mut retries = std::mem::take(&mut *daemon.retries.lock().expect("the retry lock is never poisoned"));
    while retries.join_next().await.is_some() {}
    let _deliveries = daemon.delivering.write().await;
    match end {
        End::Restart => {
            let _memory = daemon.lock().await;
            let exe = std::env::current_exe().unwrap_or_default();
            if let Err(error) = keep_open(lock.as_raw_fd()).and_then(|()| keep_open(socket_fd)) {
                daemon.log("", "", &format!("restart failed: {error}"));
                return 1;
            }
            let error = std::os::unix::process::CommandExt::exec(
                std::process::Command::new(&exe)
                    .arg("daemon")
                    .env(LOCK_FD, lock.as_raw_fd().to_string())
                    .env(SOCKET_FD, socket_fd.to_string()),
            );
            daemon.log("", "", &format!("restart failed: {}: {error}", exe.display()));
            1
        }
        End::Stop => {
            let _memory = daemon.lock().await;
            let pid_file = std::fs::read_to_string(dirs.pid()).unwrap_or_default();
            if pid_file.trim() == pid.to_string() {
                let _ = std::fs::remove_file(dirs.pid());
            }
            daemon.log("", "", &format!("daemon stop {pid}"));
            0
        }
    }
}

async fn run(daemon: &Arc<Daemon>) -> End {
    use tokio::signal::unix::{SignalKind, signal};
    let (Ok(mut terminate), Ok(mut interrupt)) = (signal(SignalKind::terminate()), signal(SignalKind::interrupt()))
    else {
        daemon.log("", "", "no signal handlers");
        return End::Stop;
    };
    let exe = std::env::current_exe().unwrap_or_default();
    let start = inode(&exe);
    let mut seen = start;
    let mut idle_since = now_seconds();
    let mut pruned_at = 0;
    {
        let memory = daemon.lock().await;
        memory.store.end_old_records();
        for sub in memory.store.subs() {
            if let Some(repo) = block_in_place(|| repo_of(&sub.repo)) {
                memory.store.add_repo(&repo);
            }
        }
    }
    loop {
        // An install renames a new file over the binary: a new inode that stays for one tick is a
        // complete update.
        let current = inode(&exe);
        if current.is_some() && current != start && current == seen {
            daemon.log("", "", "restart: waiting for the repo loops");
            return End::Restart;
        }
        seen = current;
        let now = now_seconds();
        let mut memory = daemon.lock().await;
        if now - pruned_at >= 3600 {
            memory.store.prune(now);
            pruned_at = now;
        }
        let mut ended = memory.store.end_sessions(now, daemon.grace_seconds as i64);
        ended.extend(memory.store.end_gone_worktrees());
        for key in &ended {
            memory.forget(key);
        }
        memory.store.sweep();
        for repo in memory.store.drop_gone_repos() {
            daemon.log("", "", &format!("repo gone: {}", repo.display()));
        }
        if !memory.store.live_subs(None).is_empty() || daemon.followers.load(Ordering::SeqCst) > 0 {
            idle_since = now;
        } else if now - idle_since >= daemon.idle_seconds as i64 {
            daemon.log("", "", "idle stop");
            return End::Stop;
        }
        for repo in memory.store.repos() {
            daemon.ensure_managed(&mut memory, &repo);
        }
        drop(memory);
        daemon.local_round().await;
        // The tests count rounds to know that an action had its effect.
        #[cfg(feature = "test-support")]
        daemon.log("", "", "local round end");
        daemon.changed.notify_waiters();
        tokio::select! {
            _ = tokio::time::sleep(daemon.tick) => {}
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
        keep_open(file.as_raw_fd()).unwrap();
        // SAFETY: no other test reads this variable.
        unsafe { std::env::set_var("WATCHD_TEST_INHERITED_FD", file.as_raw_fd().to_string()) };

        let fd = inherited_fd("WATCHD_TEST_INHERITED_FD").unwrap();

        // SAFETY: fcntl on an open descriptor.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        assert_eq!(flags & libc::FD_CLOEXEC, libc::FD_CLOEXEC);
    }
}
