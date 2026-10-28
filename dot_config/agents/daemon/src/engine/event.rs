use serde::{Deserialize, Deserializer, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum EventKind {
    Todo,
    Opened,
    Note,
    Reaction,
    DefaultFailed,
    Pipeline,
    Comment,
    OwnComment,
    Approved,
    Unapproved,
    Draft,
    Ready,
    Title,
    Description,
    Labels,
    Conflict,
    Mergeable,
    Merged,
    Closed,
    Unaddressed,
    Pushed,
    Resolved,
    PullBlocked,
}

/// The field order is the order that readers expect. An `Option<Option<_>>` field is absent for
/// `None` and `null` for `Some(None)`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Event {
    pub kind: EventKind,
    pub iid: Option<u64>,
    pub title: Option<String>,
    pub url: String,
    pub actor: String,
    pub detail: String,
    pub branch: String,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub previous: Option<Option<String>>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub old_base: Option<Option<String>>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub old_head: Option<Option<String>>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub new_base: Option<Option<String>>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub new_head: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub line: Option<Option<u64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub own: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jobs: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failed: Option<Vec<FailedJob>>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FailedJob {
    pub id: u64,
    pub name: String,
    pub failure_reason: Option<String>,
}

/// Gives `Some(None)` for a `null` field, so that `null` and absent stay different.
pub fn present<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

impl Event {
    pub fn new(
        kind: EventKind,
        iid: Option<u64>,
        title: Option<&str>,
        url: &str,
        actor: &str,
        detail: &str,
        branch: &str,
    ) -> Event {
        Event {
            kind,
            iid,
            title: title.map(str::to_string),
            url: url.to_string(),
            actor: actor.to_string(),
            detail: detail.to_string(),
            branch: branch.to_string(),
            previous: None,
            old_base: None,
            old_head: None,
            new_base: None,
            new_head: None,
            path: None,
            line: None,
            item: None,
            own: None,
            jobs: None,
            author: None,
            failed: None,
        }
    }
}

pub fn short(text: &str) -> String {
    let mut result = String::new();
    let mut count = 0;
    let mut in_space = false;
    for char in text.chars() {
        let next = match (char.is_whitespace(), in_space) {
            (true, true) => continue,
            (true, false) => ' ',
            (false, _) => char,
        };
        in_space = char.is_whitespace();
        if count == 100 {
            break;
        }
        result.push(next);
        count += 1;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_collapses_whitespace_and_cuts_at_100_chars() {
        assert_eq!(short(" a\n\n b "), " a b ");
        assert_eq!(short(&"ż".repeat(120)).chars().count(), 100);
    }

    #[test]
    fn default_failed_event_serializes_like_jq() {
        let event = Event {
            previous: Some(Some("success".to_string())),
            item: Some("main-failed:main".to_string()),
            ..Event::new(
                EventKind::DefaultFailed,
                None,
                None,
                "u",
                "",
                "pipeline 9 failed",
                "main",
            )
        };
        assert_eq!(
            serde_json::to_string(&event).unwrap(),
            r#"{"kind":"default-failed","iid":null,"title":null,"url":"u","actor":"","detail":"pipeline 9 failed","branch":"main","previous":"success","item":"main-failed:main"}"#
        );
    }

    #[test]
    fn event_with_null_fields_reads_back_the_same() {
        let line = r#"{"kind":"pushed","iid":5,"title":"T","url":"u","actor":"","detail":"pushed h2","branch":"b","old_base":null,"old_head":"h1","new_base":"b1","new_head":"h2"}"#;
        let event: Event = serde_json::from_str(line).unwrap();
        assert_eq!(serde_json::to_string(&event).unwrap(), line);
    }
}
