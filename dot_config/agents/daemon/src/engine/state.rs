use std::collections::BTreeMap;
use std::path::Path;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use super::EngineError;
use super::event::present;
use crate::persist::{self, Load};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Need {
    Todo,
    #[serde(rename = "main-failed")]
    MainFailed,
    Failed,
    Conflict,
    Reply,
    RequestedChanges,
    Commits,
    Ready,
    Draft,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PipelineState {
    pub id: u64,
    pub status: String,
}

/// `opened` and `default_pipeline` keep absent and empty apart, because a field that the saved
/// state does not have gives no event at its first check.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct HubState {
    #[serde(default)]
    pub todos: Vec<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opened: Option<Vec<u64>>,
    #[serde(default)]
    pub mrs: BTreeMap<String, HubMrState>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub default_pipeline: Option<Option<PipelineState>>,
    #[serde(default)]
    pub needs: Vec<Need>,
    #[serde(default)]
    pub present: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct HubMrState {
    #[serde(default)]
    pub updated_at: Option<String>,
    #[serde(default)]
    pub last_note_id: u64,
    #[serde(default)]
    pub last_own_note_id: u64,
    #[serde(default)]
    pub open_notes: Vec<u64>,
    #[serde(default)]
    pub reactions: Option<Vec<String>>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct StackState {
    #[serde(default)]
    pub mrs: BTreeMap<String, StackMrState>,
    #[serde(default)]
    pub needs: Vec<Need>,
    #[serde(default)]
    pub present: Vec<String>,
}

/// A `null` value gives no event for its change.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct StackMrState {
    pub state: Option<String>,
    pub draft: Option<bool>,
    pub pipeline: Option<PipelineState>,
    pub approved_by: Option<Vec<String>>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub labels: Option<Vec<String>>,
    pub conflicts: Option<bool>,
    pub mergeable: Option<bool>,
    pub merge_status: Option<String>,
    /// The head that the user last saw: at the first check, or at a new comment or approval of
    /// the user.
    pub seen_head: Option<String>,
    #[serde(default)]
    pub last_note_id: u64,
    pub reactions: Option<Vec<String>>,
    pub base: Option<String>,
    pub head: Option<String>,
    pub resolved: Option<Vec<String>>,
}

pub fn load<T: DeserializeOwned>(path: &Path) -> Result<Option<T>, EngineError> {
    match persist::load(path).map_err(|error| EngineError::Other(format!("{}: {error}", path.display())))? {
        None => Ok(None),
        Some(Load::Current(state) | Load::Converted(state)) => Ok(Some(state)),
        Some(Load::Dropped(reason)) => {
            let _ = std::fs::remove_file(path);
            eprintln!("watch-gitlab: {}: {reason}, record removed", path.display());
            Ok(None)
        }
    }
}

pub fn save<T: Serialize>(path: &Path, state: &T) -> Result<(), EngineError> {
    persist::save(path, state).map_err(|error| EngineError::Other(format!("{}: {error}", path.display())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_of_an_unknown_format_is_removed_for_a_first_check() {
        let dir = std::env::temp_dir().join(format!("watchd-state-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("app.json");
        std::fs::write(&path, r#"{"version": 9, "todos": "other"}"#).unwrap();

        let loaded: Option<HubState> = load(&path).unwrap();

        assert!(loaded.is_none());
        assert!(!path.exists());
    }

    #[test]
    fn bash_state_loads_and_saves_with_a_version() {
        let dir = std::env::temp_dir().join(format!("watchd-state-{}-bash", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("app.json");
        std::fs::write(&path, r#"{"todos": [4], "default_pipeline": null}"#).unwrap();

        let state: HubState = load(&path).unwrap().unwrap();
        save(&path, &state).unwrap();

        let saved: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved["version"], 1);
        assert_eq!(saved["todos"], serde_json::json!([4]));
        assert_eq!(saved["default_pipeline"], serde_json::Value::Null);
        let again: HubState = load(&path).unwrap().unwrap();
        assert_eq!(again.default_pipeline, Some(None));
    }
}
