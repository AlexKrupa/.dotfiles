use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::event::{Event, EventKind, short};
use super::state::{self, MrState, MrsState, Need, PipelineState};
use super::{CheckContext, EngineError, add_jobs, all_ok, api_json, api_pages};
use crate::glab::{self, Task, permission_for};

const MR_QUERY: &str = "query($path: ID!, $iid: String!) {
  currentUser { username }
  project(fullPath: $path) { mergeRequest(iid: $iid) {
    iid title webUrl sourceBranch state draft
    mergeUser { username }
    headPipeline { id status }
    approvedBy { nodes { username } }
    detailedMergeStatus conflicts mergeable
  } }
}";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Username {
    pub username: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Nodes<T> {
    pub nodes: Vec<T>,
}

/// Also the format of an MR cache file. With a fine-grained token, GraphQL gives no discussions,
/// diff refs, or reactions, and no error, thus they come from REST.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MrData {
    pub current_user: Username,
    pub project: MrProject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MrProject {
    pub merge_request: GqlMr,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GqlMr {
    #[serde(flatten)]
    pub base: GqlMrBase,
    pub description: String,
    pub labels: Vec<String>,
    pub diff_refs: Option<DiffRefs>,
    pub award_emoji: Nodes<GqlEmoji>,
    pub discussions: Nodes<GqlDiscussion>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GqlMrBase {
    pub iid: String,
    pub title: String,
    pub web_url: String,
    pub source_branch: String,
    pub state: String,
    pub draft: bool,
    pub merge_user: Option<Username>,
    pub head_pipeline: Option<GqlPipeline>,
    pub approved_by: Nodes<Username>,
    pub detailed_merge_status: Option<String>,
    pub conflicts: Option<bool>,
    pub mergeable: Option<bool>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GqlPipeline {
    pub id: String,
    pub status: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffRefs {
    pub base_sha: Option<String>,
    pub head_sha: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GqlEmoji {
    pub name: String,
    pub user: Username,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GqlDiscussion {
    pub id: String,
    pub resolvable: bool,
    pub resolved: bool,
    pub resolved_by: Option<OptionalUser>,
    pub notes: Nodes<GqlNote>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OptionalUser {
    pub username: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GqlNote {
    pub id: String,
    pub body: String,
    pub system: bool,
    pub url: String,
    pub author: Username,
    pub position: Option<Position>,
    pub award_emoji: Nodes<GqlEmoji>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Position {
    pub new_path: Option<String>,
    pub new_line: Option<u64>,
}

#[derive(Deserialize)]
struct GqlResponse {
    data: Option<GqlResponseData>,
    errors: Option<serde_json::Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GqlResponseData {
    current_user: Option<Username>,
    project: Option<GqlResponseProject>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GqlResponseProject {
    merge_request: Option<GqlMrBase>,
}

#[derive(Deserialize)]
struct RestMr {
    description: Option<String>,
    labels: Option<Vec<String>>,
    diff_refs: Option<RestDiffRefs>,
    user_notes_count: Option<u64>,
}

#[derive(Deserialize)]
struct RestDiffRefs {
    base_sha: Option<String>,
    head_sha: Option<String>,
}

#[derive(Deserialize)]
struct RestDiscussion {
    id: String,
    notes: Vec<RestNote>,
}

#[derive(Deserialize)]
struct RestNote {
    id: u64,
    body: String,
    system: Option<bool>,
    author: Username,
    position: Option<RestPosition>,
    resolvable: Option<bool>,
    resolved: Option<bool>,
    resolved_by: Option<OptionalUser>,
}

#[derive(Deserialize)]
struct RestPosition {
    new_path: Option<String>,
    new_line: Option<u64>,
}

pub async fn fetch_mr(ctx: &CheckContext, iid: u64) -> Result<MrData, EngineError> {
    let name = format!("{}-{iid}.json", ctx.project_ref);
    let _fetch = match &ctx.cache {
        Some(cache) => Some(cache.lock(&name).await),
        None => None,
    };
    let cached = ctx.cache.as_ref().map(|cache| cache.dir.join(&name));
    if let Some(file) = &cached
        && let Ok(text) = std::fs::read_to_string(file)
    {
        return serde_json::from_str(&text).map_err(|error| EngineError::Other(format!("{}: {error}", file.display())));
    }
    let mr_path = format!("projects/{}/merge_requests/{iid}", ctx.project_ref);
    let query = format!("query={MR_QUERY}");
    let path = format!("path={}", ctx.project);
    let iid_field = format!("iid={iid}");
    let graphql_args = ["api", "graphql", "-f", &query, "-f", &path, "-f", &iid_field];
    let (graphql, rest, discussions, mr_emoji) = tokio::join!(
        glab::run(&ctx.repo, &graphql_args),
        api_json::<RestMr>(ctx.call(&[&mr_path])),
        api_pages::<RestDiscussion>(ctx.call(&[&format!("{mr_path}/discussions?per_page=100"), "--paginate"])),
        api_pages::<GqlEmoji>(ctx.call(&[&format!("{mr_path}/award_emoji?per_page=100")])),
    );
    let (me, base) = graphql_mr(graphql, ctx, iid)?;
    let (rest, discussions) = (rest?, discussions?);
    let count = rest.user_notes_count.unwrap_or(0);
    let all_system = discussions
        .iter()
        .flat_map(|d| &d.notes)
        .all(|note| note.system == Some(true));
    if count > 0 && all_system {
        return Err(EngineError::Permanent(format!(
            "MR !{iid} has {count} comment(s), but {mr_path}/discussions?per_page=100 gave none. \
             The token needs the Read permission for {}.",
            permission_for(&format!("{mr_path}/discussions"))
        )));
    }
    let mr_emoji = mr_emoji?;
    let comment_ids: Vec<u64> = discussions
        .iter()
        .flat_map(|discussion| &discussion.notes)
        .filter(|note| note.system != Some(true))
        .map(|note| note.id)
        .collect();
    let calls: Vec<Task<_>> = comment_ids
        .iter()
        .map(|id| {
            let call = ctx.call(&[&format!("{mr_path}/notes/{id}/award_emoji?per_page=100")]);
            Box::pin(api_pages::<GqlEmoji>(call)) as Task<_>
        })
        .collect();
    let emoji_by_note: BTreeMap<u64, Vec<GqlEmoji>> = comment_ids
        .into_iter()
        .zip(all_ok(glab::parallel(calls).await)?)
        .collect();
    let url = base.web_url.clone();
    let data = MrData {
        current_user: Username { username: me },
        project: MrProject {
            merge_request: GqlMr {
                base,
                description: rest.description.unwrap_or_default(),
                labels: rest.labels.unwrap_or_default(),
                diff_refs: rest.diff_refs.map(|refs| DiffRefs {
                    base_sha: refs.base_sha,
                    head_sha: refs.head_sha,
                }),
                award_emoji: Nodes { nodes: mr_emoji },
                discussions: Nodes {
                    nodes: discussions
                        .into_iter()
                        .map(|discussion| gql_discussion(discussion, &url, &emoji_by_note))
                        .collect(),
                },
            },
        },
    };
    if let Some(file) = &cached {
        let mut text = serde_json::to_string(&data).expect("an MR serializes");
        text.push('\n');
        std::fs::write(file, text).map_err(|error| EngineError::Other(format!("{}: {error}", file.display())))?;
    }
    Ok(data)
}

/// On a GraphQL error, `glab` exits 1 with the body on stdout, and a new try gives the same error.
fn graphql_mr(
    output: std::io::Result<std::process::Output>,
    ctx: &CheckContext,
    iid: u64,
) -> Result<(String, GqlMrBase), EngineError> {
    let output = output.map_err(|error| EngineError::Other(format!("graphql: {error}")))?;
    let responses: Vec<GqlResponse> = serde_json::Deserializer::from_slice(&output.stdout)
        .into_iter::<GqlResponse>()
        .collect::<Result<_, _>>()
        .unwrap_or_default();
    let truthy = |value: &serde_json::Value| !matches!(value, serde_json::Value::Null | serde_json::Value::Bool(false));
    let errors: Vec<&serde_json::Value> = responses
        .iter()
        .filter_map(|response| response.errors.as_ref())
        .filter(|e| truthy(e))
        .collect();
    if !errors.is_empty() {
        let messages: Vec<&str> = errors
            .iter()
            .filter_map(|errors| errors.as_array())
            .flatten()
            .filter_map(|error| error["message"].as_str())
            .collect();
        return Err(EngineError::Permanent(format!("graphql: {}", messages.join("; "))));
    }
    if !output.status.success() {
        return Err(glab::classify("graphql", &output.stderr).into());
    }
    let data = responses.into_iter().next().and_then(|response| response.data);
    let me = data
        .as_ref()
        .and_then(|data| data.current_user.as_ref())
        .map(|user| user.username.clone());
    let mr = data
        .and_then(|data| data.project)
        .and_then(|project| project.merge_request);
    match mr {
        Some(mr) => Ok((me.unwrap_or_default(), mr)),
        None => Err(EngineError::Permanent(format!(
            "MR !{iid} not found in {}",
            ctx.project
        ))),
    }
}

fn gql_discussion(
    discussion: RestDiscussion,
    url: &str,
    emoji_by_note: &BTreeMap<u64, Vec<GqlEmoji>>,
) -> GqlDiscussion {
    let resolvable: Vec<&RestNote> = discussion
        .notes
        .iter()
        .filter(|note| note.resolvable == Some(true))
        .collect();
    let resolved = !resolvable.is_empty() && resolvable.iter().all(|note| note.resolved == Some(true));
    let resolved_by = resolvable.first().and_then(|note| note.resolved_by.clone());
    GqlDiscussion {
        id: discussion.id,
        resolvable: !resolvable.is_empty(),
        resolved,
        resolved_by,
        notes: Nodes {
            nodes: discussion
                .notes
                .iter()
                .map(|note| GqlNote {
                    id: note.id.to_string(),
                    body: note.body.clone(),
                    system: note.system == Some(true),
                    url: format!("{url}#note_{}", note.id),
                    author: note.author.clone(),
                    position: note.position.as_ref().map(|position| Position {
                        new_path: position.new_path.clone(),
                        new_line: position.new_line,
                    }),
                    award_emoji: Nodes {
                        nodes: emoji_by_note.get(&note.id).into_iter().flatten().cloned().collect(),
                    },
                })
                .collect(),
        },
    }
}

#[derive(Clone, Debug)]
pub struct NormNote {
    pub id: u64,
    pub body: String,
    pub url: String,
    pub author: String,
    pub position: Option<Position>,
    pub discussion: String,
}

#[derive(Clone, Debug)]
pub struct NormReaction {
    pub key: String,
    pub name: String,
    pub user: String,
    /// The author of the comment, or `None` for a reaction on the MR.
    pub on: Option<String>,
    pub url: Option<String>,
    pub position: Option<Position>,
}

#[derive(Clone, Debug)]
pub struct ResolvedThread {
    pub id: String,
    pub by: String,
    pub first: NormNote,
}

#[derive(Clone, Debug)]
pub struct Unaddressed {
    pub last: NormNote,
    pub position: Option<Position>,
    pub discussion: String,
}

#[derive(Clone, Debug)]
pub struct NormMr {
    pub iid: u64,
    pub title: String,
    pub url: String,
    pub branch: String,
    pub state: String,
    pub merge_user: String,
    pub draft: bool,
    pub draft_user: String,
    pub close_user: String,
    pub description: String,
    pub labels: Vec<String>,
    pub title_user: String,
    pub description_user: String,
    pub labels_user: String,
    pub base: Option<String>,
    pub head: Option<String>,
    pub resolved_mine: Vec<ResolvedThread>,
    pub pipeline: Option<PipelineState>,
    pub approved_by: Vec<String>,
    pub merge_status: String,
    pub conflicts: Option<bool>,
    pub mergeable: Option<bool>,
    pub notes: Vec<NormNote>,
    pub reactions: Vec<NormReaction>,
    pub open_threads: usize,
    pub unaddressed: Vec<Unaddressed>,
}

fn num(id: &str) -> u64 {
    id.rsplit('/').next().unwrap_or(id).parse().unwrap_or(0)
}

fn at_end(rest: &str) -> bool {
    rest.is_empty() || rest == "\n"
}

pub fn is_labels_note(body: &str) -> bool {
    let Some(rest) = body.strip_prefix("added ~").or_else(|| body.strip_prefix("removed ~")) else {
        return false;
    };
    let line = rest.split('\n').next().unwrap_or_default();
    line.match_indices(" label").any(|(index, _)| {
        let after = &rest[index + " label".len()..];
        let after = after.strip_prefix('s').unwrap_or(after);
        at_end(after) || after.starts_with(' ')
    })
}

enum Action {
    Draft,
    Close,
    Title,
    Description,
    Labels,
}

impl Action {
    fn matches(&self, body: &str) -> bool {
        match self {
            Action::Draft => {
                body.starts_with("marked this merge request as **draft**")
                    || body.starts_with("marked this merge request as **ready**")
            }
            Action::Close => body == "closed" || body == "closed\n",
            Action::Title => body.starts_with("changed title "),
            Action::Description => body.starts_with("changed the description"),
            Action::Labels => is_labels_note(body),
        }
    }
}

fn actor(mr: &GqlMr, action: Action) -> String {
    mr.discussions
        .nodes
        .iter()
        .flat_map(|discussion| &discussion.notes.nodes)
        .filter(|note| note.system && action.matches(&note.body))
        .max_by_key(|note| num(&note.id))
        .map(|note| note.author.username.clone())
        .unwrap_or_default()
}

pub fn normalize(data: &MrData, me: &str, review: bool) -> NormMr {
    let mr = &data.project.merge_request;
    let discussions: Vec<(&GqlDiscussion, Vec<NormNote>)> = mr
        .discussions
        .nodes
        .iter()
        .map(|discussion| {
            let notes = discussion
                .notes
                .nodes
                .iter()
                .filter(|note| !note.system)
                .map(|note| NormNote {
                    id: num(&note.id),
                    body: note.body.clone(),
                    url: note.url.clone(),
                    author: note.author.username.clone(),
                    position: note.position.clone(),
                    discussion: discussion.id.clone(),
                })
                .collect();
            (discussion, notes)
        })
        .collect();
    let open = |discussion: &GqlDiscussion| discussion.resolvable && !discussion.resolved;
    let mut labels = mr.labels.clone();
    labels.sort();
    let mut reactions: Vec<NormReaction> = mr
        .award_emoji
        .nodes
        .iter()
        .map(|emoji| NormReaction {
            key: format!("mr:{}:{}", emoji.name, emoji.user.username),
            name: emoji.name.clone(),
            user: emoji.user.username.clone(),
            on: None,
            url: None,
            position: None,
        })
        .collect();
    for discussion in &mr.discussions.nodes {
        for note in discussion.notes.nodes.iter().filter(|note| !note.system) {
            reactions.extend(note.award_emoji.nodes.iter().map(|emoji| NormReaction {
                key: format!("{}:{}:{}", num(&note.id), emoji.name, emoji.user.username),
                name: emoji.name.clone(),
                user: emoji.user.username.clone(),
                on: Some(note.author.username.clone()),
                url: Some(note.url.clone()),
                position: note.position.clone(),
            }));
        }
    }
    NormMr {
        iid: mr.base.iid.parse().unwrap_or(0),
        title: mr.base.title.clone(),
        url: mr.base.web_url.clone(),
        branch: mr.base.source_branch.clone(),
        state: mr.base.state.clone(),
        merge_user: mr
            .base
            .merge_user
            .as_ref()
            .map(|user| user.username.clone())
            .unwrap_or_default(),
        draft: mr.base.draft,
        draft_user: actor(mr, Action::Draft),
        close_user: actor(mr, Action::Close),
        description: mr.description.clone(),
        labels,
        title_user: actor(mr, Action::Title),
        description_user: actor(mr, Action::Description),
        labels_user: actor(mr, Action::Labels),
        base: mr.diff_refs.as_ref().and_then(|refs| refs.base_sha.clone()),
        head: mr.diff_refs.as_ref().and_then(|refs| refs.head_sha.clone()),
        resolved_mine: discussions
            .iter()
            .filter(|(discussion, _)| discussion.resolvable && discussion.resolved)
            .filter_map(|(discussion, notes)| {
                let first = notes.first().filter(|first| first.author == me)?;
                Some(ResolvedThread {
                    id: discussion.id.clone(),
                    by: discussion
                        .resolved_by
                        .as_ref()
                        .and_then(|user| user.username.clone())
                        .unwrap_or_default(),
                    first: first.clone(),
                })
            })
            .collect(),
        pipeline: mr.base.head_pipeline.as_ref().map(|pipeline| PipelineState {
            id: num(&pipeline.id),
            status: pipeline.status.to_lowercase(),
        }),
        approved_by: mr
            .base
            .approved_by
            .nodes
            .iter()
            .map(|user| user.username.clone())
            .collect(),
        merge_status: mr.base.detailed_merge_status.clone().unwrap_or_default().to_lowercase(),
        conflicts: mr.base.conflicts,
        mergeable: mr.base.mergeable,
        notes: discussions.iter().flat_map(|(_, notes)| notes.clone()).collect(),
        reactions,
        open_threads: discussions.iter().filter(|(discussion, _)| open(discussion)).count(),
        unaddressed: discussions
            .iter()
            .filter(|(discussion, _)| open(discussion))
            .filter_map(|(discussion, notes)| {
                let last = notes.last().filter(|last| last.author != me)?;
                match !review || notes.iter().any(|note| note.author == me) {
                    true => Some(Unaddressed {
                        last: last.clone(),
                        position: notes[0].position.clone(),
                        discussion: discussion.id.clone(),
                    }),
                    false => None,
                }
            })
            .collect(),
    }
}

/// GitLab computes the merge status async, thus a transient status keeps the last stable values.
fn transient(status: &str) -> bool {
    matches!(status, "checking" | "unchecked" | "preparing" | "approvals_syncing")
}

fn at(event: Event, position: &Option<Position>) -> Event {
    match position.as_ref().and_then(|position| position.new_path.clone()) {
        Some(path) => Event {
            path: Some(path),
            line: Some(position.as_ref().and_then(|position| position.new_line)),
            ..event
        },
        None => event,
    }
}

fn event(kind: EventKind, mr: &NormMr, actor: &str, detail: &str, url: Option<&str>) -> Event {
    Event::new(
        kind,
        Some(mr.iid),
        Some(&mr.title),
        url.unwrap_or(&mr.url),
        actor,
        detail,
        &mr.branch,
    )
}

fn with_item(event: Event, item: String) -> Event {
    Event {
        item: Some(item),
        ..event
    }
}

fn minus(left: &[String], right: &[String]) -> Vec<String> {
    left.iter().filter(|value| !right.contains(value)).cloned().collect()
}

fn new_state(mr: &NormMr, old: &MrState, me: &str) -> MrState {
    let transient = transient(&mr.merge_status);
    let old_approved = old.approved_by.clone().unwrap_or_default();
    let seen = old.seen_head.is_none()
        || mr
            .notes
            .iter()
            .any(|note| note.id > old.last_note_id && note.author == me)
        || (mr.approved_by.iter().any(|user| user == me) && !old_approved.iter().any(|user| user == me));
    MrState {
        state: Some(mr.state.clone()),
        draft: Some(mr.draft),
        pipeline: mr.pipeline.clone(),
        approved_by: Some(mr.approved_by.clone()),
        title: Some(mr.title.clone()),
        description: Some(mr.description.clone()),
        labels: Some(mr.labels.clone()),
        conflicts: if transient { old.conflicts } else { mr.conflicts },
        mergeable: if transient { old.mergeable } else { mr.mergeable },
        merge_status: if transient {
            old.merge_status.clone()
        } else {
            Some(mr.merge_status.clone())
        },
        seen_head: if seen { mr.head.clone() } else { old.seen_head.clone() },
        last_note_id: mr
            .notes
            .iter()
            .map(|note| note.id)
            .chain([old.last_note_id])
            .max()
            .unwrap_or(0),
        reactions: Some(mr.reactions.iter().map(|reaction| reaction.key.clone()).collect()),
        base: mr.base.clone(),
        head: mr.head.clone(),
        resolved: Some(mr.resolved_mine.iter().map(|thread| thread.id.clone()).collect()),
    }
}

fn mr_events(mr: &NormMr, old: &MrState, new: &MrState, me: &str, review: bool) -> Vec<Event> {
    let mut events = Vec::new();
    for note in mr.notes.iter().filter(|note| note.id > old.last_note_id) {
        let kind = if note.author == me {
            EventKind::OwnComment
        } else {
            EventKind::Comment
        };
        let comment = at(
            event(kind, mr, &note.author, &short(&note.body), Some(&note.url)),
            &note.position,
        );
        let unaddressed = mr.unaddressed.iter().any(|thread| thread.discussion == note.discussion);
        events.push(match unaddressed {
            true => with_item(comment, format!("thread:{}", note.discussion)),
            false => comment,
        });
    }
    for reaction in mr.reactions.iter().filter(|reaction| reaction.user != me) {
        if old.reactions.as_ref().is_some_and(|keys| keys.contains(&reaction.key)) {
            continue;
        }
        let on = match &reaction.on {
            None => "the MR".to_string(),
            Some(author) if author == me => "your comment".to_string(),
            Some(author) => format!("a comment of @{author}"),
        };
        let detail = format!(":{}: on {on}", reaction.name);
        let reacted = event(
            EventKind::Reaction,
            mr,
            &reaction.user,
            &detail,
            reaction.url.as_deref(),
        );
        events.push(at(reacted, &reaction.position));
    }
    if let Some(pipeline) = &new.pipeline
        && new.pipeline != old.pipeline
    {
        let detail = |result: &str| format!("pipeline {} {result}", pipeline.id);
        match pipeline.status.as_str() {
            "failed" => events.push(with_item(
                event(EventKind::Pipeline, mr, "", &detail("failed"), None),
                format!("pipeline:{}", mr.iid),
            )),
            "success" => events.push(event(EventKind::Pipeline, mr, "", &detail("passed"), None)),
            _ => {}
        }
    }
    let now_approved = new.approved_by.clone().unwrap_or_default();
    let old_approved = old.approved_by.clone().unwrap_or_default();
    for user in minus(&now_approved, &old_approved).iter().filter(|user| *user != me) {
        events.push(event(EventKind::Approved, mr, user, "approved", None));
    }
    for user in minus(&old_approved, &now_approved).iter().filter(|user| *user != me) {
        events.push(event(EventKind::Unapproved, mr, user, "approval removed", None));
    }
    if old.draft.is_some() && new.draft != old.draft && mr.draft_user != me {
        events.push(match mr.draft {
            true => event(EventKind::Draft, mr, &mr.draft_user, "marked as draft", None),
            false => event(EventKind::Ready, mr, &mr.draft_user, "marked as ready", None),
        });
    }
    if old.title.is_some() && new.title != old.title && mr.title_user != me {
        events.push(event(EventKind::Title, mr, &mr.title_user, &short(&mr.title), None));
    }
    if old.description.is_some() && new.description != old.description && mr.description_user != me {
        events.push(event(
            EventKind::Description,
            mr,
            &mr.description_user,
            "description changed",
            None,
        ));
    }
    if let Some(old_labels) = &old.labels
        && new.labels.as_ref() != Some(old_labels)
        && mr.labels_user != me
    {
        let added = minus(&mr.labels, old_labels)
            .into_iter()
            .map(|label| format!("+{label}"));
        let removed = minus(old_labels, &mr.labels)
            .into_iter()
            .map(|label| format!("-{label}"));
        let detail = added.chain(removed).collect::<Vec<_>>().join(", ");
        events.push(event(EventKind::Labels, mr, &mr.labels_user, &detail, None));
    }
    if new.conflicts == Some(true) && old.conflicts != Some(true) {
        let conflict = event(EventKind::Conflict, mr, "", "merge conflict", None);
        events.push(with_item(conflict, format!("conflict:{}", mr.iid)));
    }
    if new.mergeable == Some(true) && old.mergeable != Some(true) {
        let detail = format!("now mergeable, {} open thread(s)", mr.open_threads);
        events.push(event(EventKind::Mergeable, mr, "", &detail, None));
    }
    let was_open = old.state.as_deref() == Some("opened");
    let own = |user: &str| if user == me { Some(true) } else { None };
    if was_open && mr.state == "merged" {
        let merged = event(EventKind::Merged, mr, &mr.merge_user, "merged", None);
        events.push(Event {
            own: own(&mr.merge_user),
            ..merged
        });
    }
    if was_open && mr.state == "closed" {
        let closed = event(EventKind::Closed, mr, &mr.close_user, "closed", None);
        events.push(Event {
            own: own(&mr.close_user),
            ..closed
        });
    }
    if review
        && let (Some(old_head), Some(new_head)) = (&old.head, &new.head)
        && new_head != old_head
    {
        let short_head: String = new_head.chars().take(8).collect();
        let pushed = event(EventKind::Pushed, mr, "", &format!("pushed {short_head}"), None);
        events.push(Event {
            old_base: Some(old.base.clone()),
            old_head: Some(old.head.clone()),
            new_base: Some(new.base.clone()),
            new_head: Some(new.head.clone()),
            ..pushed
        });
    }
    for thread in mr.resolved_mine.iter().filter(|thread| review && thread.by != me) {
        if old.resolved.as_ref().is_some_and(|ids| ids.contains(&thread.id)) {
            continue;
        }
        let first = &thread.first;
        let resolved = event(
            EventKind::Resolved,
            mr,
            &thread.by,
            &short(&first.body),
            Some(&first.url),
        );
        events.push(at(resolved, &first.position));
    }
    events
}

pub fn mrs_compare(now: &[NormMr], old: Option<&MrsState>, me: &str, review: bool) -> (MrsState, Vec<Event>) {
    let fallback = MrState::default();
    let mut mrs = BTreeMap::new();
    let mut events = Vec::new();
    for mr in now {
        let key = mr.iid.to_string();
        let old_mr = old.and_then(|old| old.mrs.get(&key));
        let new = new_state(mr, old_mr.unwrap_or(&fallback), me);
        if let Some(old_mr) = old_mr {
            events.extend(mr_events(mr, old_mr, &new, me, review));
        }
        mrs.insert(key, new);
    }
    let open: Vec<(&NormMr, &MrState)> = now
        .iter()
        .filter(|mr| mr.state == "opened")
        .map(|mr| (mr, &mrs[&mr.iid.to_string()]))
        .collect();
    let failed = |s: &MrState| s.pipeline.as_ref().is_some_and(|p| p.status == "failed");
    let conflict = |s: &MrState| matches!(s.merge_status.as_deref(), Some("conflict" | "need_rebase"));
    let mut present_needs = Vec::new();
    for (mr, s) in &open {
        let checks = [
            (Need::Failed, failed(s)),
            (Need::Conflict, conflict(s)),
            (Need::Reply, !mr.unaddressed.is_empty()),
            (
                Need::RequestedChanges,
                s.merge_status.as_deref() == Some("requested_changes"),
            ),
            (Need::Commits, s.head.is_some() && s.head != s.seen_head),
            (Need::Ready, s.merge_status.as_deref() == Some("mergeable")),
            (Need::Draft, s.draft == Some(true)),
        ];
        present_needs.extend(checks.into_iter().filter(|(_, holds)| *holds).map(|(need, _)| need));
    }
    let order: &[Need] = match review {
        true => &[Need::Reply, Need::Commits],
        false => &[
            Need::Failed,
            Need::Conflict,
            Need::Reply,
            Need::RequestedChanges,
            Need::Ready,
            Need::Draft,
        ],
    };
    let mut present = Vec::new();
    for (mr, s) in &open {
        present.extend(
            mr.unaddressed
                .iter()
                .map(|thread| format!("thread:{}", thread.discussion)),
        );
        if failed(s) {
            present.push(format!("pipeline:{}", mr.iid));
        }
        if conflict(s) {
            present.push(format!("conflict:{}", mr.iid));
        }
    }
    if !events.is_empty() {
        for mr in now {
            for thread in &mr.unaddressed {
                let last = &thread.last;
                let line = event(
                    EventKind::Unaddressed,
                    mr,
                    &last.author,
                    &short(&last.body),
                    Some(&last.url),
                );
                events.push(with_item(
                    at(line, &thread.position),
                    format!("thread:{}", thread.discussion),
                ));
            }
        }
    }
    let needs = order
        .iter()
        .copied()
        .filter(|need| present_needs.contains(need))
        .collect();
    (MrsState { mrs, needs, present }, events)
}

pub async fn check_mrs(ctx: &CheckContext) -> Result<Vec<Event>, EngineError> {
    let old: Option<MrsState> = state::load(&ctx.state)?;
    let fetches: Vec<Task<_>> = ctx
        .args
        .mrs
        .iter()
        .map(|iid| {
            let (ctx, iid) = (ctx.clone(), *iid);
            Box::pin(async move { fetch_mr(&ctx, iid).await }) as Task<_>
        })
        .collect();
    let data: Vec<MrData> = all_ok(glab::parallel(fetches).await)?;
    let me = data
        .first()
        .map(|data| data.current_user.username.clone())
        .unwrap_or_default();
    let review = ctx.args.review;
    let now: Vec<NormMr> = data.iter().map(|data| normalize(data, &me, review)).collect();
    let (new_state, events) = mrs_compare(&now, old.as_ref(), &me, review);
    let events = add_jobs(ctx, &ctx.project_ref, events).await?;
    state::save(&ctx.state, &new_state)?;
    Ok(events)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{CheckContext, EngineArgs};
    use serde_json::{Value, json};
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::OnceLock;

    fn mr(patch: impl FnOnce(&mut Value)) -> MrData {
        let mut data = json!({"currentUser": {"username": "me"}, "project": {"mergeRequest": {
            "iid": "5", "title": "T", "webUrl": "u", "sourceBranch": "b", "state": "opened",
            "draft": false, "mergeUser": null, "headPipeline": null, "approvedBy": {"nodes": []},
            "detailedMergeStatus": "NOT_APPROVED", "conflicts": false, "mergeable": false,
            "description": "", "labels": [], "diffRefs": null, "awardEmoji": {"nodes": []},
            "discussions": {"nodes": []}}}});
        patch(&mut data["project"]["mergeRequest"]);
        serde_json::from_value(data).unwrap()
    }

    fn note(id: u64, author: &str, body: &str, position: Value) -> Value {
        json!({"id": id.to_string(), "body": body, "system": false, "url": format!("u#note_{id}"),
               "author": {"username": author}, "position": position, "awardEmoji": {"nodes": []}})
    }

    fn system_note(id: u64, author: &str, body: &str) -> Value {
        json!({"id": format!("s{id}"), "resolvable": false, "resolved": false, "resolvedBy": null,
               "notes": {"nodes": [{"id": id.to_string(), "body": body, "system": true,
                   "url": format!("u#note_{id}"), "author": {"username": author}, "position": null,
                   "awardEmoji": {"nodes": []}}]}})
    }

    fn thread(id: &str, resolved_by: Option<&str>, notes: Vec<Value>) -> Value {
        json!({"id": id, "resolvable": true, "resolved": resolved_by.is_some(),
               "resolvedBy": resolved_by.map(|user| json!({"username": user})),
               "notes": {"nodes": notes}})
    }

    fn compare(data: &MrData, old: Option<&MrsState>, review: bool) -> (MrsState, Vec<Event>) {
        mrs_compare(&[normalize(data, "me", review)], old, "me", review)
    }

    fn lines(events: &[Event]) -> Vec<String> {
        events
            .iter()
            .map(|event| serde_json::to_string(event).unwrap())
            .collect()
    }

    #[test]
    fn transient_merge_status_keeps_the_last_stable_values() {
        let (old, _) = compare(
            &mr(|m| {
                m["conflicts"] = json!(true);
                m["detailedMergeStatus"] = json!("CONFLICT");
            }),
            None,
            false,
        );
        let checking = mr(|m| m["detailedMergeStatus"] = json!("CHECKING"));
        let (state, events) = compare(&checking, Some(&old), false);
        assert!(events.is_empty());
        assert_eq!(state.mrs["5"].conflicts, Some(true));
        assert_eq!(state.mrs["5"].merge_status.as_deref(), Some("conflict"));
        assert_eq!(state.needs, vec![Need::Conflict]);
    }

    #[test]
    fn comment_on_unaddressed_thread_has_path_line_and_item_in_order() {
        let first = note(1, "anna", "Old", Value::Null);
        let (old, _) = compare(
            &mr(|m| m["discussions"]["nodes"] = json!([thread("d1", None, vec![first.clone()])])),
            None,
            false,
        );
        let second = note(2, "anna", "Why?", json!({"newPath": "a.kt", "newLine": 3}));
        let (_, events) = compare(
            &mr(|m| m["discussions"]["nodes"] = json!([thread("d1", None, vec![first, second])])),
            Some(&old),
            false,
        );
        assert_eq!(
            lines(&events)[0],
            r#"{"kind":"comment","iid":5,"title":"T","url":"u#note_2","actor":"anna","detail":"Why?","branch":"b","path":"a.kt","line":3,"item":"thread:d1"}"#
        );
    }

    #[test]
    fn unaddressed_lines_follow_only_when_there_are_other_events() {
        let open = json!([thread("d1", None, vec![note(1, "anna", "Nit", Value::Null)])]);
        let (old, _) = compare(&mr(|m| m["discussions"]["nodes"] = open.clone()), None, false);
        let unchanged = mr(|m| m["discussions"]["nodes"] = open.clone());
        let (old, events) = compare(&unchanged, Some(&old), false);
        assert!(events.is_empty());
        let approved = mr(|m| {
            m["discussions"]["nodes"] = open.clone();
            m["approvedBy"]["nodes"] = json!([{"username": "bob"}]);
        });
        let (_, events) = compare(&approved, Some(&old), false);
        let kinds: Vec<_> = events.iter().map(|event| event.kind).collect();
        assert_eq!(kinds, vec![EventKind::Approved, EventKind::Unaddressed]);
    }

    #[test]
    fn review_mode_gives_pushed_and_resolved() {
        let mine = note(1, "me", "Rename", json!({"newPath": "a.kt", "newLine": 4}));
        let (old, _) = compare(
            &mr(|m| {
                m["diffRefs"] = json!({"baseSha": "b1", "headSha": "h1"});
                m["discussions"]["nodes"] = json!([thread("d1", None, vec![mine.clone()])]);
            }),
            None,
            true,
        );
        let (_, events) = compare(
            &mr(|m| {
                m["diffRefs"] = json!({"baseSha": "b1", "headSha": "h2345678901"});
                m["discussions"]["nodes"] = json!([thread("d1", Some("bob"), vec![mine.clone()])]);
            }),
            Some(&old),
            true,
        );
        assert_eq!(
            lines(&events),
            vec![
                r#"{"kind":"pushed","iid":5,"title":"T","url":"u","actor":"","detail":"pushed h2345678","branch":"b","old_base":"b1","old_head":"h1","new_base":"b1","new_head":"h2345678901"}"#,
                r#"{"kind":"resolved","iid":5,"title":"T","url":"u#note_1","actor":"bob","detail":"Rename","branch":"b","path":"a.kt","line":4}"#,
            ]
        );
    }

    #[test]
    fn needs_order_differs_between_review_and_stack() {
        let data = mr(|m| {
            m["draft"] = json!(true);
            m["headPipeline"] = json!({"id": "gid://gitlab/Ci::Pipeline/9", "status": "FAILED"});
            m["discussions"]["nodes"] = json!([thread(
                "d1",
                None,
                vec![
                    note(1, "me", "Why?", Value::Null),
                    note(2, "anna", "Because", Value::Null)
                ]
            )]);
        });
        let stack_needs = compare(&data, None, false).0.needs;
        assert_eq!(stack_needs, vec![Need::Failed, Need::Reply, Need::Draft]);
        assert_eq!(compare(&data, None, true).0.needs, vec![Need::Reply]);
    }

    #[test]
    fn labels_actor_matches_added_or_removed_label_notes() {
        let data = mr(|m| {
            m["discussions"]["nodes"] = json!([
                system_note(2, "bob", "added ~7 label and removed ~8 label"),
                system_note(3, "anna", "changed title from **a** to **b**"),
                system_note(4, "carl", "added ~7 labelsx"),
            ])
        });
        let norm = normalize(&data, "me", false);
        assert_eq!(norm.labels_user, "bob");
        assert_eq!(norm.title_user, "anna");
        assert!(is_labels_note("removed ~7 ~9 labels"));
        assert!(is_labels_note("added ~7 label\n"));
        assert!(!is_labels_note("added ~7\nlabel"));
        assert!(!is_labels_note("changed ~7 label"));
    }

    fn fake_glab() -> &'static Path {
        static DIR: OnceLock<PathBuf> = OnceLock::new();
        DIR.get_or_init(|| {
            let dir = std::env::temp_dir().join(format!("watchd-glab-{}", std::process::id()));
            std::fs::create_dir_all(dir.join("bin")).unwrap();
            let script = r#"#!/bin/sh
base=BASE
tag=; iid=
for a; do case $a in path=*) tag=${a#path=} ;; iid=*) iid=${a#iid=} ;; esac; done
case "$2" in projects/*) tag=$(echo "$2" | cut -d/ -f2) ;; esac
mkdir -p "$base/$tag/live"
pwd -P >"$base/$tag/cwd"
echo $$ >"$base/$tag/live/$$"
ls "$base/$tag/live" | wc -l >>"$base/$tag/counts"
if [ "$tag" = slow ]; then exec sleep 30; fi
sleep 0.2
rm -f "$base/$tag/live/$$"
case "$2" in
  graphql) printf '{"data":{"currentUser":{"username":"me"},"project":{"mergeRequest":{"iid":"%s","title":"T","webUrl":"u","sourceBranch":"b","state":"opened","draft":false,"mergeUser":null,"headPipeline":null,"approvedBy":{"nodes":[]},"detailedMergeStatus":"MERGEABLE","conflicts":false,"mergeable":true}}}}\n' "$iid" ;;
  */discussions*|*/award_emoji*) echo '[]' ;;
  *) echo '{}' ;;
esac
"#
            .replace("BASE", &dir.display().to_string());
            let glab = dir.join("bin/glab");
            std::fs::write(&glab, script).unwrap();
            std::fs::set_permissions(&glab, std::fs::Permissions::from_mode(0o755)).unwrap();
            let path = format!("{}:{}", dir.join("bin").display(), std::env::var("PATH").unwrap());
            // SAFETY: this runs once, before the first fake call, and the other tests only read PATH.
            unsafe { std::env::set_var("PATH", path) };
            dir
        })
    }

    fn context(project: &str, mrs: Vec<u64>) -> CheckContext {
        let dir = fake_glab().join(project);
        std::fs::create_dir_all(&dir).unwrap();
        CheckContext {
            args: EngineArgs {
                mrs,
                ..EngineArgs::default()
            },
            repo: dir.clone(),
            state: dir.join("state.json"),
            project: project.to_string(),
            project_ref: project.to_string(),
            cache: None,
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn stack_check_of_20_mrs_runs_at_most_8_glab_calls_at_once() {
        let ctx = context("parallel", (1..=20).collect());
        check_mrs(&ctx).await.unwrap();
        let counts = std::fs::read_to_string(fake_glab().join("parallel/counts")).unwrap();
        let most = counts
            .lines()
            .filter_map(|line| line.trim().parse::<u32>().ok())
            .max()
            .unwrap();
        assert!((2..=8).contains(&most), "most live calls: {most}");
        let saved = std::fs::read_to_string(&ctx.state).unwrap();
        let state: MrsState = serde_json::from_str(&saved).unwrap();
        assert_eq!(state.mrs.len(), 20);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn glab_runs_in_the_repo_folder() {
        let ctx = context("folder", vec![1]);
        check_mrs(&ctx).await.unwrap();
        let cwd = std::fs::read_to_string(fake_glab().join("folder/cwd")).unwrap();
        assert_eq!(cwd.trim(), ctx.repo.canonicalize().unwrap().display().to_string());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn cancelled_check_leaves_no_glab_process() {
        let ctx = context("slow", vec![1, 2, 3]);
        let live = fake_glab().join("slow/live");
        let live_pids = || -> Vec<u32> {
            std::fs::read_dir(&live)
                .map(|entries| {
                    entries
                        .map(|entry| entry.unwrap().file_name().to_string_lossy().parse().unwrap())
                        .collect()
                })
                .unwrap_or_default()
        };
        let check = tokio::spawn(async move { check_mrs(&ctx).await });
        // On a busy machine, the first glab call can start late.
        for _ in 0..100 {
            if !live_pids().is_empty() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        check.abort();
        assert!(
            check.await.is_err_and(|error| error.is_cancelled()),
            "the slow check must be cancelled"
        );
        let pids = live_pids();
        assert!(!pids.is_empty());
        for _ in 0..50 {
            if !pids.iter().any(|pid| crate::platform::process_alive(*pid)) {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        panic!("glab processes still alive: {pids:?}");
    }
}
