# shellcheck shell=bash
# Shared helpers of the GitLab scripts. Source this file after the definition of
# die MESSAGE [EXIT CODE]. Writes nothing.

E_NOTFOUND=2
E_AMBIGUOUS=3
E_DEP=4
E_NETWORK=5

preflight() {
  command -v glab >/dev/null || die "glab not installed" "$E_DEP"
  command -v jq   >/dev/null || die "jq not installed"   "$E_DEP"
}

urlencode_path() { jq -nRr --arg s "$1" '$s|@uri'; }

# Usage: project_of_url URL. Prints the group/project path of an https, ssh, or scp-like git URL.
project_of_url() { sed -E 's#\.git$##; s#^[a-z+]+://[^/]+/##; s#^[^@/]+@[^:]+:##' <<<"$1"; }

# Usage: open_mr_of_branch BRANCH [PROJECT]. Prints the iid of the open MR of BRANCH, or nothing.
# With more than one open MR, it prints them on stderr and exits 3.
open_mr_of_branch() {
  local branch="$1" project="${2-}" json repo_args=()
  [[ -z "$project" ]] || repo_args=(-R "$project")
  json=$(glab mr list --source-branch "$branch" "${repo_args[@]}" --output json 2>/dev/null) \
    || die "glab mr list failed for branch '$branch'" "$E_NETWORK"
  case "$(jq 'length' <<<"$json")" in
    0) ;;
    1) jq -r '.[0].iid' <<<"$json" ;;
    *)
      {
        echo "multiple open MRs for branch '$branch':"
        jq -r '.[] | "  iid \(.iid): \(.title) (\(.web_url))"' <<<"$json"
      } >&2
      exit "$E_AMBIGUOUS"
      ;;
  esac
}
