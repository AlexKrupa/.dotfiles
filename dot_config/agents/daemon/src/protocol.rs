//! The socket protocol between the client commands and the daemon: one JSON object per line, one
//! request, and one response, except for `follow`.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};

use crate::core::eventlog::RouteAction;
use crate::core::items::{Items, RoutedEvent};
use crate::core::subs::{Agent, Mode, Session, SessionKey};
use crate::core::worktrees::Kind;
use crate::core::worktrees::WorktreeState;
use crate::report::ReportInput;

/// A line of an older client has no folder.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Envelope {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<PathBuf>,
    #[serde(flatten)]
    pub request: Request,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    Watch(WatchRequest),
    Wait {
        session: String,
        owner_pid: u32,
        /// The live session of the same owner process gives its watches to this session.
        #[serde(default)]
        rename_owner_session: bool,
    },
    /// The request of an older client. The daemon answers it with an error.
    Subscribe(serde_json::Value),
    Unsubscribe {
        key: String,
        slug: String,
        mode: Mode,
        session: String,
    },
    Status,
    Kind {
        kind: Kind,
    },
    Route {
        key: String,
        iid: u64,
        action: RouteAction,
    },
    Report {
        key: String,
        mode: Mode,
        mrs: Vec<u64>,
        input: ReportInput,
    },
    DebugState,
    Follow {
        after: Option<u64>,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WatchRequest {
    pub key: String,
    pub slug: String,
    pub repo: PathBuf,
    pub mode: Mode,
    pub mrs: Vec<u64>,
    pub interval: u64,
    pub session: String,
    pub fresh: bool,
}

/// An event of one watch of a session, which can have more than one watch.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct KeyedEvent {
    pub key: String,
    pub mode: Mode,
    #[serde(flatten)]
    pub routed: RoutedEvent,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    Events {
        events: Vec<KeyedEvent>,
        /// The keys that a different session took.
        #[serde(default)]
        replaced: Vec<SessionKey>,
    },
    /// The text for stderr, with its newline.
    Error {
        text: String,
    },
    Replaced,
    Status(StatusReport),
    Ok,
    Report {
        text: String,
    },
    State(Box<DebugState>),
}

/// The memory fields are `None` when no daemon runs.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct DebugState {
    pub pid: Option<u32>,
    pub subs: BTreeMap<String, Agent>,
    pub inbox: BTreeMap<String, Vec<RoutedEvent>>,
    pub errors: BTreeMap<String, String>,
    pub items: BTreeMap<String, Items>,
    pub engine: BTreeMap<String, serde_json::Value>,
    pub worktrees: BTreeMap<String, WorktreeState>,
    pub sessions: BTreeMap<String, Session>,
    pub repos: Option<BTreeMap<String, RepoTimes>>,
    pub rounds: Option<BTreeMap<String, u64>>,
    /// The number of the connected waiter of each session.
    pub waiters: Option<BTreeMap<String, u64>>,
    pub followers: Option<usize>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RepoTimes {
    pub last_poll: i64,
    pub next_round: Option<i64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatusReport {
    pub pid: Option<u32>,
    pub repos: Vec<RepoPoll>,
    pub subs: Vec<SubStatus>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RepoPoll {
    pub slug: String,
    pub last_poll: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SubStatus {
    pub sub: Agent,
    pub live: bool,
    pub inbox_lines: usize,
}

pub async fn send<W: AsyncWrite + Unpin, T: Serialize>(writer: &mut W, value: &T) -> std::io::Result<()> {
    let mut line = serde_json::to_string(value).map_err(std::io::Error::other)?;
    line.push('\n');
    writer.write_all(line.as_bytes()).await?;
    writer.flush().await
}

/// Returns `None` when the other side closed the socket.
pub async fn receive<R, T>(reader: &mut BufReader<R>) -> std::io::Result<Option<T>>
where
    R: tokio::io::AsyncRead + Unpin,
    T: DeserializeOwned,
{
    let mut line = String::new();
    match reader.read_line(&mut line).await? {
        0 => Ok(None),
        _ => serde_json::from_str(&line).map(Some).map_err(std::io::Error::other),
    }
}
