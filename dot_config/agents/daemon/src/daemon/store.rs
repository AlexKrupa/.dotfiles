//! The daemon state files, with the daemon as the only writer: each function runs under its state
//! lock.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::core::eventlog::{LogLine, event_line, id_of, next_id, prune_lines, stopped_line};
use crate::core::items::{Item, Items, Owner, RoutedEvent, assign_rows, move_items, prune_items, prune_moved};
use crate::core::subs::{Agent, Mode, add_ended};
use crate::core::workspaces::{Kind, Stage, Workspace};
use crate::core::worktrees::{Repos, ReviewLink, Reviews, Target, WorktreeState};
use crate::engine::event::{Event, EventKind};
use crate::engine::state::Need;
use crate::local::repo_of;
use crate::paths::StateDirs;
use crate::persist::{Load, load, save};
use crate::platform::{local_time, now_seconds, process_alive, utc_timestamp};
use crate::protocol::{DebugState, SubStatus, SubscribeArgs};
use crate::report::{ReportInput, build_report, render};

pub const ALL_ENDED: &str = "all MRs merged or closed";

pub struct Store {
    pub dirs: StateDirs,
    last_id: std::sync::Mutex<Option<u64>>,
}

fn remove(path: &Path) {
    let _ = std::fs::remove_file(path);
}

