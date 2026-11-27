//! The view of a watch key: its branches, their rows, and the artifacts of the work. `watchd
//! follow` sends it to clients.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::core::worktrees::WorktreeState;
use crate::engine::event::EventKind;
use crate::engine::state::{MrState, MrsState};
use crate::report::{Row, RowSection, sentence, without_anchor};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct View {
    pub key: String,
    pub path: PathBuf,
    pub hub: bool,
    /// The path is the main checkout of the repo.
    #[serde(default)]
    pub main: bool,
    /// The session of the agent record of `key`. `None` with no record.
    #[serde(default)]
    pub session: Option<String>,
    pub heading: Option<String>,
    pub artifacts: Vec<Artifact>,
    pub branches: Vec<Branch>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Branch {
    pub name: Option<String>,
    pub title: String,
    pub iid: Option<u64>,
    pub status: Vec<String>,
    pub rows: Vec<ViewRow>,
    pub artifacts: Vec<Artifact>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ViewRow {
    pub id: u64,
    pub section: RowSection,
    pub kind: String,
    pub what: String,
    pub result: Option<String>,
    pub url: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Artifact {
    pub kind: String,
    pub target: String,
}

/// An artifact that a client recorded for a worktree. `branch: None` puts it in the common list.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct StoredArtifact {
    pub kind: String,
    pub target: String,
    pub branch: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactBranch {
    CheckedOut,
    Named(String),
    Common,
}

const SHOWN_APPROVERS: usize = 3;

/// The view as text: the heading, the common artifacts, then each branch with its rows and
/// artifacts. A row has its id, which the report takes.
pub fn view_text(view: &View) -> String {
    let artifact_line = |artifact: &Artifact| format!("  {}  {}", artifact.kind, artifact.target);
    let mut lines: Vec<String> = view.heading.iter().cloned().collect();
    lines.extend(view.artifacts.iter().map(artifact_line));
    for branch in &view.branches {
        let iid = branch.iid.map(|iid| format!("!{iid}"));
        let parts: Vec<String> = [branch.title.clone()]
            .into_iter()
            .chain(iid)
            .chain(branch.status.iter().cloned())
            .collect();
        lines.push(parts.join(" · "));
        for row in &branch.rows {
            let result = row
                .result
                .as_ref()
                .map(|result| format!(" -> {result}"))
                .unwrap_or_default();
            let url = row.url.as_ref().map(|url| format!("  {url}")).unwrap_or_default();
            lines.push(format!("  {}  {}  {}{result}{url}", row.id, row.kind, row.what));
        }
        lines.extend(branch.artifacts.iter().map(artifact_line));
    }
    lines.iter().map(|line| format!("{line}\n")).collect()
}

/// The branches come in stack order. With no stack, the checked-out branch has the first MR. An MR
/// or a row of an MR that no branch has gets a branch with no name. A row with no MR goes to the
/// checked-out branch.
pub fn compose(
    key: &str,
    worktree: &WorktreeState,
    engine: &MrsState,
    rows: &[Row],
    drafts: &BTreeMap<String, String>,
    ticket_url: Option<&str>,
) -> View {
    let mut branches: Vec<Branch> = worktree
        .stack
        .iter()
        .map(|name| empty_branch(Some(name.clone()), worktree.branch_mrs.get(name).copied()))
        .collect();
    if branches.is_empty() {
        let iid = worktree
            .mrs
            .iter()
            .copied()
            .chain(rows.iter().filter_map(|row| row.iid))
            .next();
        branches.push(empty_branch(worktree.branch.clone(), iid));
    }
    let extra_iids = worktree
        .mrs
        .iter()
        .copied()
        .chain(rows.iter().filter_map(|row| row.iid));
    for iid in extra_iids {
        if branches.iter().all(|branch| branch.iid != Some(iid)) {
            branches.push(empty_branch(None, Some(iid)));
        }
    }
    let checked_out = branches
        .iter()
        .position(|branch| branch.name.is_some() && branch.name == worktree.branch)
        .unwrap_or(0);
    for row in rows {
        let index = match row.iid {
            Some(iid) => branches
                .iter()
                .position(|branch| branch.iid == Some(iid))
                .unwrap_or(checked_out),
            None => checked_out,
        };
        branches[index].rows.push(view_row(row));
    }
    // The local conflict test is of the top branch of the stack.
    let top = worktree
        .stack
        .len()
        .checked_sub(1)
        .filter(|_| !worktree.conflict.is_empty());
    let mut common: Vec<Artifact> = Vec::new();
    for (index, branch) in branches.iter_mut().enumerate() {
        let mr = branch.iid.and_then(|iid| engine.mrs.get(&iid.to_string()));
        let name = branch.name.as_deref();
        branch.title = mr
            .and_then(|mr| mr.title.clone())
            .or_else(|| name.and_then(|name| drafts.get(name).cloned()))
            .or_else(|| name.map(str::to_string))
            .or_else(|| branch.iid.map(|iid| format!("!{iid}")))
            .unwrap_or_default();
        branch.status = status_parts(mr.unwrap_or(&MrState::default()), top == Some(index));
        branch.rows.sort_by_key(|row| urgency(row.section));
        let ticket = ticket_url.zip(name.and_then(ticket_key));
        branch
            .artifacts
            .extend(ticket.map(|(url, key)| artifact("ticket", &url.replace("{key}", &key))));
        branch.artifacts.extend(mr.map(mr_artifacts).unwrap_or_default());
    }
    for stored in &worktree.artifacts {
        let place = stored
            .branch
            .as_ref()
            .and_then(|name| branches.iter_mut().find(|branch| branch.name.as_ref() == Some(name)));
        let list = match place {
            Some(branch) => &mut branch.artifacts,
            None => &mut common,
        };
        list.retain(|other| (&other.kind, &other.target) != (&stored.kind, &stored.target));
        list.push(artifact(&stored.kind, &stored.target));
    }
    if branches.len() > 1 {
        let shared: Vec<Artifact> = branches[0]
            .artifacts
            .iter()
            .filter(|artifact| branches.iter().all(|branch| branch.artifacts.contains(artifact)))
            .cloned()
            .collect();
        for branch in &mut branches {
            branch.artifacts.retain(|artifact| !shared.contains(artifact));
        }
        common.retain(|artifact| !shared.contains(artifact));
        common.splice(0..0, shared);
    }
    common.sort_by_key(|artifact| artifact.kind != "ticket");
    let keys: Vec<Option<String>> = branches
        .iter()
        .map(|branch| branch.name.as_deref().and_then(ticket_key))
        .collect();
    let key_of_all = keys[0].clone().filter(|_| keys.iter().all(|key| *key == keys[0]));
    let heading = match (branches.len(), key_of_all) {
        (0 | 1, key_of_all) => key_of_all,
        (count, Some(key_of_all)) => Some(format!("{key_of_all} · stack of {count}")),
        (count, None) => Some(format!("Stack of {count}")),
    };
    View {
        key: key.to_string(),
        path: worktree.path.clone(),
        hub: false,
        main: worktree.path == worktree.repo,
        session: None,
        heading,
        artifacts: common,
        branches,
    }
}

/// One branch for each MR and for each default-branch pipeline, in the order of their first row.
/// Only an MR of the user has a status.
pub fn compose_hub(key: &str, path: &Path, rows: &[Row], own: &MrsState) -> View {
    let mut branches: Vec<Branch> = Vec::new();
    for row in rows {
        let default_branch = match (row.iid, &row.event) {
            (None, Some(event)) if event.kind == EventKind::DefaultFailed => Some(event.branch.clone()),
            _ => None,
        };
        let found = branches
            .iter()
            .position(|branch| (branch.iid, &branch.name) == (row.iid, &default_branch));
        let index = match found {
            Some(index) => index,
            None => {
                let mr = row.iid.and_then(|iid| own.mrs.get(&iid.to_string()));
                let mr_url = mr
                    .and_then(|mr| mr.url.clone())
                    .or_else(|| row.iid.and(row.url.as_deref().map(without_anchor)));
                let artifacts = match (&default_branch, row.iid) {
                    (Some(_), _) => row.url.iter().map(|url| artifact("pipeline", url)).collect(),
                    (None, Some(_)) => mr_url.iter().map(|url| artifact("MR", url)).collect(),
                    (None, None) => Vec::new(),
                };
                let title = row
                    .title
                    .clone()
                    .or_else(|| mr.and_then(|mr| mr.title.clone()))
                    .or_else(|| default_branch.clone())
                    .or_else(|| row.iid.map(|iid| format!("!{iid}")))
                    .unwrap_or_else(|| OTHER.to_string());
                branches.push(Branch {
                    name: default_branch,
                    title,
                    iid: row.iid,
                    status: mr.map(|mr| status_parts(mr, false)).unwrap_or_default(),
                    rows: Vec::new(),
                    artifacts,
                });
                branches.len() - 1
            }
        };
        branches[index].rows.push(view_row(row));
    }
    for branch in &mut branches {
        branch.rows.sort_by_key(|row| urgency(row.section));
    }
    View {
        key: key.to_string(),
        path: path.to_path_buf(),
        hub: true,
        main: true,
        session: None,
        heading: None,
        artifacts: Vec::new(),
        branches,
    }
}

/// The title of the hub entry of the rows with no MR and no default-branch pipeline.
const OTHER: &str = "Other";

/// The parts of the status of an MR. A merged or closed MR has only that part.
fn status_parts(mr: &MrState, local_conflict: bool) -> Vec<String> {
    if let Some(state) = mr
        .state
        .as_deref()
        .filter(|state| matches!(*state, "merged" | "closed"))
    {
        return vec![state.to_string()];
    }
    let approvers = mr.approved_by.as_deref().unwrap_or_default();
    let approvals = match approvers.len() {
        0 => None,
        count if count > SHOWN_APPROVERS => Some(format!(
            "approved by {} +{}",
            approvers[..SHOWN_APPROVERS].join(", "),
            count - SHOWN_APPROVERS
        )),
        _ => Some(format!("approved by {}", approvers.join(", "))),
    };
    let running = mr
        .pipeline
        .as_ref()
        .is_some_and(|pipeline| matches!(pipeline.status.as_str(), "running" | "pending"));
    [
        (mr.draft == Some(true)).then(|| "draft".to_string()),
        (mr.merge_status.as_deref() == Some("mergeable")).then(|| "ready to merge".to_string()),
        approvals,
        local_conflict.then(|| "local conflict".to_string()),
        running.then(|| "pipeline running".to_string()),
    ]
    .into_iter()
    .flatten()
    .collect()
}

/// The first match of `[A-Z][A-Z0-9]+-[0-9]+`.
fn ticket_key(branch: &str) -> Option<String> {
    let bytes = branch.as_bytes();
    let in_class = |index: usize| {
        bytes
            .get(index)
            .is_some_and(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
    };
    let digit = |index: usize| bytes.get(index).is_some_and(u8::is_ascii_digit);
    (0..bytes.len())
        .filter(|start| bytes[*start].is_ascii_uppercase())
        .find_map(|start| {
            let dash = (start + 1..=bytes.len()).find(|index| !in_class(*index))?;
            let end = (dash + 1..=bytes.len()).find(|index| !digit(*index))?;
            let matches = dash > start + 1 && bytes.get(dash) == Some(&b'-') && end > dash + 1;
            matches.then(|| branch[start..end].to_string())
        })
}

fn artifact(kind: &str, target: &str) -> Artifact {
    Artifact {
        kind: kind.to_string(),
        target: target.to_string(),
    }
}

fn empty_branch(name: Option<String>, iid: Option<u64>) -> Branch {
    Branch {
        name,
        title: String::new(),
        iid,
        status: Vec::new(),
        rows: Vec::new(),
        artifacts: Vec::new(),
    }
}

/// The MR while it is open, and its pipeline while it runs or after it fails.
fn mr_artifacts(mr: &MrState) -> Vec<Artifact> {
    let open = !matches!(mr.state.as_deref(), Some("merged" | "closed"));
    let Some(url) = mr
        .url
        .as_deref()
        .map(without_anchor)
        .filter(|url| open && !url.is_empty())
    else {
        return Vec::new();
    };
    let pipeline = mr
        .pipeline
        .as_ref()
        .filter(|pipeline| pipeline.status != "success")
        .and_then(|pipeline| {
            let project = url.split_once("/-/merge_requests/")?.0;
            Some(artifact("pipeline", &format!("{project}/-/pipelines/{}", pipeline.id)))
        });
    [Some(artifact("MR", &url)), pipeline].into_iter().flatten().collect()
}

fn view_row(row: &Row) -> ViewRow {
    let what = match (&row.what, &row.event) {
        (Some(what), _) => what.clone(),
        (None, Some(event)) => sentence(event),
        (None, None) => String::new(),
    };
    ViewRow {
        id: row.n,
        section: row.section,
        kind: row
            .event
            .as_ref()
            .map_or("agent", |event| row_kind(event.kind))
            .to_string(),
        what,
        result: Some(row.result.clone()).filter(|result| !result.is_empty()),
        url: row.url.clone().filter(|url| !url.is_empty()),
    }
}

fn row_kind(kind: EventKind) -> &'static str {
    match kind {
        EventKind::Comment | EventKind::OwnComment | EventKind::Note | EventKind::Unaddressed => "comment",
        EventKind::Pipeline | EventKind::DefaultFailed => "pipeline",
        EventKind::Approved | EventKind::Unapproved | EventKind::Todo => "review",
        EventKind::Resolved => "thread",
        EventKind::Pushed => "commits",
        EventKind::Conflict => "conflict",
        EventKind::Opened => "MR",
        EventKind::Reaction => "reaction",
        EventKind::PullBlocked => "pull",
        EventKind::Draft
        | EventKind::Ready
        | EventKind::Title
        | EventKind::Description
        | EventKind::Labels
        | EventKind::Mergeable
        | EventKind::Merged
        | EventKind::Closed => "status",
    }
}

fn urgency(section: RowSection) -> u8 {
    match section {
        RowSection::NeedsYou => 0,
        RowSection::Agent => 1,
        RowSection::Info => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::event::Event;
    use crate::engine::state::PipelineState;

    const MR_URL: &str = "https://g/a/b/-/merge_requests/410";

    fn worktree(stack: &[&str], branch_mrs: &[(&str, u64)]) -> WorktreeState {
        WorktreeState {
            stack: stack.iter().map(|name| name.to_string()).collect(),
            mrs: branch_mrs.iter().map(|(_, iid)| *iid).collect(),
            branch_mrs: branch_mrs.iter().map(|(name, iid)| (name.to_string(), *iid)).collect(),
            ..WorktreeState::new(
                "/r-wt".into(),
                "/r".into(),
                stack.last().map(|name| name.to_string()),
                "app".into(),
                &[],
            )
        }
    }

    fn engine(iid: u64, mr: MrState) -> MrsState {
        MrsState {
            mrs: BTreeMap::from([(iid.to_string(), mr)]),
            ..MrsState::default()
        }
    }

    fn open_mr(pipeline: Option<(u64, &str)>) -> MrState {
        MrState {
            state: Some("opened".into()),
            title: Some("Extract repo".into()),
            url: Some(MR_URL.into()),
            pipeline: pipeline.map(|(id, status)| PipelineState {
                id,
                status: status.into(),
            }),
            ..MrState::default()
        }
    }

    fn stored(kind: &str, target: &str, branch: Option<&str>) -> StoredArtifact {
        StoredArtifact {
            kind: kind.into(),
            target: target.into(),
            branch: branch.map(str::to_string),
        }
    }

    fn event(kind: EventKind, iid: Option<u64>) -> Event {
        Event::new(kind, iid, None, "https://g/a/b/-/pipelines/9", "bob", "fix it", "main")
    }

    fn row(n: u64, section: RowSection, iid: Option<u64>, event: Option<Event>) -> Row {
        Row {
            n,
            section,
            iid,
            title: None,
            url: None,
            event,
            what: None,
            result: String::new(),
            since: None,
        }
    }

    fn kinds(artifacts: &[Artifact]) -> Vec<&str> {
        artifacts.iter().map(|artifact| artifact.kind.as_str()).collect()
    }

    fn no_drafts() -> BTreeMap<String, String> {
        BTreeMap::new()
    }

    #[test]
    fn stack_view_has_common_and_branch_artifacts() {
        let worktree = WorktreeState {
            artifacts: vec![
                stored("spec", "/s/spec.md", None),
                stored("review", "/s/review.md", Some("a/APP-1-y")),
            ],
            ..worktree(&["a/APP-1-x", "a/APP-1-y"], &[("a/APP-1-x", 410)])
        };
        let engine = engine(410, open_mr(Some((7, "running"))));

        let view = compose("app", &worktree, &engine, &[], &no_drafts(), Some("https://t/{key}"));

        assert_eq!(view.heading.as_deref(), Some("APP-1 · stack of 2"));
        assert_eq!(
            view.artifacts,
            [artifact("ticket", "https://t/APP-1"), artifact("spec", "/s/spec.md")]
        );
        assert_eq!(view.branches[0].iid, Some(410));
        assert_eq!(
            view.branches[0].artifacts,
            [
                artifact("MR", MR_URL),
                artifact("pipeline", "https://g/a/b/-/pipelines/7")
            ]
        );
        assert_eq!(view.branches[1].artifacts, [artifact("review", "/s/review.md")]);
    }

    #[test]
    fn different_ticket_keys_stay_with_their_branches() {
        let worktree = worktree(&["APP-1-x", "APP-2-y"], &[]);

        let view = compose(
            "app",
            &worktree,
            &MrsState::default(),
            &[],
            &no_drafts(),
            Some("https://t/{key}"),
        );

        assert_eq!(view.heading.as_deref(), Some("Stack of 2"));
        assert!(view.artifacts.is_empty());
        assert_eq!(view.branches[0].artifacts, [artifact("ticket", "https://t/APP-1")]);
        assert_eq!(view.branches[1].artifacts, [artifact("ticket", "https://t/APP-2")]);
    }

    #[test]
    fn branch_with_no_mr_uses_the_branch_name() {
        let worktree = worktree(&["a/sync"], &[]);

        let plain = compose("app", &worktree, &MrsState::default(), &[], &no_drafts(), None);
        let drafts = BTreeMap::from([("a/sync".to_string(), "Show sync".to_string())]);
        let drafted = compose("app", &worktree, &MrsState::default(), &[], &drafts, None);

        let branch = &plain.branches[0];
        assert_eq!((branch.title.as_str(), branch.iid), ("a/sync", None));
        assert!(branch.artifacts.is_empty());
        assert!(plain.artifacts.is_empty());
        assert_eq!(drafted.branches[0].title, "Show sync");
    }

    #[test]
    fn worktree_with_no_stack_puts_its_first_mr_on_the_checked_out_branch() {
        let worktree = WorktreeState {
            branch: Some("main".into()),
            ..worktree(&[], &[])
        };
        let rows = [row(
            1,
            RowSection::NeedsYou,
            Some(5),
            Some(event(EventKind::Comment, Some(5))),
        )];

        let view = compose("app", &worktree, &MrsState::default(), &rows, &no_drafts(), None);

        assert_eq!(view.branches.len(), 1);
        let branch = &view.branches[0];
        assert_eq!(
            (branch.name.as_deref(), branch.iid, branch.rows.len()),
            (Some("main"), Some(5), 1)
        );
    }

    #[test]
    fn passed_pipeline_is_hidden() {
        let worktree = worktree(&["a/x"], &[("a/x", 410)]);
        let passed = compose(
            "app",
            &worktree,
            &engine(410, open_mr(Some((7, "success")))),
            &[],
            &no_drafts(),
            None,
        );
        let failed = compose(
            "app",
            &worktree,
            &engine(410, open_mr(Some((7, "failed")))),
            &[],
            &no_drafts(),
            None,
        );

        assert_eq!(kinds(&passed.branches[0].artifacts), ["MR"]);
        assert_eq!(kinds(&failed.branches[0].artifacts), ["MR", "pipeline"]);
    }

    #[test]
    fn rows_go_to_their_branch_needs_you_first() {
        let worktree = worktree(&["a/x", "a/y"], &[("a/x", 410), ("a/y", 411)]);
        let model = Row {
            what: Some("Fixed lint".into()),
            ..row(3, RowSection::Agent, Some(411), None)
        };
        let rows = [
            row(
                1,
                RowSection::Info,
                Some(410),
                Some(event(EventKind::Pipeline, Some(410))),
            ),
            row(
                2,
                RowSection::NeedsYou,
                Some(410),
                Some(event(EventKind::Comment, Some(410))),
            ),
            model,
        ];

        let view = compose("app", &worktree, &MrsState::default(), &rows, &no_drafts(), None);

        let first: Vec<(u64, RowSection, &str)> = view.branches[0]
            .rows
            .iter()
            .map(|row| (row.id, row.section, row.kind.as_str()))
            .collect();
        assert_eq!(
            first,
            [(2, RowSection::NeedsYou, "comment"), (1, RowSection::Info, "pipeline")]
        );
        assert_eq!(view.branches[0].rows[0].what, "@bob: \"fix it\"");
        let second = &view.branches[1].rows[0];
        assert_eq!((second.kind.as_str(), second.what.as_str()), ("agent", "Fixed lint"));
    }

    #[test]
    fn status_parts_lists_the_parts() {
        let open = MrState {
            draft: Some(true),
            merge_status: Some("mergeable".into()),
            approved_by: Some(["a", "b", "c", "d"].map(str::to_string).to_vec()),
            pipeline: Some(PipelineState {
                id: 7,
                status: "running".into(),
            }),
            ..MrState::default()
        };
        let merged = MrState {
            state: Some("merged".into()),
            ..open.clone()
        };

        assert_eq!(
            status_parts(&open, true),
            [
                "draft",
                "ready to merge",
                "approved by a, b, c +1",
                "local conflict",
                "pipeline running"
            ]
        );
        assert_eq!(status_parts(&merged, true), ["merged"]);
        assert!(status_parts(&MrState::default(), false).is_empty());
    }

    #[test]
    fn ticket_key_takes_the_first_match() {
        assert_eq!(ticket_key("alex/APP-12-sync").as_deref(), Some("APP-12"));
        assert_eq!(ticket_key("A-1/X2Y-3").as_deref(), Some("X2Y-3"));
        assert_eq!(ticket_key("app-1"), None);
    }

    #[test]
    fn hub_view_groups_rows_by_mr() {
        let failed = Row {
            url: Some("https://g/a/b/-/pipelines/9".into()),
            ..row(
                3,
                RowSection::NeedsYou,
                None,
                Some(event(EventKind::DefaultFailed, None)),
            )
        };
        let rows = [
            row(
                1,
                RowSection::Info,
                Some(12),
                Some(event(EventKind::Approved, Some(12))),
            ),
            row(
                2,
                RowSection::NeedsYou,
                Some(14),
                Some(event(EventKind::Todo, Some(14))),
            ),
            failed,
        ];

        let view = compose_hub("app-hub", Path::new("/r"), &rows, &MrsState::default());

        assert!(view.hub);
        let iids: Vec<Option<u64>> = view.branches.iter().map(|branch| branch.iid).collect();
        assert_eq!(iids, [Some(12), Some(14), None]);
        assert_eq!(view.branches[2].title, "main");
        assert_eq!(
            view.branches[2].artifacts,
            [artifact("pipeline", "https://g/a/b/-/pipelines/9")]
        );
    }
}
