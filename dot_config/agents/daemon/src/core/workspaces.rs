use serde::{Deserialize, Serialize};

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
pub fn set_kind(workspace: &mut Workspace, kind: Kind, live_watch: bool) {
    workspace.kind = Some(kind);
    if !live_watch {
        workspace.stage = None;
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
        let mut workspace = Workspace {
            kind: Some(Kind::Mine),
            stage: Some(Stage::Done),
        };
        set_kind(&mut workspace, Kind::Review, true);
        assert_eq!(
            workspace,
            Workspace {
                kind: Some(Kind::Review),
                stage: Some(Stage::Done)
            }
        );
        set_kind(&mut workspace, Kind::Bump, false);
        assert_eq!(
            workspace,
            Workspace {
                kind: Some(Kind::Bump),
                stage: None
            }
        );
        assert_eq!(
            serde_json::to_string(&workspace).unwrap(),
            r#"{"kind":"bump","stage":null}"#
        );
    }
}
