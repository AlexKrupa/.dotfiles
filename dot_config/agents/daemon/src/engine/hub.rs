use std::collections::BTreeMap;

use serde::Deserialize;

use super::event::{Event, EventKind, short};
use super::stack::{GqlEmoji, Username};
use super::state::{self, HubMrState, HubState, Need, OwnMr, PipelineState};
use super::{CheckContext, EngineError, add_jobs, all_ok, api_json, api_pages, uri_encode};
use crate::glab::{self, Task};
use crate::platform::{now_seconds, utc_date};

#[derive(Clone, Debug, Deserialize)]
pub struct Todo {
    pub id: u64,
    pub action_name: String,
    pub author: Username,
    pub target: TodoTarget,
    pub target_url: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct TodoTarget {
    pub iid: u64,
    pub title: String,
    pub source_branch: String,
    pub author: Option<Username>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RestMr {
    pub iid: u64,
    pub title: String,
    pub state: String,
    pub updated_at: Option<String>,
    pub source_branch: String,
    pub web_url: String,
    pub author: Username,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RestNote {
    pub id: u64,
    pub system: Option<bool>,
    pub body: String,
    pub author: Username,
    pub resolved: Option<bool>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RestPipeline {
    pub id: u64,
    pub status: String,
    pub web_url: String,
}

#[derive(Clone, Debug)]
pub struct NoteReactions {
    pub iid: u64,
    pub id: u64,
    pub emoji: Vec<GqlEmoji>,
}

#[derive(Clone, Debug, Default)]
pub struct HubInput {
    pub me: String,
    pub default_branch: String,
    pub todos: Vec<Todo>,
    pub opened: Vec<RestMr>,
    /// The MRs that the user commented on.
    pub watched: Vec<RestMr>,
    /// Only the MRs with a changed `updated_at` have notes.
    pub notes: Vec<(u64, Vec<RestNote>)>,
    pub reactions: Vec<NoteReactions>,
    /// The newest finished pipeline of the default branch.
    pub default: Option<RestPipeline>,
    /// The open MRs of the user.
    pub own: Vec<RestMr>,
}

struct Reaction {
    key: String,
    name: String,
    user: String,
    url: String,
}

impl RestNote {
    fn is_system(&self) -> bool {
        self.system == Some(true)
    }
}

impl Todo {
    fn on_own_mr(&self, me: &str) -> bool {
        self.target.author.as_ref().is_some_and(|author| author.username == me)
    }
}

#[derive(Deserialize)]
struct CurrentUser {
    id: u64,
    username: String,
}

#[derive(Deserialize)]
struct Project {
    id: u64,
    default_branch: String,
}

#[derive(Deserialize)]
struct UserEvent {
    project_id: Option<u64>,
    note: Option<EventNote>,
}

#[derive(Deserialize)]
struct EventNote {
    id: Option<u64>,
    noteable_type: Option<String>,
    noteable_iid: Option<u64>,
}

impl UserEvent {
    fn mr_note(&self, project: u64) -> Option<(u64, Option<u64>)> {
        let note = self.note.as_ref()?;
        match self.project_id == Some(project) && note.noteable_type.as_deref() == Some("MergeRequest") {
            true => Some((note.noteable_iid?, note.id)),
            false => None,
        }
    }
}

/// The first error in the order of the calls wins, so that the error text does not depend on the
/// timing.
pub async fn check_hub(ctx: &CheckContext) -> Result<Vec<Event>, EngineError> {
    let (user, project) = tokio::join!(
        api_json::<CurrentUser>(ctx.call(&["user"])),
        api_json::<Project>(ctx.call(&[&format!("projects/{}", ctx.project_ref)]))
    );
    let (user, project) = (user?, project?);
    let me = user.username;
    let pid = project.id;
    let old: Option<HubState> = state::load(&ctx.state)?;
    let since = utc_date(now_seconds() - 14 * 86400);
    let (todos, opened, events, default, own) = tokio::join!(
        api_pages::<Todo>(ctx.call(&[&format!(
            "todos?project_id={pid}&type=MergeRequest&state=pending&per_page=100"
        )])),
        // An MR older than the newest 100 is not new.
        api_pages::<RestMr>(ctx.call(&[&format!(
            "projects/{pid}/merge_requests?state=opened&order_by=created_at&sort=desc&per_page=100"
        )])),
        api_pages::<UserEvent>(ctx.call(&[
            &format!("users/{}/events?target_type=note&after={since}&per_page=100", user.id),
            "--paginate",
        ])),
        api_pages::<RestPipeline>(ctx.call(&[&format!(
            "projects/{pid}/pipelines?ref={}&scope=finished&per_page=1",
            uri_encode(&project.default_branch)
        )])),
        api_pages::<RestMr>(ctx.call(&[&format!(
            "projects/{pid}/merge_requests?author_username={}&state=opened&per_page=100",
            uri_encode(&me)
        )])),
    );
    let (todos, opened, events, own) = (todos?, opened?, events?, own?);

    let mut iids: Vec<u64> = events
        .iter()
        .filter_map(|event| event.mr_note(pid))
        .map(|(iid, _)| iid)
        .collect();
    iids.sort_unstable();
    iids.dedup();
    // 100 MRs is the size of one page.
    let pages: Vec<Task<_>> = iids
        .chunks(100)
        .map(|chunk| {
            let filter: Vec<String> = chunk.iter().map(|iid| format!("iids[]={iid}")).collect();
            let call = ctx.call(&[&format!(
                "projects/{pid}/merge_requests?state=all&{}&per_page=100",
                filter.join("&")
            )]);
            Box::pin(api_pages::<RestMr>(call)) as Task<_>
        })
        .collect();
    let watched: Vec<RestMr> = all_ok(glab::parallel(pages).await)?.into_iter().flatten().collect();

    // A new note changes `updated_at`.
    let changed: Vec<u64> = watched
        .iter()
        .filter(|mr| {
            let saved = old.as_ref().and_then(|old| old.mrs.get(&mr.iid.to_string()));
            saved.and_then(|saved| saved.updated_at.as_ref()) != mr.updated_at.as_ref() || saved.is_none()
        })
        .map(|mr| mr.iid)
        .collect();
    let notes_calls: Vec<Task<_>> = changed
        .iter()
        .map(|iid| {
            let call = ctx.call(&[&format!(
                "projects/{pid}/merge_requests/{iid}/notes?sort=desc&order_by=created_at&per_page=50"
            )]);
            Box::pin(api_pages::<RestNote>(call)) as Task<_>
        })
        .collect();
    // GraphQL gives no reactions to a fine-grained token, thus each comment of the user gets one
    // REST call.
    let others: Vec<u64> = watched
        .iter()
        .filter(|mr| mr.author.username != me)
        .map(|mr| mr.iid)
        .collect();
    let own_notes: Vec<(u64, u64)> = events
        .iter()
        .filter_map(|event| event.mr_note(pid))
        .filter(|(iid, _)| others.contains(iid))
        .filter_map(|(iid, id)| Some((iid, id?)))
        .collect();
    let emoji_calls: Vec<Task<_>> = own_notes
        .iter()
        .map(|(iid, id)| {
            let call = ctx.call(&[&format!(
                "projects/{pid}/merge_requests/{iid}/notes/{id}/award_emoji?per_page=100"
            )]);
            Box::pin(api_pages::<GqlEmoji>(call)) as Task<_>
        })
        .collect();
    let (notes, emoji) = tokio::join!(glab::parallel(notes_calls), glab::parallel(emoji_calls));
    let notes = changed.into_iter().zip(all_ok(notes)?).collect();
    let reactions = own_notes
        .into_iter()
        .zip(all_ok(emoji)?)
        .map(|((iid, id), emoji)| NoteReactions { iid, id, emoji })
        .collect();
    let input = HubInput {
        me,
        default_branch: project.default_branch,
        todos,
        opened,
        watched,
        notes,
        reactions,
        default: default?.into_iter().next(),
        own,
    };
    let (new_state, events) = hub_compare(&input, old.as_ref(), &ctx.args.skip_mrs);
    let events = add_jobs(ctx, &pid.to_string(), events).await?;
    state::save(&ctx.state, &new_state)?;
    Ok(events)
}

pub fn hub_compare(input: &HubInput, old: Option<&HubState>, reviewed: &[u64]) -> (HubState, Vec<Event>) {
    let me = input.me.as_str();
    let mut by: Vec<&RestMr> = Vec::new();
    for mr in input.watched.iter().filter(|mr| mr.author.username != me) {
        match by.iter_mut().find(|known| known.iid == mr.iid) {
            Some(known) => *known = mr,
            None => by.push(mr),
        }
    }
    let notes_by: BTreeMap<u64, &[RestNote]> = input
        .notes
        .iter()
        .map(|(iid, notes)| (*iid, notes.as_slice()))
        .collect();
    let mut reactions_by: BTreeMap<u64, Vec<Reaction>> = BTreeMap::new();
    for note in &input.reactions {
        let url = by.iter().find(|mr| mr.iid == note.iid).map_or("null", |mr| &mr.web_url);
        for emoji in note.emoji.iter().filter(|emoji| emoji.user.username != me) {
            reactions_by.entry(note.iid).or_default().push(Reaction {
                key: format!("{}:{}:{}", note.id, emoji.name, emoji.user.username),
                name: emoji.name.clone(),
                user: emoji.user.username.clone(),
                url: format!("{url}#note_{}", note.id),
            });
        }
    }
    let opened: Vec<&RestMr> = input.opened.iter().filter(|mr| mr.author.username != me).collect();
    let new_pipeline = input.default.as_ref().map(|pipeline| PipelineState {
        id: pipeline.id,
        status: pipeline.status.clone(),
    });
    let saved_pipeline = old.and_then(|old| old.default_pipeline.clone()).flatten();
    let default_pipeline = match saved_pipeline {
        Some(saved) if saved.id > new_pipeline.as_ref().map_or(0, |new| new.id) => Some(saved),
        _ => new_pipeline,
    };
    let default_failed = default_pipeline
        .as_ref()
        .is_some_and(|pipeline| pipeline.status == "failed");

    let mut mrs = BTreeMap::new();
    for mr in &by {
        let old_mr = old.and_then(|old| old.mrs.get(&mr.iid.to_string()));
        let fetched = notes_by.get(&mr.iid).copied().unwrap_or_default();
        let fallback = HubMrState::default();
        let saved = old_mr.unwrap_or(&fallback);
        let own = fetched
            .iter()
            .filter(|note| note.author.username == me)
            .map(|note| note.id)
            .chain([saved.last_own_note_id])
            .max()
            .unwrap_or_default();
        let new_notes = fetched.iter().filter(|note| {
            old_mr.is_some() && note.id > saved.last_note_id && !note.is_system() && note.author.username != me
        });
        let mut open_notes: Vec<u64> = saved
            .open_notes
            .iter()
            .copied()
            .chain(new_notes.map(|note| note.id))
            .collect();
        open_notes.sort_unstable();
        open_notes.dedup();
        open_notes.retain(|id| *id > own && !fetched.iter().any(|note| note.id == *id && note.resolved == Some(true)));
        let state = HubMrState {
            updated_at: mr.updated_at.clone(),
            last_note_id: fetched
                .iter()
                .map(|note| note.id)
                .chain([saved.last_note_id])
                .max()
                .unwrap_or_default(),
            last_own_note_id: own,
            open_notes,
            reactions: Some(
                reactions_by
                    .get(&mr.iid)
                    .into_iter()
                    .flatten()
                    .map(|r| r.key.clone())
                    .collect(),
            ),
        };
        mrs.insert(mr.iid.to_string(), state);
    }

    let others_todos: Vec<&Todo> = input.todos.iter().filter(|todo| !todo.on_own_mr(me)).collect();
    let mut needs = Vec::new();
    if !others_todos.is_empty() {
        needs.push(Need::Todo);
    }
    if default_failed {
        needs.push(Need::MainFailed);
    }
    let mut present: Vec<String> = others_todos.iter().map(|todo| format!("todo:{}", todo.id)).collect();
    for mr in by.iter().filter(|mr| mr.state == "opened") {
        let open_notes = &mrs[&mr.iid.to_string()].open_notes;
        present.extend(open_notes.iter().map(|id| format!("note:{id}")));
    }
    if default_failed {
        present.push(format!("main-failed:{}", input.default_branch));
    }
    let state = HubState {
        todos: input.todos.iter().map(|todo| todo.id).collect(),
        opened: Some(opened.iter().map(|mr| mr.iid).collect()),
        mrs,
        default_pipeline: Some(default_pipeline),
        needs,
        present,
        own_mrs: input.own.iter().map(|mr| OwnMr { iid: mr.iid }).collect(),
    };
    let events = match old {
        Some(old) => hub_events(input, old, &by, &notes_by, &reactions_by, &opened)
            .into_iter()
            .filter(|event| match event.kind {
                EventKind::Opened | EventKind::DefaultFailed => true,
                EventKind::Todo if event.detail == "review_requested" => true,
                _ => !event.iid.is_some_and(|iid| reviewed.contains(&iid)),
            })
            .collect(),
        None => Vec::new(),
    };
    (state, events)
}

fn hub_events(
    input: &HubInput,
    old: &HubState,
    by: &[&RestMr],
    notes_by: &BTreeMap<u64, &[RestNote]>,
    reactions_by: &BTreeMap<u64, Vec<Reaction>>,
    opened: &[&RestMr],
) -> Vec<Event> {
    let me = input.me.as_str();
    let mut events = Vec::new();
    for todo in &input.todos {
        if old.todos.contains(&todo.id) || todo.on_own_mr(me) {
            continue;
        }
        events.push(Event {
            item: Some(format!("todo:{}", todo.id)),
            author: todo.target.author.as_ref().map(|author| author.username.clone()),
            ..Event::new(
                EventKind::Todo,
                Some(todo.target.iid),
                Some(&todo.target.title),
                &todo.target_url,
                &todo.author.username,
                &todo.action_name,
                &todo.target.source_branch,
            )
        });
    }
    if let Some(old_opened) = &old.opened {
        for mr in opened.iter().filter(|mr| !old_opened.contains(&mr.iid)) {
            events.push(Event {
                author: Some(mr.author.username.clone()),
                ..Event::new(
                    EventKind::Opened,
                    Some(mr.iid),
                    Some(&mr.title),
                    &mr.web_url,
                    &mr.author.username,
                    "opened",
                    &mr.source_branch,
                )
            });
        }
    }
    if let (Some(old_pipeline), Some(pipeline)) = (&old.default_pipeline, &input.default) {
        let saved_id = old_pipeline.as_ref().map_or(0, |saved| saved.id);
        if pipeline.id > saved_id && pipeline.status == "failed" {
            events.push(Event {
                previous: Some(old_pipeline.as_ref().map(|saved| saved.status.clone())),
                item: Some(format!("main-failed:{}", input.default_branch)),
                ..Event::new(
                    EventKind::DefaultFailed,
                    None,
                    None,
                    &pipeline.web_url,
                    "",
                    &format!("pipeline {} failed", pipeline.id),
                    &input.default_branch,
                )
            });
        }
    }
    for mr in by {
        let Some(old_mr) = old.mrs.get(&mr.iid.to_string()) else {
            continue;
        };
        let fetched = notes_by.get(&mr.iid).copied().unwrap_or_default();
        for note in fetched {
            if note.id > old_mr.last_note_id && !note.is_system() && note.author.username != me {
                events.push(Event {
                    item: Some(format!("note:{}", note.id)),
                    ..Event::new(
                        EventKind::Note,
                        Some(mr.iid),
                        Some(&mr.title),
                        &format!("{}#note_{}", mr.web_url, note.id),
                        &note.author.username,
                        &short(&note.body),
                        &mr.source_branch,
                    )
                });
            }
        }
    }
    for mr in by {
        let Some(old_reactions) = old.mrs.get(&mr.iid.to_string()).and_then(|o| o.reactions.as_ref()) else {
            continue;
        };
        for reaction in reactions_by.get(&mr.iid).into_iter().flatten() {
            if old_reactions.contains(&reaction.key) {
                continue;
            }
            events.push(Event::new(
                EventKind::Reaction,
                Some(mr.iid),
                Some(&mr.title),
                &reaction.url,
                &reaction.user,
                &format!(":{}: on your comment", reaction.name),
                &mr.source_branch,
            ));
        }
    }
    events
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const URL: &str = "https://gitlab.example.com/group/sub/app/-/merge_requests";

    fn todo(id: u64, action: &str, iid: u64) -> serde_json::Value {
        json!({"id": id, "action_name": action, "author": {"username": "anna"},
               "target": {"iid": iid, "title": "Add foo", "source_branch": "ABC-1/foo",
                          "author": {"username": "bob"}},
               "target_url": format!("{URL}/{iid}")})
    }

    fn input(todos: serde_json::Value) -> HubInput {
        HubInput {
            me: "me".to_string(),
            default_branch: "main".to_string(),
            todos: serde_json::from_value(todos).unwrap(),
            ..HubInput::default()
        }
    }

    fn lines(events: &[Event]) -> Vec<String> {
        events
            .iter()
            .map(|event| serde_json::to_string(event).unwrap())
            .collect()
    }

    #[test]
    fn hub_first_check_saves_state_and_gives_no_events() {
        let (state, events) = hub_compare(&input(json!([todo(11, "mentioned", 5)])), None, &[]);
        assert!(events.is_empty());
        assert_eq!(state.todos, vec![11]);
        assert_eq!(state.present, vec!["todo:11"]);
    }

    #[test]
    fn hub_new_todo_gives_todo_event_with_item() {
        let old = HubState::default();
        let (_, events) = hub_compare(&input(json!([todo(11, "review_requested", 5)])), Some(&old), &[]);
        assert_eq!(
            lines(&events),
            vec![format!(
                r#"{{"kind":"todo","iid":5,"title":"Add foo","url":"{URL}/5","actor":"anna","detail":"review_requested","branch":"ABC-1/foo","item":"todo:11","author":"bob"}}"#
            )]
        );
    }

    #[test]
    fn hub_skip_mr_keeps_only_review_requested_todo_and_opened() {
        let old: HubState = serde_json::from_value(json!({"todos": [], "opened": [],
            "mrs": {"9": {"updated_at": "t1", "last_note_id": 300, "last_own_note_id": 0,
                          "open_notes": [], "reactions": []}}}))
        .unwrap();
        let mut input = input(json!([todo(21, "mentioned", 9), todo(22, "review_requested", 9)]));
        let mr = json!({"iid": 9, "title": "Fix bar", "state": "opened", "updated_at": "t2",
                        "source_branch": "ABC-2/bar", "web_url": format!("{URL}/9"),
                        "author": {"username": "bob"}});
        input.watched = serde_json::from_value(json!([mr])).unwrap();
        input.opened = serde_json::from_value(json!([
            {"iid": 30, "title": "Bump", "state": "opened", "updated_at": "t1",
             "source_branch": "renovate/x", "web_url": format!("{URL}/30"),
             "author": {"username": "renovate-bot"}}]))
        .unwrap();
        input.notes = vec![(
            9,
            serde_json::from_value(json!([
            {"id": 301, "system": false, "body": "Odd", "author": {"username": "anna"}}]))
            .unwrap(),
        )];
        let (_, events) = hub_compare(&input, Some(&old), &[9]);
        let kinds: Vec<_> = events
            .iter()
            .map(|event| (event.kind, event.item.clone(), event.author.clone()))
            .collect();
        assert_eq!(
            kinds,
            vec![
                (EventKind::Todo, Some("todo:22".to_string()), Some("bob".to_string())),
                (EventKind::Opened, None, Some("renovate-bot".to_string()))
            ]
        );
    }

    #[test]
    fn hub_default_pipeline_below_saved_id_gives_no_event() {
        let old: HubState =
            serde_json::from_value(json!({"todos": [], "default_pipeline": {"id": 72, "status": "success"}})).unwrap();
        let mut input = input(json!([]));
        input.default =
            serde_json::from_value(json!({"id": 69, "status": "failed", "web_url": "https://p/69"})).unwrap();
        let (state, events) = hub_compare(&input, Some(&old), &[]);
        assert!(events.is_empty());
        assert_eq!(
            serde_json::to_string(&state.default_pipeline).unwrap(),
            r#"{"id":72,"status":"success"}"#
        );
    }
}
