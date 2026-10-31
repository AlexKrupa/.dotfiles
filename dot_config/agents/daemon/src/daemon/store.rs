//! The daemon state files, with the daemon as the only writer: each function runs under its state
//! lock.

use std::collections::{BTreeMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::board::Board;
use crate::core::eventlog::{LogLine, event_line, id_of, next_id, prune_lines, stopped_line};
use crate::core::items::{Item, Items, Owner, RoutedEvent, assign_rows, move_items, prune_items, prune_moved};
use crate::core::subs::{Agent, Mode, Session, SessionKey, add_ended};
use crate::core::worktrees::{Kind, Repos, ReviewLink, Reviews, Stage, Target, WorktreeState};
use crate::engine::event::{Event, EventKind};
use crate::engine::router::Routing;
use crate::engine::state::Need;
use crate::key::is_worktree_key;
use crate::local::repo_of;
use crate::paths::StateDirs;
use crate::persist::{Load, LoadError, load, save, write_atomic, write_json};
use crate::platform::{local_time, now_seconds, process_alive, utc_timestamp};
use crate::protocol::{DebugState, SubStatus, WatchRequest};
use crate::report::{ReportInput, build_report, render};

pub const ALL_ENDED: &str = "all MRs merged or closed";

fn unreadable() -> String {
    "report: jq could not read the input or the state".to_string()
}

pub struct Store {
    pub dirs: StateDirs,
    last_id: std::sync::Mutex<Option<u64>>,
}

fn remove(path: &Path) {
    let _ = std::fs::remove_file(path);
}

pub fn first_line(text: &str) -> &str {
    text.lines().next().unwrap_or_default()
}

fn lines_of<T: Serialize>(values: &[T]) -> String {
    values
        .iter()
        .map(|value| serde_json::to_string(value).expect("a line serializes") + "\n")
        .collect()
}

/// The log needs no state lock: each line is one append.
pub fn log(dirs: &StateDirs, slug: &str, key: &str, message: &str) {
    let dash = |text: &str| {
        if text.is_empty() {
            "-".to_string()
        } else {
            text.to_string()
        }
    };
    let line = format!(
        "{} {} {} {message}\n",
        utc_timestamp(now_seconds()),
        dash(slug),
        dash(key)
    );
    let file = std::fs::OpenOptions::new().create(true).append(true).open(dirs.log());
    if let Ok(mut file) = file {
        let _ = file.write_all(line.as_bytes());
    }
}

fn kind_of(mode: Mode) -> Kind {
    match mode {
        Mode::Hub => Kind::Hub,
        Mode::Author => Kind::Mine,
        Mode::Review => Kind::Review,
    }
}

impl Store {
    pub fn new(dirs: StateDirs) -> Store {
        Store {
            dirs,
            last_id: std::sync::Mutex::new(None),
        }
    }

    /// A broken file goes away with a log line, as a file of an unknown format does.
    fn read_json<T: DeserializeOwned>(&self, path: &Path) -> Result<Option<T>, LoadError> {
        let reason = match load(path) {
            Ok(None) => return Ok(None),
            Ok(Some(Load::Current(data) | Load::Converted(data))) => return Ok(Some(data)),
            Ok(Some(Load::Dropped(reason))) => reason,
            Err(LoadError::Parse(error)) => error.to_string(),
            Err(error @ LoadError::Read(_)) => return Err(error),
        };
        remove(path);
        self.log("", "", &format!("{}: {reason}, record removed", path.display()));
        Ok(None)
    }

    /// A read error gets a log line, and the caller goes on as with no file.
    fn read<T: DeserializeOwned>(&self, path: &Path) -> Option<T> {
        self.read_json(path).unwrap_or_else(|error| {
            self.log("", "", &format!("{}: {error}", path.display()));
            None
        })
    }

    /// Returns false if the write failed.
    fn save_items(&self, path: &Path, items: &Items) -> bool {
        match save(path, items) {
            Ok(()) => true,
            Err(error) => {
                self.log("", "", &format!("{}: items not written: {error}", path.display()));
                false
            }
        }
    }

    fn write_text(&self, path: &Path, text: &str) {
        if let Err(error) = write_atomic(path, text) {
            self.log("", "", &format!("{}: not written: {error}", path.display()));
        }
    }

    pub fn ensure_dirs(&self) -> std::io::Result<()> {
        for dir in ["subs", "sessions", "inbox", "items", "worktrees"] {
            std::fs::create_dir_all(self.dirs.watchd.join(dir))?;
        }
        Ok(())
    }

    pub fn log(&self, slug: &str, key: &str, message: &str) {
        log(&self.dirs, slug, key, message);
    }

    /// Shrinks the log in place, because the log file is the stdout of the daemon.
    pub fn trim_log(&self) {
        let Ok(text) = std::fs::read_to_string(self.dirs.log()) else {
            return;
        };
        let lines: Vec<&str> = text.lines().collect();
        if lines.len() <= 10_000 {
            return;
        }
        let kept: String = lines[lines.len() - 5000..]
            .iter()
            .map(|line| format!("{line}\n"))
            .collect();
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(self.dirs.log())
        {
            let _ = file.write_all(kept.as_bytes());
        }
    }

    pub fn sub(&self, key: &str) -> Option<Agent> {
        self.read(&self.dirs.sub(key))
    }

    pub fn subs(&self) -> Vec<Agent> {
        let Ok(entries) = std::fs::read_dir(self.dirs.watchd.join("subs")) else {
            return Vec::new();
        };
        let mut keys: Vec<String> = entries
            .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
            .filter_map(|name| name.strip_suffix(".json").map(str::to_string))
            .collect();
        keys.sort();
        keys.iter().filter_map(|key| self.sub(key)).collect()
    }

    /// A record stays while its session is away: the events of the key wait in its inbox.
    pub fn live_subs(&self, slug: Option<&str>) -> Vec<Agent> {
        self.subs()
            .into_iter()
            .filter(|sub| slug.is_none_or(|slug| sub.slug == slug))
            .collect()
    }

    pub fn session_subs(&self, id: &str) -> Vec<Agent> {
        self.subs().into_iter().filter(|sub| sub.session == id).collect()
    }

    pub fn session(&self, id: &str) -> Option<Session> {
        self.read(&self.dirs.session(id))
    }

    pub fn sessions(&self) -> Vec<(String, Session)> {
        self.json_files(&self.dirs.watchd.join("sessions"), ".json")
            .into_iter()
            .collect()
    }

    pub fn write_session(&self, id: &str, session: &Session) {
        if let Err(error) = save(&self.dirs.session(id), session) {
            self.log("", "", &format!("session {id} not written: {error}"));
        }
    }

    pub fn remove_session(&self, id: &str) {
        remove(&self.dirs.session(id));
    }

    /// A session is away from the end of its owner to the next wait.
    pub fn live_session(&self, id: &str) -> bool {
        self.session(id).is_some_and(|session| session.owner_gone_at.is_none())
    }

    /// Returns the keys of the ended records.
    pub fn end_sessions(&self, now: i64, grace_seconds: i64) -> Vec<String> {
        let mut keys = Vec::new();
        for (id, mut session) in self.sessions() {
            let gone_at = match session.owner_gone_at {
                Some(gone_at) => gone_at,
                None if session.owner_pid.is_some_and(process_alive) => continue,
                None => {
                    session.owner_gone_at = Some(now);
                    self.write_session(&id, &session);
                    now
                }
            };
            if now - gone_at < grace_seconds {
                continue;
            }
            for sub in self.session_subs(&id) {
                self.remove_record(&sub, &format!("session {id} is gone"), None);
                keys.push(sub.key);
            }
            self.remove_session(&id);
        }
        keys
    }

    /// A new conversation in the same owner process has a new session ID. The watches of the live
    /// session of the owner move to the new ID. An away session keeps its watches: a different
    /// process can have its PID now. Returns the old ID.
    pub fn rename_session(&self, id: &str, owner_pid: u32) -> Option<String> {
        if self.session(id).is_some() {
            return None;
        }
        let (old, state) = self
            .sessions()
            .into_iter()
            .find(|(_, state)| state.owner_pid == Some(owner_pid) && state.owner_gone_at.is_none())?;
        for sub in self.session_subs(&old) {
            self.write_sub(&Agent {
                session: id.to_string(),
                ..sub
            });
        }
        self.write_session(id, &state);
        self.remove_session(&old);
        Some(old)
    }

    /// One owner process shows one conversation at a time: its other live sessions are away.
    /// Returns their IDs.
    pub fn leave_other_sessions(&self, id: &str, owner_pid: u32, now: i64) -> Vec<String> {
        let mut left = Vec::new();
        for (other, mut state) in self.sessions() {
            if other != id && state.owner_pid == Some(owner_pid) && state.owner_gone_at.is_none() {
                state.owner_gone_at = Some(now);
                self.write_session(&other, &state);
                left.push(other);
            }
        }
        left
    }

    /// Returns the keys of the ended records.
    pub fn end_gone_worktrees(&self) -> Vec<String> {
        let mut keys = Vec::new();
        for sub in self.subs().into_iter().filter(|sub| !sub.repo.is_dir()) {
            let error = format!("watchd: the worktree is gone: {}\n", sub.repo.display());
            self.remove_record(&sub, "worktree gone", Some(&error));
            keys.push(sub.key);
        }
        keys
    }

    pub fn write_sub(&self, sub: &Agent) {
        if let Err(error) = save(&self.dirs.sub(&sub.key), sub) {
            self.log(&sub.slug, &sub.key, &format!("record not written: {error}"));
        }
    }

    pub fn repos(&self) -> Vec<PathBuf> {
        let repos: Option<Repos> = self.read(&self.dirs.repos());
        repos.unwrap_or_default().repos
    }

    fn write_repos(&self, repos: Vec<PathBuf>) {
        if let Err(error) = save(&self.dirs.repos(), &Repos { repos }) {
            self.log("", "", &format!("repos not written: {error}"));
        }
    }

    pub fn add_repo(&self, repo: &Path) {
        let mut repos = self.repos();
        if repos.iter().any(|known| known == repo) {
            return;
        }
        repos.push(repo.to_path_buf());
        repos.sort();
        self.write_repos(repos);
        self.log("", "", &format!("repo added: {}", repo.display()));
    }

    pub fn drop_gone_repos(&self) -> Vec<PathBuf> {
        let (kept, gone): (Vec<PathBuf>, Vec<PathBuf>) = self.repos().into_iter().partition(|repo| repo.is_dir());
        if !gone.is_empty() {
            self.write_repos(kept);
        }
        gone
    }

    pub fn reviews(&self) -> Vec<ReviewLink> {
        let reviews: Option<Reviews> = self.read(&self.dirs.reviews());
        reviews.unwrap_or_default().reviews
    }

    pub fn write_reviews(&self, reviews: Vec<ReviewLink>) {
        if let Err(error) = save(&self.dirs.reviews(), &Reviews { reviews }) {
            self.log("", "", &format!("reviews not written: {error}"));
        }
    }

    pub fn add_review(&self, link: ReviewLink) {
        let mut reviews = self.reviews();
        if !reviews.contains(&link) {
            self.log(
                "",
                "",
                &format!("review link: {} !{}", link.worktree.display(), link.iid),
            );
            reviews.push(link);
            self.write_reviews(reviews);
        }
    }

    pub fn worktrees(&self) -> Vec<WorktreeState> {
        let states: BTreeMap<String, WorktreeState> = self.json_files(&self.dirs.watchd.join("worktrees"), ".json");
        states.into_values().collect()
    }

    pub fn worktree(&self, path: &Path) -> Option<WorktreeState> {
        self.read(&self.dirs.worktree(path))
    }

    pub fn write_worktree(&self, state: &WorktreeState) {
        if let Err(error) = save(&self.dirs.worktree(&state.path), state) {
            self.log("", "", &format!("{}: state not written: {error}", state.path.display()));
        }
    }

    pub fn remove_worktree(&self, path: &Path) {
        remove(&self.dirs.worktree(path));
    }

    pub fn inbox_lines(&self, key: &str) -> usize {
        std::fs::read_to_string(self.dirs.inbox(key)).map_or(0, |text| text.lines().count())
    }

    fn inbox_has_events(&self, key: &str) -> bool {
        std::fs::metadata(self.dirs.inbox(key)).is_ok_and(|meta| meta.len() > 0)
    }

    pub fn take_inbox_of(&self, key: &str, mrs: &[u64]) -> Vec<RoutedEvent> {
        let events = self.take_inbox(key);
        if mrs.is_empty() {
            return events;
        }
        let (taken, kept): (Vec<RoutedEvent>, Vec<RoutedEvent>) = events
            .into_iter()
            .partition(|event| event.event.iid.is_some_and(|iid| mrs.contains(&iid)));
        self.put_back_inbox(key, &kept);
        taken
    }

    pub fn open_events(&self, key: &str) -> Vec<RoutedEvent> {
        let items: Items = self.read(&self.dirs.items(key)).unwrap_or_default();
        items
            .items
            .into_iter()
            .filter(|item| item.owner == Owner::Daemon)
            .filter_map(|item| {
                Some(RoutedEvent {
                    event: item.event?,
                    row: item.n,
                })
            })
            .collect()
    }

    pub fn take_inbox(&self, key: &str) -> Vec<RoutedEvent> {
        let path = self.dirs.inbox(key);
        let text = std::fs::read_to_string(&path).unwrap_or_default();
        remove(&path);
        let mut events = Vec::new();
        for line in text.lines().filter(|line| !line.trim().is_empty()) {
            match serde_json::from_str(line) {
                Ok(event) => events.push(event),
                Err(error) => self.log("", key, &format!("inbox line dropped: {error}: {line}")),
            }
        }
        events
    }

    pub fn put_back_inbox(&self, key: &str, events: &[RoutedEvent]) {
        let path = self.dirs.inbox(key);
        let newer = std::fs::read_to_string(&path).unwrap_or_default();
        self.write_text(&path, &(lines_of(events) + &newer));
    }

    fn append_lines<T: Serialize>(&self, path: &Path, values: &[T]) {
        let text = lines_of(values);
        let file = std::fs::OpenOptions::new().create(true).append(true).open(path);
        if let Ok(mut file) = file {
            let _ = file.write_all(text.as_bytes());
        }
    }

    /// The delivery that the next `report` shows.
    pub fn write_last(&self, key: &str, events: &[RoutedEvent]) {
        self.write_text(&self.dirs.last(key), &lines_of(events));
    }

    pub fn last_id(&self) -> u64 {
        let mut last_id = self.last_id.lock().expect("the id lock is never poisoned");
        *last_id.get_or_insert_with(|| {
            let text = std::fs::read_to_string(self.dirs.events()).unwrap_or_default();
            text.lines().map(id_of).max().unwrap_or(0)
        })
    }

    pub fn event_log(&self, lines: Vec<LogLine>) {
        let mut last = self.last_id();
        let mut last_id = self.last_id.lock().expect("the id lock is never poisoned");
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |duration| duration.as_millis() as u64);
        let mut texts = Vec::new();
        for mut line in lines {
            last = next_id(last, millis);
            line.set_id(last);
            texts.push(serde_json::to_string(&line).expect("a log line serializes"));
        }
        *last_id = Some(last);
        let text: String = texts.iter().map(|line| format!("{line}\n")).collect();
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dirs.events());
        if let Ok(mut file) = file {
            let _ = file.write_all(text.as_bytes());
        }
    }

    /// A worktree with no state gets a state with no git key: the next local round fills it.
    pub fn update_worktree(&self, path: &Path, change: impl FnOnce(&mut WorktreeState)) {
        let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        let mut state = self.worktree(&path).unwrap_or_else(|| {
            let repo = tokio::task::block_in_place(|| repo_of(&path)).unwrap_or_else(|| path.clone());
            WorktreeState::new(path.clone(), repo, None, String::new(), &[])
        });
        change(&mut state);
        self.write_worktree(&state);
    }

    pub fn engine_value(&self, key: &str) -> Option<serde_json::Value> {
        self.read(&self.dirs.engine_state(key))
    }

    /// Writes the error before it removes the record: the next wait of the session must see the
    /// error first.
    pub fn remove_record(&self, sub: &Agent, reason: &str, error: Option<&str>) {
        if let Some(text) = error {
            // The text names the watch: a session can have more than one, with the same error.
            let detail = text.strip_prefix("watchd: ").unwrap_or(text);
            let named = format!("watchd: {} watch {}: {detail}", sub.mode.as_str(), sub.key);
            self.write_text(&self.dirs.error(&sub.key), &named);
            let title = match sub.mode {
                Mode::Hub => None,
                Mode::Author | Mode::Review => sub.mrs.first().and_then(|iid| {
                    let engine = self.engine_value(&sub.key)?;
                    engine["mrs"][iid.to_string()]["title"].as_str().map(str::to_string)
                }),
            };
            let line = stopped_line(&sub.slug, &sub.key, sub.mode, now_seconds(), title, first_line(text));
            self.event_log(vec![LogLine::Stopped(line)]);
        }
        if let Some(mut session) = self.session(&sub.session) {
            let ended = SessionKey {
                key: sub.key.clone(),
                mode: sub.mode,
            };
            if !session.ended.contains(&ended) {
                session.ended.push(ended);
                self.write_session(&sub.session, &session);
            }
        }
        match sub.mode {
            Mode::Author | Mode::Review => self.move_items(&sub.key, &sub.slug, None),
            Mode::Hub => {}
        }
        remove(&self.dirs.sub(&sub.key));
        self.log(&sub.slug, &sub.key, &format!("subscription removed: {reason}"));
        let stage = if reason == ALL_ENDED {
            Stage::Done
        } else {
            Stage::Stopped
        };
        self.update_worktree(&sub.repo, |state| state.stage = Some(stage));
    }

    pub fn write_needs(&self, target: &Target) {
        let needs: Vec<Need> = self
            .engine_value(&target.key)
            .and_then(|engine| serde_json::from_value(engine["needs"].clone()).ok())
            .unwrap_or_default();
        self.update_worktree(&target.repo, |state| match needs.is_empty() {
            true => {
                state.needs.remove(&target.key);
            }
            false => {
                state.needs.insert(target.key.clone(), needs);
            }
        });
    }

    /// No check clears the needs of a key that is no longer a target.
    pub fn prune_needs(&self, repo: &Path, targets: &[Target]) {
        for mut state in self.worktrees().into_iter().filter(|state| state.repo == repo) {
            let count = state.needs.len();
            state
                .needs
                .retain(|key, _| targets.iter().any(|target| target.key == *key));
            if state.needs.len() < count {
                self.write_worktree(&state);
            }
        }
    }

    /// The records of an older format have no session. Returns the count of ended records.
    pub fn end_old_records(&self) -> usize {
        let mut count = 0;
        for entry in std::fs::read_dir(self.dirs.watchd.join("subs"))
            .into_iter()
            .flatten()
            .flatten()
        {
            if let Ok(Some(Load::Converted(sub))) = load::<Agent>(&entry.path()) {
                self.remove_record(&sub, "old format", None);
                count += 1;
            }
        }
        for entry in std::fs::read_dir(self.dirs.watchd.join("inbox"))
            .into_iter()
            .flatten()
            .flatten()
        {
            if entry.file_name().to_string_lossy().ends_with(".owner") {
                remove(&entry.path());
            }
        }
        count
    }

    /// The hub keeps its items: the present rules close them, and a new hub session gets them.
    /// An ended key keeps its results until the next wait of its session.
    pub fn sweep(&self) {
        let mut keys = Vec::new();
        for (dir, suffixes) in [("inbox", &[".jsonl", ".error"][..]), ("items", &[".json"][..])] {
            let Ok(entries) = std::fs::read_dir(self.dirs.watchd.join(dir)) else {
                continue;
            };
            for name in entries.filter_map(|entry| entry.ok()?.file_name().into_string().ok()) {
                if name.ends_with(".last.jsonl") {
                    continue;
                }
                let Some(key) = suffixes.iter().find_map(|suffix| name.strip_suffix(suffix)) else {
                    continue;
                };
                if dir == "items" && !is_worktree_key(key) {
                    continue;
                }
                keys.push(key.to_string());
            }
        }
        keys.sort();
        keys.dedup();
        let ended: HashSet<String> = self
            .sessions()
            .into_iter()
            .flat_map(|(_, session)| session.ended)
            .map(|ended| ended.key)
            .collect();
        for key in keys {
            if self.dirs.sub(&key).exists() || ended.contains(&key) {
                continue;
            }
            for path in [self.dirs.inbox(&key), self.dirs.error(&key), self.dirs.last(&key)] {
                remove(&path);
            }
            if is_worktree_key(&key) {
                remove(&self.dirs.items(&key));
            }
            self.log("", &key, "results of an ended subscription removed");
        }
    }

    pub fn assign(&self, target: &Target, events: Vec<Event>, now: i64) -> Vec<RoutedEvent> {
        let owner = match (self.live_agent(&target.key), target.mode) {
            (false, Mode::Author | Mode::Review) => {
                // The items that an ended agent left in the file of the key.
                self.move_items(&target.key, &target.slug, None);
                &target.slug
            }
            _ => &target.key,
        };
        let path = self.dirs.items(owner);
        let routed = match self.read_json::<Items>(&path) {
            Ok(items) => {
                let mut items = items.unwrap_or_default();
                let routed = assign_rows(&mut items, events, now);
                self.save_items(&path, &items);
                routed
            }
            // The engine saved its state already: events that do not go out now are lost.
            Err(_) => {
                self.log(&target.slug, &target.key, "no rows: the items file is not readable");
                assign_rows(&mut Items::default(), events, now)
            }
        };
        let lines = routed
            .iter()
            .map(|event| {
                LogLine::Event(Box::new(event_line(
                    &target.slug,
                    &target.key,
                    target.mode,
                    now,
                    event.clone(),
                )))
            })
            .collect();
        self.event_log(lines);
        routed
    }

    /// A live agent of the key gets all events, else a live hub gets the worktree events with an item.
    pub fn recipient(&self, target: &Target, routed: &[RoutedEvent]) -> Option<(String, Vec<RoutedEvent>)> {
        match (self.live_agent(&target.key), target.mode) {
            (true, _) => Some((target.key.clone(), routed.to_vec())),
            (false, Mode::Author | Mode::Review) if self.live_hub(&target.slug) => {
                let items = routed
                    .iter()
                    .filter(|event| event.event.item.is_some())
                    .cloned()
                    .collect();
                Some((target.slug.clone(), items))
            }
            (false, _) => None,
        }
    }

    /// With only handled rows, the board gets the report and the hub inbox gets nothing. Else the
    /// inbox gets all events, and the `.routing` file keeps the fields of the handled rows.
    pub fn deliver(&self, target: &Target, routed: &[RoutedEvent], routing: &Routing) {
        if let Some((key, events)) = self.recipient(target, routed)
            && !events.is_empty()
        {
            let all_handled = events.iter().all(|event| routing.handled.contains(&event.row));
            // A router of the hub does not apply to the inbox of another agent.
            match (key == target.slug, all_handled) {
                (true, true) => {
                    if let Err(error) = self.build(&key, Mode::Hub, &[], &routing.input, &events) {
                        self.log(&target.slug, &key, &format!("board: {error}"));
                    }
                }
                (true, false) => {
                    self.append_lines(&self.dirs.inbox(&key), &events);
                    if !routing.handled.is_empty() {
                        let mut saved = self.routing(&key);
                        saved.add(routing.clone());
                        self.write_routing(&key, &saved);
                    }
                }
                (false, _) => self.append_lines(&self.dirs.inbox(&key), &events),
            }
        }
        self.log(&target.slug, &target.key, &format!("routed {} event(s)", routed.len()));
    }

    pub fn add_rows(&self, target: &Target, input: &ReportInput) {
        for add in &input.add {
            let text = add.what.as_deref().or(add.result.as_deref()).unwrap_or_default();
            self.log(&target.slug, &target.key, &format!("row: {text}"));
        }
        if let Err(error) = self.build(&target.slug, Mode::Hub, &[], input, &[]) {
            self.log(&target.slug, &target.key, &format!("board: {error}"));
        }
    }

    fn retry_counts(&self, key: &str) -> BTreeMap<String, u32> {
        let text = std::fs::read_to_string(self.dirs.retries(key)).unwrap_or_default();
        serde_json::from_str(&text).unwrap_or_default()
    }

    /// `job` is `<pipeline id>:<job name>`.
    pub fn retry_count(&self, key: &str, job: &str) -> u32 {
        self.retry_counts(key).get(job).copied().unwrap_or(0)
    }

    pub fn set_retry_count(&self, key: &str, job: &str, count: u32) {
        let mut counts = self.retry_counts(key);
        counts.insert(job.to_string(), count);
        let text = serde_json::to_string(&counts).expect("the counts serialize");
        if let Err(error) = write_atomic(&self.dirs.retries(key), &text) {
            self.log("", key, &format!("retry count not written: {error}"));
        }
    }

    pub fn routing(&self, key: &str) -> Routing {
        let text = std::fs::read_to_string(self.dirs.routing(key)).unwrap_or_default();
        serde_json::from_str(&text).unwrap_or_default()
    }

    fn write_routing(&self, key: &str, routing: &Routing) {
        let path = self.dirs.routing(key);
        if routing.handled.is_empty() {
            remove(&path);
            return;
        }
        let text = serde_json::to_string(routing).expect("a routing serializes");
        if let Err(error) = write_atomic(&path, &text) {
            self.log("", key, &format!("routing not written: {error}"));
        }
    }

    pub fn open_item(&self, key: &str, item: &str) -> Option<Item> {
        let items: Items = self.read(&self.dirs.items(key))?;
        items.items.into_iter().find(|open| open.item == item)
    }

    fn live_hub(&self, slug: &str) -> bool {
        self.live_subs(Some(slug)).iter().any(|agent| agent.mode == Mode::Hub)
    }

    pub fn close_item(&self, key: &str, item: &str) {
        let path = self.dirs.items(key);
        let Ok(Some(mut items)) = self.read_json::<Items>(&path) else {
            return;
        };
        let count = items.items.len();
        items.items.retain(|open| open.item != item);
        if items.items.len() < count {
            self.save_items(&path, &items);
        }
    }

    pub fn prune_items(&self, target: &Target) {
        let strings = |value: &serde_json::Value| -> Option<Vec<String>> {
            value
                .as_array()
                .map(|list| list.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        };
        let Some(present) = self
            .engine_value(&target.key)
            .and_then(|engine| strings(&engine["present"]))
        else {
            return;
        };
        let path = self.dirs.items(&target.key);
        if let Ok(Some(mut items)) = self.read_json::<Items>(&path) {
            let hub = match target.mode {
                Mode::Hub => None,
                Mode::Author | Mode::Review => self
                    .engine_value(&target.slug)
                    .and_then(|engine| strings(&engine["present"])),
            };
            prune_items(&mut items, &present, hub.as_deref(), target.mode);
            self.save_items(&path, &items);
        }
        if target.mode == Mode::Hub {
            return;
        }
        let hub_path = self.dirs.items(&target.slug);
        if let Ok(Some(mut hub_items)) = self.read_json::<Items>(&hub_path) {
            prune_moved(&mut hub_items, &target.mrs, &present);
            self.save_items(&hub_path, &hub_items);
        }
    }

    pub fn live_agent(&self, key: &str) -> bool {
        self.sub(key).is_some()
    }

    /// The merged and closed MRs leave the polling of the worktree. Returns true if this ended
    /// the agent record of the key.
    pub fn end_mrs(&self, target: &Target, routed: &[RoutedEvent]) -> bool {
        let ended_events: Vec<&RoutedEvent> = routed
            .iter()
            .filter(|event| matches!(event.event.kind, EventKind::Merged | EventKind::Closed))
            .collect();
        if ended_events.is_empty() {
            return false;
        }
        let ended: Vec<u64> = ended_events.iter().filter_map(|event| event.event.iid).collect();
        if target.mode == Mode::Review {
            let reviews = self.reviews();
            let kept: Vec<ReviewLink> = reviews
                .iter()
                .filter(|link| link.worktree != target.repo || !ended.contains(&link.iid))
                .cloned()
                .collect();
            if kept.len() < reviews.len() {
                self.write_reviews(kept);
            }
        }
        if let Some(mut state) = self.worktree(&target.repo) {
            if target.mode == Mode::Author {
                state.ended.extend(&ended);
                state.ended.sort_unstable();
                state.ended.dedup();
            }
            state
                .ended_branches
                .extend(ended_events.iter().map(|event| event.event.branch.clone()));
            state.ended_branches.sort_unstable();
            state.ended_branches.dedup();
            // The next local round runs the conflict test again, without the ended branches.
            state.key.clear();
            self.write_worktree(&state);
        }
        let Some(mut sub) = self.sub(&target.key) else {
            return false;
        };
        let all = add_ended(&mut sub, routed, &target.mrs);
        self.write_sub(&sub);
        if all {
            self.remove_record(&sub, ALL_ENDED, None);
        }
        all
    }

    pub fn move_items(&self, source: &str, target: &str, iid: Option<u64>) {
        let source_path = self.dirs.items(source);
        let Ok(Some(mut from)) = self.read_json::<Items>(&source_path) else {
            return;
        };
        let target_path = self.dirs.items(target);
        let Ok(to) = self.read_json::<Items>(&target_path) else {
            return;
        };
        let mut to = to.unwrap_or_default();
        if move_items(&mut from, &mut to, iid) > 0 {
            match self.save_items(&target_path, &to) {
                true => self.save_items(&source_path, &from),
                // The source keeps the items.
                false => return,
            };
        }
        if iid.is_none() {
            remove(&source_path);
        }
    }

    pub fn prune(&self, now: i64) {
        let cut = now - 7 * 86400;
        if let Ok(text) = std::fs::read_to_string(self.dirs.events()) {
            self.write_text(&self.dirs.events(), &prune_lines(&text, cut));
        }
        let Ok(entries) = std::fs::read_dir(&self.dirs.engine) else {
            return;
        };
        for entry in entries.filter_map(Result::ok) {
            let name = entry.file_name().to_string_lossy().to_string();
            let Some(key) = name.strip_suffix(".json") else {
                continue;
            };
            let modified = entry.metadata().ok().and_then(|meta| meta.modified().ok());
            let seconds = modified
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(now, |duration| duration.as_secs() as i64);
            if !self.dirs.sub(key).exists() && seconds < cut {
                remove(&entry.path());
                self.log("", key, "old engine state removed");
            }
        }
    }

    /// A new hub gets the open items of the hub first. A new session is away until its first
    /// wait: with no waiter, its records end after the grace period.
    pub fn watch(&self, request: &WatchRequest, now: i64) {
        let old = self.sub(&request.key);
        let replaced = old.as_ref().filter(|old| old.session != request.session);
        if let Some(old) = replaced
            && let Some(mut first) = self.session(&old.session)
        {
            let taken = SessionKey {
                key: old.key.clone(),
                mode: old.mode,
            };
            if !first.replaced.contains(&taken) {
                first.replaced.push(taken);
                self.write_session(&old.session, &first);
            }
        }
        // A session that takes its key back has the watch again.
        if let Some(mut own) = self.session(&request.session)
            && own.replaced.iter().any(|taken| taken.key == request.key)
        {
            own.replaced.retain(|taken| taken.key != request.key);
            self.write_session(&request.session, &own);
        }
        if old.is_none() && request.mode == Mode::Hub && !self.inbox_has_events(&request.key) {
            self.append_lines(&self.dirs.inbox(&request.key), &self.open_events(&request.key));
        }
        let ended: Vec<u64> = old
            .map(|old| {
                old.ended_mrs
                    .into_iter()
                    .filter(|iid| request.mrs.contains(iid))
                    .collect()
            })
            .unwrap_or_default();
        let sub = Agent {
            key: request.key.clone(),
            slug: request.slug.clone(),
            repo: request.repo.clone(),
            mode: request.mode,
            mrs: request.mrs.clone(),
            interval: request.interval,
            session: request.session.clone(),
            ended_mrs: ended,
        };
        self.write_sub(&sub);
        if self.session(&sub.session).is_none() {
            let session = Session {
                owner_gone_at: Some(now),
                ..Session::default()
            };
            self.write_session(&sub.session, &session);
        }
        let kind = kind_of(sub.mode);
        self.update_worktree(&sub.repo, |state| {
            state.kind.get_or_insert(kind);
        });
        let mrs: Vec<String> = sub.mrs.iter().map(u64::to_string).collect();
        self.log(
            &sub.slug,
            &sub.key,
            &format!("subscribed: {} {}", sub.mode.as_str(), mrs.join(" ")),
        );
    }

    pub fn take_error(&self, key: &str) -> Option<String> {
        let text = std::fs::read_to_string(self.dirs.error(key)).ok()?;
        remove(&self.dirs.error(key));
        Some(text)
    }

    pub fn put_back_error(&self, session: &str, ended: &SessionKey, text: &str) {
        if let Err(error) = write_atomic(&self.dirs.error(&ended.key), text) {
            self.log("", &ended.key, &format!("error file not written: {error}"));
        }
        let mut state = self.session(session).unwrap_or_default();
        if !state.ended.contains(ended) {
            state.ended.push(ended.clone());
            self.write_session(session, &state);
        }
    }

    pub fn unsubscribe(&self, key: &str, slug: &str, mode: Mode, session: &str) -> Result<(), String> {
        let sub = self.sub(key);
        if let Some(sub) = &sub
            && sub.session != session
            && self.live_session(&sub.session)
        {
            return Err(format!("the subscription {key} is of session {}", sub.session));
        }
        match mode {
            Mode::Author | Mode::Review => self.move_items(key, slug, None),
            Mode::Hub => {}
        }
        for path in [
            self.dirs.sub(key),
            self.dirs.inbox(key),
            self.dirs.error(key),
            self.dirs.last(key),
        ] {
            remove(&path);
        }
        if let Some(sub) = sub {
            self.update_worktree(&sub.repo, |state| state.stage = Some(Stage::Stopped));
        }
        self.log(slug, key, "unsubscribed");
        Ok(())
    }

    /// The router fields of the rows of the delivery join the input of the model.
    pub fn report(&self, key: &str, mode: Mode, mrs: &[u64], input: &ReportInput) -> Result<String, String> {
        let text = std::fs::read_to_string(self.dirs.last(key)).unwrap_or_default();
        let delivery: Vec<RoutedEvent> = text
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(serde_json::from_str)
            .collect::<Result<_, _>>()
            .map_err(|_| unreadable())?;
        let rows: Vec<u64> = delivery.iter().map(|event| event.row).collect();
        let mut saved = self.routing(key);
        let routed = saved.take(&rows).input;
        let mut input = input.clone();
        for (row, cell) in routed.cells {
            input.cells.entry(row).or_insert(cell);
        }
        input.agent.extend(routed.agent);
        input.close.extend(routed.close);
        input.add.extend(routed.add);
        let text = self.build(key, mode, mrs, &input, &delivery)?;
        self.write_routing(key, &saved);
        Ok(text)
    }

    fn build(
        &self,
        key: &str,
        mode: Mode,
        mrs: &[u64],
        input: &ReportInput,
        delivery: &[RoutedEvent],
    ) -> Result<String, String> {
        let path = self.dirs.items(key);
        let items = self
            .read_json::<Items>(&path)
            .map_err(|_| unreadable())?
            .unwrap_or_default();
        let mut titles = BTreeMap::new();
        if let Some(engine) = self.engine_value(key)
            && let Some(mrs) = engine["mrs"].as_object()
        {
            for (iid, mr) in mrs {
                if let (Ok(iid), Some(title)) = (iid.parse(), mr["title"].as_str()) {
                    titles.insert(iid, title.to_string());
                }
            }
        }
        let (items, data) = build_report(input, &items, delivery, &titles, now_seconds());
        save(&path, &items).map_err(|error| format!("report: {}: {error}", path.display()))?;
        let (hour, minute, _) = local_time(now_seconds());
        let time = format!("{hour:02}:{minute:02}");
        let text = render(mode, &time, mrs, &data);
        if mode == Mode::Hub {
            self.write_board(key, &Board::of(&time, &data));
        }
        Ok(text)
    }

    fn write_board(&self, key: &str, board: &Board) {
        if let Err(error) = write_json(&self.dirs.board(key), board) {
            self.log("", key, &format!("board not written: {error}"));
        }
    }

    fn json_files<T: DeserializeOwned>(&self, dir: &Path, suffix: &str) -> BTreeMap<String, T> {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return BTreeMap::new();
        };
        entries
            .filter_map(|entry| {
                let entry = entry.ok()?;
                let name = entry.file_name().into_string().ok()?;
                let key = name.strip_suffix(suffix)?.to_string();
                let value = self.read(&entry.path())?;
                Some((key, value))
            })
            .collect()
    }

    pub fn sidebar(&self) -> serde_json::Value {
        let subs: Vec<serde_json::Value> = self
            .subs()
            .into_iter()
            .map(|sub| {
                let live = self.live_session(&sub.session);
                let mut value = serde_json::to_value(sub).expect("a record serializes");
                value["live"] = serde_json::Value::Bool(live);
                value
            })
            .collect();
        let engine_needs: BTreeMap<String, serde_json::Value> = subs
            .iter()
            .filter_map(|sub| {
                let key = sub["key"].as_str()?.to_string();
                let needs = self
                    .engine_value(&key)
                    .map_or(serde_json::json!([]), |engine| engine["needs"].clone());
                Some((key, if needs.is_null() { serde_json::json!([]) } else { needs }))
            })
            .collect();
        let worktrees: BTreeMap<String, WorktreeState> = self
            .worktrees()
            .into_iter()
            .map(|state| (state.path.display().to_string(), state))
            .collect();
        serde_json::json!({
            "type": "sidebar",
            "subs": subs,
            "engine_needs": engine_needs,
            "worktrees": worktrees,
        })
    }

    pub fn debug_disk(&self) -> DebugState {
        let mut inbox = BTreeMap::new();
        let mut errors = BTreeMap::new();
        if let Ok(entries) = std::fs::read_dir(self.dirs.watchd.join("inbox")) {
            for name in entries.filter_map(|entry| entry.ok()?.file_name().into_string().ok()) {
                if let Some(key) = name.strip_suffix(".jsonl").filter(|key| !key.ends_with(".last")) {
                    let text = std::fs::read_to_string(self.dirs.inbox(key)).unwrap_or_default();
                    let events: Vec<RoutedEvent> = text
                        .lines()
                        .filter_map(|line| serde_json::from_str(line).ok())
                        .collect();
                    inbox.insert(key.to_string(), events);
                }
                if let Some(key) = name.strip_suffix(".error") {
                    errors.insert(
                        key.to_string(),
                        std::fs::read_to_string(self.dirs.error(key)).unwrap_or_default(),
                    );
                }
            }
        }
        DebugState {
            subs: self.json_files(&self.dirs.watchd.join("subs"), ".json"),
            inbox,
            errors,
            items: self.json_files(&self.dirs.watchd.join("items"), ".json"),
            engine: self.json_files(&self.dirs.engine, ".json"),
            worktrees: self
                .worktrees()
                .into_iter()
                .map(|state| (state.path.display().to_string(), state))
                .collect(),
            sessions: self.json_files(&self.dirs.watchd.join("sessions"), ".json"),
            ..DebugState::default()
        }
    }

    pub fn sub_status(&self) -> Vec<SubStatus> {
        self.subs()
            .into_iter()
            .map(|sub| SubStatus {
                live: self.live_session(&sub.session),
                inbox_lines: self.inbox_lines(&sub.key),
                sub,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_of_an_unknown_format_is_removed_with_a_log_line() {
        let base = std::env::temp_dir().join(format!("watchd-store-{}-format", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let store = Store::new(StateDirs {
            watchd: base.join("watchd"),
            engine: base.join("watch-gitlab"),
        });
        store.ensure_dirs().unwrap();
        std::fs::write(store.dirs.sub("app"), r#"{"version": 9, "key": "app"}"#).unwrap();

        assert!(store.sub("app").is_none());

        assert!(!store.dirs.sub("app").exists());
        let log = std::fs::read_to_string(store.dirs.log()).unwrap();
        let expected = format!(
            "{}: format 9 not supported, record removed\n",
            store.dirs.sub("app").display()
        );
        assert!(log.ends_with(&expected), "{log}");
    }

    #[test]
    fn put_back_inbox_puts_the_events_before_the_newer_lines() {
        let base = std::env::temp_dir().join(format!("watchd-store-{}-put-back", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let store = Store::new(StateDirs {
            watchd: base.join("watchd"),
            engine: base.join("watch-gitlab"),
        });
        store.ensure_dirs().unwrap();
        let line = |row| {
            format!(
                r#"{{"kind":"unaddressed","iid":5,"title":"T","url":"u","actor":"anna","detail":"d","branch":"b","row":{row}}}"#
            )
        };
        std::fs::write(store.dirs.inbox("app"), format!("{}\n{}\n", line(1), line(2))).unwrap();
        let taken = store.take_inbox("app");
        std::fs::write(store.dirs.inbox("app"), format!("{}\n", line(3))).unwrap();

        store.put_back_inbox("app", &taken);

        let rows: Vec<u64> = store.take_inbox("app").iter().map(|event| event.row).collect();
        assert_eq!(rows, [1, 2, 3]);
    }

    #[test]
    fn put_back_error_gives_the_error_to_the_next_wait_of_the_session() {
        let base = std::env::temp_dir().join(format!("watchd-store-{}-put-back-error", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let store = Store::new(StateDirs {
            watchd: base.join("watchd"),
            engine: base.join("watch-gitlab"),
        });
        store.ensure_dirs().unwrap();
        let ended = SessionKey {
            key: "app".to_string(),
            mode: Mode::Hub,
        };
        store.write_session("s1", &Session::default());
        std::fs::write(store.dirs.error("app"), "watchd: HTTP 403\n").unwrap();
        let text = store.take_error("app").unwrap();

        store.put_back_error("s1", &ended, &text);
        store.put_back_error("s1", &ended, &text);

        assert_eq!(store.take_error("app").as_deref(), Some("watchd: HTTP 403\n"));
        assert_eq!(store.session("s1").unwrap().ended, [ended]);
    }

    #[test]
    fn report_has_the_router_rows_of_its_delivery_and_keeps_the_others() {
        let base = std::env::temp_dir().join(format!("watchd-store-{}-routing", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let store = Store::new(StateDirs {
            watchd: base.join("watchd"),
            engine: base.join("watch-gitlab"),
        });
        store.ensure_dirs().unwrap();
        let todo = |row: u64| RoutedEvent {
            event: Event::new(
                EventKind::Todo,
                Some(row),
                Some("Add foo"),
                "u",
                "anna",
                "mentioned",
                "b",
            ),
            row,
        };
        store.write_last("app", &[todo(1), todo(2)]);
        let mut routing = Routing::default();
        for row in [1, 3] {
            routing
                .input
                .cells
                .insert(row.to_string(), format!("router cell {row}").into());
            routing.handled.push(row);
        }
        store.write_routing("app", &routing);

        let text = store.report("app", Mode::Hub, &[], &ReportInput::default()).unwrap();

        assert!(text.contains("router cell 1"), "{text}");
        assert_eq!(store.routing("app").handled, [3]);
    }

    #[test]
    fn report_writes_the_board_file() {
        let base = std::env::temp_dir().join(format!("watchd-store-{}-board", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let store = Store::new(StateDirs {
            watchd: base.join("watchd"),
            engine: base.join("watch-gitlab"),
        });
        store.ensure_dirs().unwrap();

        let text = store.report("app", Mode::Hub, &[], &ReportInput::default()).unwrap();

        let board: Board = serde_json::from_str(&std::fs::read_to_string(store.dirs.board("app")).unwrap()).unwrap();
        assert_eq!(board.time, text);
        assert_eq!(board.rows, []);
    }
}
