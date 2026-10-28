use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::core::items::RoutedEvent;
use crate::engine::event::EventKind;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Hub,
    Stack,
    Review,
}

impl Mode {
    /// The name in the files and the lines of the daemon.
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Hub => "hub",
            Mode::Stack => "stack",
            Mode::Review => "review",
        }
    }
}

/// The newest session owns the key: `replaced_sessions` has the live sessions that it replaced.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Agent {
    pub key: String,
    pub slug: String,
    pub repo: PathBuf,
    pub mode: Mode,
    pub mrs: Vec<u64>,
    pub interval: u64,
    pub session_pid: u32,
    pub client_pid: u32,
    pub client_at: i64,
    #[serde(default)]
    pub replaced_sessions: Vec<u32>,
    #[serde(default)]
    pub ended_mrs: Vec<u64>,
}

/// Returns true if this made all MRs of the agent end. With no `--mr` list, the MRs of the
/// agent are the polled MRs.
pub fn add_ended(sub: &mut Agent, events: &[RoutedEvent], polled: &[u64]) -> bool {
    let ended: Vec<u64> = events
        .iter()
        .filter(|routed| matches!(routed.event.kind, EventKind::Merged | EventKind::Closed))
        .filter_map(|routed| routed.event.iid)
        .collect();
    if ended.is_empty() {
        return false;
    }
    sub.ended_mrs.extend(ended);
    sub.ended_mrs.sort_unstable();
    sub.ended_mrs.dedup();
    let mrs = if sub.mrs.is_empty() { polled } else { &sub.mrs };
    mrs.iter().all(|mr| sub.ended_mrs.contains(mr))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::event::Event;

    fn agent(mrs: Vec<u64>) -> Agent {
        Agent {
            key: "app-1-review-5".to_string(),
            slug: "app".to_string(),
            repo: "/r".into(),
            mode: Mode::Stack,
            mrs,
            interval: 120,
            session_pid: 1,
            client_pid: 2,
            client_at: 0,
            replaced_sessions: Vec::new(),
            ended_mrs: Vec::new(),
        }
    }

    fn merged(iid: u64) -> RoutedEvent {
        RoutedEvent {
            event: Event::new(EventKind::Merged, Some(iid), Some("T"), "u", "a", "merged", "b"),
            row: 1,
        }
    }

    #[test]
    fn add_ended_ignores_mrs_outside_the_agent() {
        let mut sub = agent(vec![5, 6]);
        assert!(!add_ended(&mut sub, &[merged(7)], &[]));
        assert!(!add_ended(&mut sub, &[merged(5)], &[]));
        assert_eq!(sub.ended_mrs, vec![5, 7]);
        assert!(add_ended(&mut sub, &[merged(6)], &[]));
    }

    #[test]
    fn add_ended_with_no_mr_list_uses_the_polled_mrs() {
        let mut sub = agent(Vec::new());

        assert!(!add_ended(&mut sub, &[merged(5)], &[5, 6]));
        assert!(add_ended(&mut sub, &[merged(6)], &[6]));
    }

    #[test]
    fn agent_record_has_the_fields_of_the_bash_client() {
        let line = r#"{"key":"app-1-review-5","slug":"app","repo":"/r","mode":"stack","mrs":[5],"interval":120,"session_pid":1,"client_pid":2,"client_at":0,"replaced_sessions":[],"ended_mrs":[]}"#;
        let sub: Agent = serde_json::from_str(line).unwrap();
        assert_eq!(serde_json::to_string(&sub).unwrap(), line);
    }
}
