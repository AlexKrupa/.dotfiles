use serde::{Deserialize, Serialize};

use crate::core::worktrees::WorktreeState;

/// The record of a herdr workspace of format version 1, which the daemon start converts.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Workspace {
    #[serde(default)]
    pub kind: Option<Kind>,
    #[serde(default)]
    pub stage: Option<Stage>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Mine,
    Review,
    Bump,
    Debug,
    Hub,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Stage {
    Done,
    Stopped,
}

/// With no live watch, a new task starts, and the end stage of an earlier watch does not apply to it.
pub fn set_kind(state: &mut WorktreeState, kind: Kind, live_watch: bool) {
    state.kind = Some(kind);
    if !live_watch {
        state.stage = None;
    }
}

impl Kind {
    pub fn parse(text: &str) -> Option<Kind> {
        match text {
            "mine" => Some(Kind::Mine),
            "review" => Some(Kind::Review),
            "bump" => Some(Kind::Bump),
            "debug" => Some(Kind::Debug),
            "hub" => Some(Kind::Hub),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_without_live_subscription_clears_the_stage() {
        let mut state = WorktreeState {
            kind: Some(Kind::Mine),
            stage: Some(Stage::Done),
            ..WorktreeState::new("/r".into(), "/r".into(), None, String::new(), &[])
        };
        set_kind(&mut state, Kind::Review, true);
        assert_eq!((state.kind, state.stage), (Some(Kind::Review), Some(Stage::Done)));
        set_kind(&mut state, Kind::Bump, false);
        assert_eq!((state.kind, state.stage), (Some(Kind::Bump), None));
    }
}
