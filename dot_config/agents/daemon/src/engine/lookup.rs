//! The open MR of a branch, read-only: the MR of a worktree with no git-spice MR and no review link.

use std::path::Path;

use serde::Deserialize;

use super::{Call, EngineError, api_pages, args, project_of_url, remote_url, uri_encode};

#[derive(Deserialize)]
struct Iid {
    iid: u64,
}

pub async fn lookup_mr(repo: &Path, branch: &str) -> Result<Option<u64>, EngineError> {
    let remote = remote_url(repo).ok_or_else(|| EngineError::Other(format!("no git remote in {}", repo.display())))?;
    let project = uri_encode(&project_of_url(&remote));
    let path = format!(
        "projects/{project}/merge_requests?source_branch={}&state=opened",
        uri_encode(branch)
    );
    let call = Call {
        dir: repo.to_path_buf(),
        args: args(&[&path]),
    };
    let mrs: Vec<Iid> = api_pages(call).await?;
    Ok(mrs.first().map(|mr| mr.iid))
}
