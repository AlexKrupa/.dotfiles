//! The files of the daemon state. The daemon is their only writer: each function runs under the
//! state lock of the daemon. The tests and the herdr plugin read the files.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::core::eventlog::{LogLine, event_line, id_of, next_id, prune_lines, stopped_line};
use crate::core::items::{Items, RoutedEvent, assign_rows, move_items, prune_items};
use crate::core::subs::{Mode, Subscription, add_ended};
use crate::core::workspaces::{Kind, Stage, Workspace};
use crate::engine::event::{Event, EventKind};
use crate::paths::StateDirs;
use crate::persist::{Load, load, save};
use crate::platform::{local_time, now_seconds, process_alive, utc_timestamp};
use crate::protocol::{DebugState, SubStatus, SubscribeArgs};
use crate::report::{ReportInput, build_report, render};

pub const ALL_ENDED: &str = "all MRs merged or closed";

pub struct Store {
    pub dirs: StateDirs,
    /// The last id of the event log, read from the log at the first append.
    last_id: std::sync::Mutex<Option<u64>>,
}

fn remove(path: &Path) {
    let _ = std::fs::remove_file(path);
}

/// `-<12 hex digits>` or `-<12 hex digits>-review-<iid>` at the end: a stack or review key.
pub fn is_worktree_key(key: &str) -> bool {
    let key = match key.rsplit_once("-review-") {
        Some((front, iid)) if !iid.is_empty() && iid.bytes().all(|byte| byte.is_ascii_digit()) => front,
        _ => key,
    };
    key.len() > 13
        && key.as_bytes()[key.len() - 13] == b'-'
        && key[key.len() - 12..].bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
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
        Store { dirs, last_id: std::sync::Mutex::new(None) }
    }

    /// A missing file is `Ok(None)`. A file that is not JSON of the type is an error. A record of
    /// an unknown format goes away: its subscription starts again with a first check.
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
        for dir in ["subs", "inbox", "items", "workspaces"] {
            std::fs::create_dir_all(self.dirs.watchd.join(dir))?;
        }
        Ok(())
    }

    /// One line of `watchd.log`: time, repo slug, subscription key, message. An empty slug or key
    /// is `-`.
    pub fn log(&self, slug: &str, key: &str, message: &str) {
        let dash = |text: &str| if text.is_empty() { "-".to_string() } else { text.to_string() };
        let line = format!("{} {} {} {message}\n", utc_timestamp(now_seconds()), dash(slug), dash(key));
        let file = std::fs::OpenOptions::new().create(true).append(true).open(self.dirs.log());
        if let Ok(mut file) = file {
            let _ = file.write_all(line.as_bytes());
        }
    }

    /// The log grows with each round. Thus it shrinks in place: the log file stays the stdout of
    /// the daemon.
    pub fn trim_log(&self) {
        let Ok(text) = std::fs::read_to_string(self.dirs.log()) else { return };
        let lines: Vec<&str> = text.lines().collect();
        if lines.len() <= 10_000 {
            return;
        }
        let kept: String = lines[lines.len() - 5000..].iter().map(|line| format!("{line}\n")).collect();
        if let Ok(mut file) = std::fs::OpenOptions::new().write(true).truncate(true).open(self.dirs.log()) {
            let _ = file.write_all(kept.as_bytes());
        }
    }

    pub fn sub(&self, key: &str) -> Option<Subscription> {
        self.read_json(&self.dirs.sub(key)).ok().flatten()
    }

    /// All readable records, in the order of their keys.
    pub fn subs(&self) -> Vec<Subscription> {
        let Ok(entries) = std::fs::read_dir(self.dirs.watchd.join("subs")) else { return Vec::new() };
        let mut keys: Vec<String> = entries
            .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
            .filter_map(|name| name.strip_suffix(".json").map(str::to_string))
            .collect();
        keys.sort();
        keys.iter().filter_map(|key| self.sub(key)).collect()
    }

    /// The subscriptions of `slug`, or of all repos, whose session runs.
    pub fn live_subs(&self, slug: Option<&str>) -> Vec<Subscription> {
        self.subs()
            .into_iter()
            .filter(|sub| slug.is_none_or(|slug| sub.slug == slug))
            .filter(|sub| process_alive(sub.session_pid))
            .collect()
    }

    pub fn write_sub(&self, sub: &Subscription) {
        if let Err(error) = save(&self.dirs.sub(&sub.key), sub) {
            self.log(&sub.slug, &sub.key, &format!("record not written: {error}"));
        }
    }

    pub fn inbox_lines(&self, key: &str) -> usize {
        std::fs::read_to_string(self.dirs.inbox(key)).map_or(0, |text| text.lines().count())
    }

    fn inbox_has_events(&self, key: &str) -> bool {
        std::fs::metadata(self.dirs.inbox(key)).is_ok_and(|meta| meta.len() > 0)
    }

    /// The events that wait in the inbox. The inbox goes away.
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

    /// The events of a delivery that did not get to the client.
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

    /// The delivery of the next `report`.
    pub fn write_last(&self, key: &str, events: &[RoutedEvent]) {
        let path = self.dirs.last(key);
        remove(&path);
        self.append_lines(&path, events);
    }

    /// The newest id of the event log.
    pub fn last_id(&self) -> u64 {
        let mut last_id = self.last_id.lock().expect("the id lock is never poisoned");
        *last_id.get_or_insert_with(|| {
            let text = std::fs::read_to_string(self.dirs.events()).unwrap_or_default();
            text.lines().map(id_of).max().unwrap_or(0)
        })
    }

    /// Appends the lines to the event log, each with a new id.
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
        let file = std::fs::OpenOptions::new().create(true).append(true).open(self.dirs.events());
        if let Ok(mut file) = file {
            let _ = file.write_all(text.as_bytes());
        }
    }

    /// Changes the workspace file. A missing file is `{}`. A file that is not JSON stays.
    pub fn workspace_update(&self, id: &str, change: impl FnOnce(&mut Workspace)) {
        let path = self.dirs.workspace(id);
        let Ok(workspace) = self.read_json::<Workspace>(&path) else { return };
        let mut workspace = workspace.unwrap_or_default();
        change(&mut workspace);
        let _ = std::fs::create_dir_all(self.dirs.watchd.join("workspaces"));
        let _ = save(&path, &workspace);
    }

    fn engine_value(&self, key: &str) -> Option<serde_json::Value> {
        self.read_json(&self.dirs.engine_state(key)).ok().flatten()
    }

    /// The error text goes to the next client of the session, which sees it before it sees that
    /// the record is gone. The owner file keeps the session of the results.
    pub fn remove_record(&self, sub: &Subscription, reason: &str, error: Option<&str>) {
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
            Mode::Review => self.move_items(&sub.key, &sub.slug, None),
            Mode::Hub | Mode::Stack => {}
        }
        remove(&self.dirs.sub(&sub.key));
        self.log(&sub.slug, &sub.key, &format!("subscription removed: {reason}"));
        if let Some(workspace) = &sub.herdr_workspace {
            let stage = if reason == ALL_ENDED { Stage::Done } else { Stage::Stopped };
            self.workspace_update(workspace, |workspace| workspace.stage = Some(stage));
        }
    }

    /// Ends the subscription if its session is gone, or if it has no client for the limit. True
    /// if it ended.
    pub fn end_if_due(&self, sub: &Subscription, now: i64, client_seconds: i64) -> bool {
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

    /// Removes the results of ended subscriptions whose session is gone, and results with no
    /// record and no owner. The open items of a stack or review key are results. The hub keeps its
    /// items: the present rules close them, and a new hub session gets them.
    pub fn sweep(&self) {
        let mut keys = Vec::new();
        for (dir, suffixes) in [("inbox", &[".jsonl", ".error"][..]), ("items", &[".json"][..])] {
            let Ok(entries) = std::fs::read_dir(self.dirs.watchd.join(dir)) else { continue };
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
            let owner_alive = owner.and_then(|owner| owner.trim().parse().ok()).is_some_and(process_alive);
            if owner_alive {
                continue;
            }
            for path in [self.dirs.inbox(&key), self.dirs.error(&key), self.dirs.owner(&key), self.dirs.last(&key)] {
                remove(&path);
            }
            if is_worktree_key(&key) {
                remove(&self.dirs.items(&key));
            }
            self.log("", &key, "results of an ended subscription removed");
        }
    }

    /// The events get their rows. Then they go to the event log, then to the inbox.
    pub fn route(&self, sub: &Subscription, events: Vec<Event>, now: i64) -> Vec<RoutedEvent> {
        let count = events.len();
        let path = self.dirs.items(&sub.key);
        let routed = match self.read_json::<Items>(&path) {
            Ok(items) => {
                let mut items = items.unwrap_or_default();
                let routed = assign_rows(&mut items, events, now);
                let _ = save(&path, &items);
                routed
            }
            // The engine saved its state: events that do not go out now are lost.
            Err(_) => {
                self.log(&sub.slug, &sub.key, "no rows: the items file is not readable");
                assign_rows(&mut Items::default(), events, now)
            }
        };
        let lines = routed
            .iter()
            .map(|event| LogLine::Event(event_line(&sub.slug, &sub.key, sub.mode, now, event.clone())))
            .collect();
        self.event_log(lines);
        self.append_lines(&self.dirs.inbox(&sub.key), &routed);
        self.log(&sub.slug, &sub.key, &format!("routed {count} event(s)"));
        routed
    }

    /// After a check: closes the daemon items whose cause GitLab does not show.
    pub fn prune_items(&self, sub: &Subscription) {
        let path = self.dirs.items(&sub.key);
        let Ok(Some(mut items)) = self.read_json::<Items>(&path) else { return };
        let strings = |value: &serde_json::Value| -> Option<Vec<String>> {
            value.as_array().map(|list| list.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        };
        let Some(present) = self.engine_value(&sub.key).and_then(|engine| strings(&engine["present"])) else {
            return;
        };
        let hub = match sub.mode {
            Mode::Hub => None,
            Mode::Stack | Mode::Review => self.engine_value(&sub.slug).and_then(|engine| strings(&engine["present"])),
        };
        prune_items(&mut items, &present, hub.as_deref(), sub.mode);
        let _ = save(&path, &items);
    }

    /// Adds the MRs of the merged and closed events to `ended_mrs`. If all MRs ended, the
    /// subscription ends. Its inbox stays until the client takes it.
    pub fn end_mrs(&self, key: &str, routed: &[RoutedEvent]) -> bool {
        let ended = routed.iter().any(|event| matches!(event.event.kind, EventKind::Merged | EventKind::Closed));
        let Some(mut sub) = self.sub(key).filter(|_| ended) else { return false };
        let all = add_ended(&mut sub, routed);
        self.write_sub(&sub);
        if all {
            self.remove_record(&sub, ALL_ENDED, None);
        }
        all
    }

    /// Moves the open items of `source`, or only the items of the MR `iid`, to `target`. With no
    /// `iid`, the source file goes away.
    pub fn move_items(&self, source: &str, target: &str, iid: Option<u64>) {
        let source_path = self.dirs.items(source);
        let Ok(Some(mut from)) = self.read_json::<Items>(&source_path) else { return };
        let target_path = self.dirs.items(target);
        let Ok(to) = self.read_json::<Items>(&target_path) else { return };
        let mut to = to.unwrap_or_default();
        if move_items(&mut from, &mut to, iid) > 0 {
            let _ = save(&target_path, &to);
            let _ = save(&source_path, &from);
        }
        if iid.is_none() {
            remove(&source_path);
        }
    }

    /// Removes the event log lines and the engine states with no record that are older than 7
    /// days.
    pub fn prune(&self, now: i64) {
        let cut = now - 7 * 86400;
        if let Ok(text) = std::fs::read_to_string(self.dirs.events()) {
            let mut temp = self.dirs.events().into_os_string();
            temp.push(".tmp");
            if std::fs::write(&temp, prune_lines(&text, cut)).is_ok() {
                let _ = std::fs::rename(&temp, self.dirs.events());
            }
        }
        let Ok(entries) = std::fs::read_dir(&self.dirs.engine) else { return };
        for entry in entries.filter_map(Result::ok) {
            let name = entry.file_name().to_string_lossy().to_string();
            let Some(key) = name.strip_suffix(".json") else { continue };
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

    /// Writes the record of a `watch` client. The newest session owns the key: it adds the old
    /// live session to `replaced_sessions`. True if the key needs a first check now.
    pub fn subscribe(&self, args: &SubscribeArgs, old: Option<&Subscription>, now: i64) -> bool {
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
            .map(|old| old.ended_mrs.iter().copied().filter(|iid| args.mrs.contains(iid)).collect())
            .unwrap_or_default();
        let sub = Subscription {
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
            herdr_workspace: args.herdr_workspace.clone(),
        };
        self.write_sub(&sub);
        remove(&self.dirs.owner(&sub.key));
        if let Some(workspace) = &sub.herdr_workspace {
            let kind = kind_of(sub.mode);
            self.workspace_update(workspace, |workspace| {
                workspace.kind.get_or_insert(kind);
            });
        }
        let mrs: Vec<String> = sub.mrs.iter().map(u64::to_string).collect();
        self.log(&sub.slug, &sub.key, &format!("subscribed: {} {}", sub.mode.as_str(), mrs.join(" ")));
        old.is_none() || args.once || args.again
    }

    /// The results of an ended subscription are only for the next client of its session. Gives
    /// true if they wait for this client: then it does not subscribe again.
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

    /// Ends the subscription of the repo and mode of a session. The open items of a review go
    /// back to the hub. The hub keeps its items.
    pub fn unsubscribe(&self, key: &str, slug: &str, mode: Mode, session_pid: u32) -> Result<(), String> {
        let sub = self.sub(key);
        if let Some(sub) = &sub
            && sub.session_pid != session_pid
            && process_alive(sub.session_pid)
        {
            return Err(format!("the subscription {key} is of session {}", sub.session_pid));
        }
        match mode {
            Mode::Review => self.move_items(key, slug, None),
            Mode::Stack => remove(&self.dirs.items(key)),
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
        if let Some(workspace) = sub.and_then(|sub| sub.herdr_workspace) {
            self.workspace_update(&workspace, |workspace| workspace.stage = Some(Stage::Stopped));
        }
        self.log(slug, key, "unsubscribed");
        Ok(())
    }

    /// The report of the last delivery and of the open items. The model input changes the items.
    pub fn report(&self, key: &str, mode: Mode, mrs: &[u64], input: &ReportInput) -> Result<String, String> {
        let unreadable = || "report: jq could not read the input or the state".to_string();
        let path = self.dirs.items(key);
        let items = self.read_json::<Items>(&path).map_err(|_| unreadable())?.unwrap_or_default();
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

    /// The readable JSON files of a folder, by name with no extension.
    fn json_files<T: DeserializeOwned>(&self, dir: &Path, suffix: &str) -> BTreeMap<String, T> {
        let Ok(entries) = std::fs::read_dir(dir) else { return BTreeMap::new() };
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

    /// The data of the sidebar: the workspace files, the records with their live state, and the
    /// needs of the engine state of each record.
    pub fn sidebar(&self) -> serde_json::Value {
        let workspaces: BTreeMap<String, serde_json::Value> =
            self.json_files(&self.dirs.watchd.join("workspaces"), ".json");
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
                let needs = self.engine_value(&key).map_or(serde_json::json!([]), |engine| engine["needs"].clone());
                Some((key, if needs.is_null() { serde_json::json!([]) } else { needs }))
            })
            .collect();
        serde_json::json!({"type": "sidebar", "workspaces": workspaces, "subs": subs, "engine_needs": engine_needs})
    }

    /// The state on disk, for `debug state`.
    pub fn debug_disk(&self) -> DebugState {
        let mut inbox = BTreeMap::new();
        let mut errors = BTreeMap::new();
        if let Ok(entries) = std::fs::read_dir(self.dirs.watchd.join("inbox")) {
            for name in entries.filter_map(|entry| entry.ok()?.file_name().into_string().ok()) {
                if let Some(key) = name.strip_suffix(".jsonl").filter(|key| !key.ends_with(".last")) {
                    let text = std::fs::read_to_string(self.dirs.inbox(key)).unwrap_or_default();
                    let events: Vec<RoutedEvent> =
                        text.lines().filter_map(|line| serde_json::from_str(line).ok()).collect();
                    inbox.insert(key.to_string(), events);
                }
                if let Some(key) = name.strip_suffix(".error") {
                    errors.insert(key.to_string(), std::fs::read_to_string(self.dirs.error(key)).unwrap_or_default());
                }
            }
        }
        DebugState {
            subs: self.json_files(&self.dirs.watchd.join("subs"), ".json"),
            inbox,
            errors,
            items: self.json_files(&self.dirs.watchd.join("items"), ".json"),
            engine: self.json_files(&self.dirs.engine, ".json"),
            workspaces: self.json_files(&self.dirs.watchd.join("workspaces"), ".json"),
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

    pub fn forget_workspace(&self, id: &str) {
        remove(&self.dirs.workspace(id));
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
        let store = Store::new(StateDirs { watchd: base.join("watchd"), engine: base.join("watch-gitlab") });
        store.ensure_dirs().unwrap();
        std::fs::write(store.dirs.sub("app"), r#"{"version": 9, "key": "app"}"#).unwrap();

        assert!(store.sub("app").is_none());

        assert!(!store.dirs.sub("app").exists());
        let log = std::fs::read_to_string(store.dirs.log()).unwrap();
        let expected = format!("{}: format 9 not supported, record removed\n", store.dirs.sub("app").display());
        assert!(log.ends_with(&expected), "{log}");
    }

    #[test]
    fn put_back_inbox_puts_the_events_before_the_newer_lines() {
        let base = std::env::temp_dir().join(format!("watchd-store-{}-put-back", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let store = Store::new(StateDirs { watchd: base.join("watchd"), engine: base.join("watch-gitlab") });
        store.ensure_dirs().unwrap();
        let line = |row| format!(r#"{{"kind":"unaddressed","iid":5,"title":"T","url":"u","actor":"anna","detail":"d","branch":"b","row":{row}}}"#);
        std::fs::write(store.dirs.inbox("app"), format!("{}\n{}\n", line(1), line(2))).unwrap();
        let taken = store.take_inbox("app");
        std::fs::write(store.dirs.inbox("app"), format!("{}\n", line(3))).unwrap();

        store.put_back_inbox("app", &taken);

        let rows: Vec<u64> = store.take_inbox("app").iter().map(|event| event.row).collect();
        assert_eq!(rows, [1, 2, 3]);
    }
}
