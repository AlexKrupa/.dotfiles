use std::path::Path;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

/// Files with no `version` field and version 1 files still load: their fields are the same.
pub const FORMAT_VERSION: u32 = 2;

#[derive(Serialize, Deserialize)]
pub struct Versioned<T> {
    pub version: u32,
    #[serde(flatten)]
    pub data: T,
}

pub enum Load<T> {
    Current(T),
    Converted(T),
    Dropped(String),
}

pub fn load<T: DeserializeOwned>(path: &Path) -> Result<Option<Load<T>>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    if text.trim().is_empty() {
        return Ok(None);
    }
    let value: serde_json::Value = serde_json::from_str(&text).map_err(|error| error.to_string())?;
    let loaded = match value.get("version") {
        None => Load::Converted(serde_json::from_value(value).map_err(|error| error.to_string())?),
        Some(version) if *version == 1 => {
            let versioned: Versioned<T> = serde_json::from_value(value).map_err(|error| error.to_string())?;
            Load::Converted(versioned.data)
        }
        Some(version) if *version == FORMAT_VERSION => {
            let versioned: Versioned<T> = serde_json::from_value(value).map_err(|error| error.to_string())?;
            Load::Current(versioned.data)
        }
        Some(version) => Load::Dropped(format!("format {version} not supported")),
    };
    Ok(Some(loaded))
}

pub fn save<T: Serialize>(path: &Path, data: &T) -> std::io::Result<()> {
    write_json(
        path,
        &Versioned {
            version: FORMAT_VERSION,
            data,
        },
    )
}

/// A temp file in the same folder and a rename, so that a reader never sees a partial file.
pub fn write_json<T: Serialize>(path: &Path, value: &T) -> std::io::Result<()> {
    let mut text = serde_json::to_string_pretty(value).map_err(std::io::Error::other)?;
    text.push('\n');
    let mut temp = path.as_os_str().to_owned();
    temp.push(".tmp");
    std::fs::write(&temp, text)?;
    std::fs::rename(&temp, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::subs::Agent;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("watchd-persist-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    const BASH_SUB: &str = r#"{"key":"app","slug":"app","repo":"/r","mode":"hub","mrs":[],"interval":120,"session_pid":1,"client_pid":2,"client_at":0,"replaced_sessions":[],"ended_mrs":[]}"#;

    #[test]
    fn bash_subscription_file_without_version_loads_as_converted() {
        let path = scratch("bash").join("app.json");
        std::fs::write(&path, BASH_SUB).unwrap();

        let loaded = load::<Agent>(&path).unwrap();

        let expected: Agent = serde_json::from_str(BASH_SUB).unwrap();
        assert!(matches!(loaded, Some(Load::Converted(sub)) if sub == expected));
    }

    #[test]
    fn saved_record_loads_as_current() {
        let path = scratch("current").join("app.json");
        let sub: Agent = serde_json::from_str(BASH_SUB).unwrap();

        save(&path, &sub).unwrap();

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.starts_with("{\n  \"version\": 2,\n"), "{text}");
        assert!(matches!(load::<Agent>(&path).unwrap(), Some(Load::Current(loaded)) if loaded == sub));
    }

    #[test]
    fn version_1_record_loads_as_converted() {
        let path = scratch("version-1").join("app.json");
        let versioned = BASH_SUB.replacen('{', r#"{"version": 1, "#, 1);
        std::fs::write(&path, &versioned).unwrap();

        let loaded = load::<Agent>(&path).unwrap();

        let expected: Agent = serde_json::from_str(BASH_SUB).unwrap();
        assert!(matches!(loaded, Some(Load::Converted(sub)) if sub == expected));
    }

    #[test]
    fn unknown_version_is_dropped_with_a_reason() {
        let path = scratch("unknown").join("app.json");
        std::fs::write(&path, r#"{"version": 7, "key": "app"}"#).unwrap();

        let loaded = load::<Agent>(&path).unwrap();

        assert!(matches!(loaded, Some(Load::Dropped(reason)) if reason == "format 7 not supported"));
    }

    #[test]
    fn missing_or_empty_file_is_none_and_bad_json_is_an_error() {
        let dir = scratch("missing");
        std::fs::write(dir.join("empty.json"), "\n").unwrap();
        std::fs::write(dir.join("bad.json"), "not json").unwrap();

        assert!(load::<Agent>(&dir.join("none.json")).unwrap().is_none());
        assert!(load::<Agent>(&dir.join("empty.json")).unwrap().is_none());
        assert!(load::<Agent>(&dir.join("bad.json")).is_err());
    }

    #[test]
    fn write_json_never_leaves_a_partial_file() {
        let path = scratch("atomic").join("app.json");
        std::fs::write(&path, "old content\n").unwrap();
        let mut reader = std::fs::File::open(&path).unwrap();

        write_json(&path, &serde_json::json!({"new": true})).unwrap();

        let mut old = String::new();
        std::io::Read::read_to_string(&mut reader, &mut old).unwrap();
        assert_eq!(old, "old content\n");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{\n  \"new\": true\n}\n");
        let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, vec!["app.json"]);
    }
}
