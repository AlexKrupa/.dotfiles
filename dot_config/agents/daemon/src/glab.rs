use std::fmt;
use std::path::Path;
use std::process::{Output, Stdio};

use tokio::process::Command;
use tokio::sync::Semaphore;

use crate::nap::is_network_error;

static LIMIT: Semaphore = Semaphore::const_new(8);

#[derive(Debug)]
pub enum ApiError {
    Auth { status: u16, path: String },
    Network(String),
    Other(String),
}

impl fmt::Display for ApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        match self {
            ApiError::Auth { status, path } => write!(
                formatter,
                "HTTP {status} on {path}. The token needs the Read permission for {}.",
                permission_for(path)
            ),
            ApiError::Network(message) | ApiError::Other(message) => formatter.write_str(message),
        }
    }
}

pub async fn run(dir: &Path, args: &[&str]) -> std::io::Result<Output> {
    let _permit = LIMIT.acquire().await.expect("the semaphore is never closed");
    Command::new("glab")
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await
}

pub async fn api(dir: &Path, args: &[String]) -> Result<Vec<u8>, ApiError> {
    let path = args.first().map(String::as_str).unwrap_or_default();
    let argv: Vec<&str> = std::iter::once("api").chain(args.iter().map(String::as_str)).collect();
    let output = run(dir, &argv)
        .await
        .map_err(|error| ApiError::Other(format!("{path}: {error}")))?;
    match output.status.success() {
        true => Ok(output.stdout),
        false => Err(classify(path, &output.stderr)),
    }
}

pub type Task<T> = std::pin::Pin<Box<dyn std::future::Future<Output = T> + Send>>;

/// A drop of the returned future aborts the tasks.
pub async fn parallel<T: Send + 'static>(tasks: Vec<Task<T>>) -> Vec<T> {
    let mut set = tokio::task::JoinSet::new();
    let count = tasks.len();
    for (index, task) in tasks.into_iter().enumerate() {
        set.spawn(async move { (index, task.await) });
    }
    let mut results: Vec<Option<T>> = (0..count).map(|_| None).collect();
    while let Some(joined) = set.join_next().await {
        let (index, result) = joined.expect("a check task does not panic");
        results[index] = Some(result);
    }
    results
        .into_iter()
        .map(|result| result.expect("each task gives a result"))
        .collect()
}

pub fn classify(path: &str, stderr: &[u8]) -> ApiError {
    let text = String::from_utf8_lossy(stderr);
    let joined = text.strip_suffix('\n').unwrap_or(&text).replace('\n', " ");
    if let Some(status) = auth_status(&joined) {
        return ApiError::Auth {
            status,
            path: path.to_string(),
        };
    }
    match is_network_error(&joined) {
        true => ApiError::Network(format!("{path}: {joined}")),
        false => ApiError::Other(format!("{path}: {joined}")),
    }
}

fn auth_status(text: &str) -> Option<u16> {
    ["HTTP 401", "HTTP 403"]
        .iter()
        .filter_map(|pattern| text.find(pattern).map(|index| (index, pattern)))
        .min()
        .map(|(_, pattern)| pattern[5..].parse().expect("a status number"))
}

pub fn permission_for(path: &str) -> &'static str {
    const PERMISSIONS: &[(&str, &str)] = &[
        ("user", "User (user boundary)"),
        ("users/*/events*", "Event (user boundary)"),
        ("todos*", "Todo (user boundary)"),
        (
            "projects/*/merge_requests/*/notes*",
            "Work Item (group or project boundary)",
        ),
        (
            "projects/*/merge_requests/*/discussions*",
            "Work Item (group or project boundary)",
        ),
        (
            "projects/*/merge_requests*",
            "Merge Request (group or project boundary)",
        ),
        ("projects/*/pipelines*", "Pipeline (group or project boundary)"),
        ("graphql", "Merge Request (group or project boundary)"),
    ];
    PERMISSIONS
        .iter()
        .find(|(pattern, _)| glob(pattern.as_bytes(), path.as_bytes()))
        .map_or("Project (group or project boundary)", |(_, permission)| permission)
}

fn glob(pattern: &[u8], text: &[u8]) -> bool {
    match pattern.split_first() {
        None => text.is_empty(),
        Some((b'*', rest)) => (0..=text.len()).any(|start| glob(rest, &text[start..])),
        Some((first, rest)) => text.first() == Some(first) && glob(rest, &text[1..]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permission_for_maps_the_paths_of_the_bash_engine() {
        assert_eq!(permission_for("todos?project_id=1"), "Todo (user boundary)");
        assert_eq!(
            permission_for("projects/a/merge_requests/5/discussions?per_page=100"),
            "Work Item (group or project boundary)"
        );
        assert_eq!(permission_for("graphql"), "Merge Request (group or project boundary)");
        assert_eq!(permission_for("projects/a"), "Project (group or project boundary)");
    }
}