pub fn is_worktree_key(key: &str) -> bool {
    let key = match key.rsplit_once("-review-") {
        Some((front, iid)) if !iid.is_empty() && iid.bytes().all(|byte| byte.is_ascii_digit()) => front,
        _ => key,
    };
    key.len() > 13
        && key.as_bytes()[key.len() - 13] == b'-'
        && key[key.len() - 12..]
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

pub fn first_line(text: &str) -> &str {
    text.lines().next().unwrap_or_default()
}

fn kind_of(mode: Mode) -> Kind {
    match mode {
        Mode::Hub => Kind::Hub,
        Mode::Stack => Kind::Mine,
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

    fn read_json<T: DeserializeOwned>(&self, path: &Path) -> Result<Option<T>, String> {
        match load(path)? {
            None => Ok(None),
            Some(Load::Current(data) | Load::Converted(data)) => Ok(Some(data)),
            Some(Load::Dropped(reason)) => {
                remove(path);
                self.log("", "", &format!("{}: {reason}, record removed", path.display()));
                Ok(None)
            }
        }
    }

    pub fn ensure_dirs(&self) -> std::io::Result<()> {
        for dir in ["subs", "inbox", "items", "worktrees"] {
            std::fs::create_dir_all(self.dirs.watchd.join(dir))?;
        }
        Ok(())
    }

    pub fn log(&self, slug: &str, key: &str, message: &str) {
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
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dirs.log());
        if let Ok(mut file) = file {
            let _ = file.write_all(line.as_bytes());
        }
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
        self.read_json(&self.dirs.sub(key)).ok().flatten()
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

    pub fn live_subs(&self, slug: Option<&str>) -> Vec<Agent> {
        self.subs()
            .into_iter()
            .filter(|sub| slug.is_none_or(|slug| sub.slug == slug))
            .filter(|sub| process_alive(sub.session_pid))
            .collect()
    }

    pub fn write_sub(&self, sub: &Agent) {
        if let Err(error) = save(&self.dirs.sub(&sub.key), sub) {
            self.log(&sub.slug, &sub.key, &format!("record not written: {error}"));
        }
    }

    pub fn repos(&self) -> Vec<PathBuf> {
        let repos: Option<Repos> = self.read_json(&self.dirs.repos()).ok().flatten();
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

    /// Returns the repos whose folder is gone.
    pub fn drop_gone_repos(&self) -> Vec<PathBuf> {
        let (kept, gone): (Vec<PathBuf>, Vec<PathBuf>) = self.repos().into_iter().partition(|repo| repo.is_dir());
        if !gone.is_empty() {
            self.write_repos(kept);
        }
        gone
    }

    pub fn reviews(&self) -> Vec<ReviewLink> {
        let reviews: Option<Reviews> = self.read_json(&self.dirs.reviews()).ok().flatten();
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

    pub fn write_worktree(&self, state: &WorktreeState) {
        let written = self
            .dirs
            .worktree(&state.path)
            .and_then(|path| save(&path, state).map_err(|error| error.to_string()));
        if let Err(error) = written {
            self.log("", "", &format!("{}: state not written: {error}", state.path.display()));
        }
    }

    pub fn remove_worktree(&self, path: &Path) {
        if let Ok(file) = self.dirs.worktree(path) {
            remove(&file);
        }
    }

    pub fn inbox_lines(&self, key: &str) -> usize {
        std::fs::read_to_string(self.dirs.inbox(key)).map_or(0, |text| text.lines().count())
    }

    fn inbox_has_events(&self, key: &str) -> bool {
        std::fs::metadata(self.dirs.inbox(key)).is_ok_and(|meta| meta.len() > 0)
    }

    /// The events of the MRs in `mrs`, or all events for an empty list. The other events stay.
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

    /// The saved event of each open daemon item, for the first delivery of a new hub.
    pub fn open_events(&self, key: &str) -> Vec<RoutedEvent> {
        let items: Items = self.read_json(&self.dirs.items(key)).ok().flatten().unwrap_or_default();
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
        remove(&path);
        self.append_lines(&path, events);
        let file = std::fs::OpenOptions::new().append(true).open(&path);
        if let Ok(mut file) = file {
            let _ = file.write_all(newer.as_bytes());
        }
    }

    fn append_lines<T: Serialize>(&self, path: &Path, values: &[T]) {
        let text: String = values
            .iter()
            .map(|value| serde_json::to_string(value).expect("a line serializes") + "\n")
            .collect();
        let file = std::fs::OpenOptions::new().create(true).append(true).open(path);
        if let Ok(mut file) = file {
            let _ = file.write_all(text.as_bytes());
        }
    }

    /// The delivery that the next `report` shows.
    pub fn write_last(&self, key: &str, events: &[RoutedEvent]) {
        let path = self.dirs.last(key);
        remove(&path);
        self.append_lines(&path, events);
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
        let known = self.worktrees().into_iter().find(|state| state.path == path);
        let mut state = known.unwrap_or_else(|| {
            let repo = repo_of(&path).unwrap_or_else(|| path.clone());
            WorktreeState::new(path.clone(), repo, None, String::new(), &[])
        });
        change(&mut state);
        self.write_worktree(&state);
    }

    /// Format version 1 kept the kind and the stage in a record of each herdr workspace. An
    /// agent record of the workspace gives its worktree. The other records go away.
    pub fn convert_workspaces(&self) {
        let mut used = Vec::new();
        for mut sub in self.subs() {
            let Some(id) = sub.herdr_workspace.take() else {
                continue;
            };
            if let Ok(Some(record)) = self.read_json::<Workspace>(&self.dirs.workspace(&id)) {
                self.update_worktree(&sub.repo, |state| {
                    state.kind = record.kind.or(state.kind);
                    state.stage = record.stage;
                });
            }
            self.write_sub(&sub);
            used.push(id);
        }
        let folder = self.dirs.watchd.join("workspaces");
        let Ok(entries) = std::fs::read_dir(&folder) else {
            return;
        };
        for name in entries.filter_map(|entry| entry.ok()?.file_name().into_string().ok()) {
            let Some(id) = name.strip_suffix(".json") else {
                continue;
            };
            remove(&self.dirs.workspace(id));
            if !used.iter().any(|known| known == id) {
                self.log("", "", &format!("workspace record dropped: {id}"));
            }
        }
        let _ = std::fs::remove_dir(&folder);
    }

    pub fn engine_value(&self, key: &str) -> Option<serde_json::Value> {
        self.read_json(&self.dirs.engine_state(key)).ok().flatten()
    }

    /// Writes the error before it removes the record: the next client of the session must see the
    /// error first.
    pub fn remove_record(&self, sub: &Agent, reason: &str, error: Option<&str>) {
        if let Some(text) = error {
            let _ = std::fs::write(self.dirs.error(&sub.key), text);
            let title = match sub.mode {
                Mode::Hub => None,
                Mode::Stack | Mode::Review => sub.mrs.first().and_then(|iid| {
                    let engine = self.engine_value(&sub.key)?;
                    engine["mrs"][iid.to_string()]["title"].as_str().map(str::to_string)
                }),
            };
            let line = stopped_line(&sub.slug, &sub.key, sub.mode, now_seconds(), title, first_line(text));
            self.event_log(vec![LogLine::Stopped(line)]);
        }
        let _ = std::fs::write(self.dirs.owner(&sub.key), format!("{}\n", sub.session_pid));
        match sub.mode {
            Mode::Stack | Mode::Review => self.move_items(&sub.key, &sub.slug, None),
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

    pub fn end_if_due(&self, sub: &Agent, now: i64, client_seconds: i64) -> bool {
        let reason = if !process_alive(sub.session_pid) {
            format!("session {} is gone", sub.session_pid)
        } else if !process_alive(sub.client_pid) && now - sub.client_at > client_seconds {
            format!("no client for {client_seconds} seconds")
        } else {
            return false;
        };
        self.remove_record(sub, &reason, None);
        true
    }

    /// The hub keeps its items: the present rules close them, and a new hub session gets them.
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
        for key in keys {
            if self.dirs.sub(&key).exists() {
                continue;
            }
            let owner = std::fs::read_to_string(self.dirs.owner(&key)).ok();
            let owner_alive = owner
                .and_then(|owner| owner.trim().parse().ok())
                .is_some_and(process_alive);
            if owner_alive {
                continue;
            }
            for path in [
                self.dirs.inbox(&key),
                self.dirs.error(&key),
                self.dirs.owner(&key),
                self.dirs.last(&key),
            ] {
                remove(&path);
            }
            if is_worktree_key(&key) {
                remove(&self.dirs.items(&key));
            }
            self.log("", &key, "results of an ended subscription removed");
        }
    }

    /// A live agent of the key gets the events in its inbox. With no live agent, the events of a
    /// worktree key are items of the hub, and a live hub gets the events that have an item.
    pub fn route(&self, target: &Target, events: Vec<Event>, now: i64) -> Vec<RoutedEvent> {
        let count = events.len();
        let live = self.live_agent(&target.key);
        let owner = match (live, target.mode) {
            (false, Mode::Stack | Mode::Review) => {
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
                let _ = save(&path, &items);
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
            .map(|event| LogLine::Event(event_line(&target.slug, &target.key, target.mode, now, event.clone())))
            .collect();
        self.event_log(lines);
        match (live, target.mode) {
            (true, _) => self.append_lines(&self.dirs.inbox(&target.key), &routed),
            (false, Mode::Stack | Mode::Review) if self.live_hub(&target.slug) => {
                let items: Vec<RoutedEvent> = routed
                    .iter()
                    .filter(|event| event.event.item.is_some())
                    .cloned()
                    .collect();
                self.append_lines(&self.dirs.inbox(&target.slug), &items);
            }
            (false, _) => {}
        }
        self.log(&target.slug, &target.key, &format!("routed {count} event(s)"));
        routed
    }

    pub fn open_item(&self, key: &str, item: &str) -> Option<Item> {
        let items: Items = self.read_json(&self.dirs.items(key)).ok().flatten()?;
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
            let _ = save(&path, &items);
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
                Mode::Stack | Mode::Review => self
                    .engine_value(&target.slug)
                    .and_then(|engine| strings(&engine["present"])),
            };
            prune_items(&mut items, &present, hub.as_deref(), target.mode);
            let _ = save(&path, &items);
        }
        if target.mode == Mode::Hub {
            return;
        }
        let hub_path = self.dirs.items(&target.slug);
        if let Ok(Some(mut hub_items)) = self.read_json::<Items>(&hub_path) {
            prune_moved(&mut hub_items, &target.mrs, &present);
            let _ = save(&hub_path, &hub_items);
        }
    }

    pub fn live_agent(&self, key: &str) -> bool {
        self.sub(key).is_some_and(|sub| process_alive(sub.session_pid))
    }

    /// The merged and closed MRs leave the polling of the worktree. Returns true if this ended
    /// the agent record of the key.
    pub fn end_mrs(&self, target: &Target, routed: &[RoutedEvent]) -> bool {
        let ended: Vec<u64> = routed
            .iter()
            .filter(|event| matches!(event.event.kind, EventKind::Merged | EventKind::Closed))
            .filter_map(|event| event.event.iid)
            .collect();
        if ended.is_empty() {
            return false;
        }
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
        let worktree = self.worktrees().into_iter().find(|state| state.path == target.repo);
        if let Some(mut state) = worktree.filter(|_| target.mode == Mode::Stack) {
            state.ended.extend(&ended);
            state.ended.sort_unstable();
            state.ended.dedup();
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
            let _ = save(&target_path, &to);
            let _ = save(&source_path, &from);
        }
        if iid.is_none() {
            remove(&source_path);
        }
    }

    pub fn prune(&self, now: i64) {
        let cut = now - 7 * 86400;
        if let Ok(text) = std::fs::read_to_string(self.dirs.events()) {
            let mut temp = self.dirs.events().into_os_string();
            temp.push(".tmp");
            if std::fs::write(&temp, prune_lines(&text, cut)).is_ok() {
                let _ = std::fs::rename(&temp, self.dirs.events());
            }
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

    /// Returns true if the key needs a first check now.
    pub fn subscribe(&self, args: &SubscribeArgs, old: Option<&Agent>, now: i64) -> bool {
        let mut replaced: Vec<u32> = old.map(|old| old.replaced_sessions.clone()).unwrap_or_default();
        if let Some(old) = old
            && old.session_pid != args.session_pid
            && process_alive(old.session_pid)
        {
            replaced.push(old.session_pid);
        }
        replaced.sort_unstable();
        replaced.dedup();
        let ended: Vec<u64> = old
            .map(|old| {
                old.ended_mrs
                    .iter()
                    .copied()
                    .filter(|iid| args.mrs.contains(iid))
                    .collect()
            })
            .unwrap_or_default();
        let sub = Agent {
            key: args.key.clone(),
            slug: args.slug.clone(),
            repo: args.repo.clone(),
            mode: args.mode,
            mrs: args.mrs.clone(),
            interval: args.interval,
            session_pid: args.session_pid,
            client_pid: args.client_pid,
            client_at: now,
            replaced_sessions: replaced,
            ended_mrs: ended,
            herdr_workspace: None,
        };
        self.write_sub(&sub);
        remove(&self.dirs.owner(&sub.key));
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
        old.is_none() || args.once || args.again
    }

    /// Returns true if the results of an ended subscription wait for this client, which then does
    /// not subscribe again.
    pub fn ended_with_result(&self, key: &str, session_pid: u32) -> bool {
        let owner = std::fs::read_to_string(self.dirs.owner(key)).unwrap_or_default();
        if owner.trim() != session_pid.to_string() {
            for path in [self.dirs.inbox(key), self.dirs.error(key), self.dirs.owner(key)] {
                remove(&path);
            }
        }
        self.dirs.error(key).exists() || self.inbox_has_events(key)
    }

    pub fn take_error(&self, key: &str) -> Option<String> {
        let text = std::fs::read_to_string(self.dirs.error(key)).ok()?;
        remove(&self.dirs.error(key));
        remove(&self.dirs.owner(key));
        Some(text)
    }

    pub fn remove_owner(&self, key: &str) {
        remove(&self.dirs.owner(key));
    }

    pub fn unsubscribe(&self, key: &str, slug: &str, mode: Mode, session_pid: u32) -> Result<(), String> {
        let sub = self.sub(key);
        if let Some(sub) = &sub
            && sub.session_pid != session_pid
            && process_alive(sub.session_pid)
        {
            return Err(format!("the subscription {key} is of session {}", sub.session_pid));
        }
        match mode {
            Mode::Stack | Mode::Review => self.move_items(key, slug, None),
            Mode::Hub => {}
        }
        for path in [
            self.dirs.sub(key),
            self.dirs.inbox(key),
            self.dirs.error(key),
            self.dirs.owner(key),
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

    pub fn report(&self, key: &str, mode: Mode, mrs: &[u64], input: &ReportInput) -> Result<String, String> {
        let unreadable = || "report: jq could not read the input or the state".to_string();
        let path = self.dirs.items(key);
        let items = self
            .read_json::<Items>(&path)
            .map_err(|_| unreadable())?
            .unwrap_or_default();
        let text = std::fs::read_to_string(self.dirs.last(key)).unwrap_or_default();
        let delivery: Vec<RoutedEvent> = text
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(serde_json::from_str)
            .collect::<Result<_, _>>()
            .map_err(|_| unreadable())?;
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
        let (items, data) = build_report(input, &items, &delivery, &titles, now_seconds());
        save(&path, &items).map_err(|error| format!("report: {}: {error}", path.display()))?;
        let (hour, minute, _) = local_time(now_seconds());
        Ok(render(mode, &format!("{hour:02}:{minute:02}"), mrs, &data))
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
                let value = self.read_json(&entry.path()).ok().flatten()?;
                Some((key, value))
            })
            .collect()
    }

    pub fn sidebar(&self) -> serde_json::Value {
        let subs: Vec<serde_json::Value> = self
            .subs()
            .into_iter()
            .map(|sub| {
                let live = process_alive(sub.session_pid);
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
            ..DebugState::default()
        }
    }

    /// The waiting clients of the repo stop with exit 3: their record gets another client.
    pub fn replace_clients(&self, repo: &Path) -> usize {
        let mut count = 0;
        for mut sub in self.subs().into_iter().filter(|sub| sub.repo == repo) {
            sub.client_pid = 0;
            self.write_sub(&sub);
            count += 1;
        }
        count
    }

    pub fn sub_status(&self) -> Vec<SubStatus> {
        self.subs()
            .into_iter()
            .map(|sub| SubStatus {
                live: process_alive(sub.session_pid),
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
    fn worktree_keys_have_the_hash_of_the_worktree() {
        assert!(is_worktree_key("app-0123456789ab"));
        assert!(is_worktree_key("app-0123456789ab-review-5"));
        assert!(!is_worktree_key("app"));
        assert!(!is_worktree_key("my-app"));
        assert!(!is_worktree_key("app-0123456789ab-review-"));
    }

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
}
