# State files of format version 1: the new daemon loads them. It writes version 2 when a state
# changes, for example after a new commit in the worktree.
"$sample_dir/sample" stop
while IFS= read -r file; do
  jq '.version = 1' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
done < <(find "$SAMPLE_STATE/watchd" -name '*.json')
"$sample_dir/sample" start >/dev/null
(cd "$repo" && "$watchd" status >/dev/null)
if grep -q 'record removed' "$SAMPLE_STATE/watchd/watchd.log"; then
  echo "the daemon dropped a version 1 file" >&2
  exit 1
fi
commit "$SAMPLE_ROOT/repo-branch" feature.txt "Change feature"
state=$SAMPLE_STATE/watchd/worktrees/$(hash12 "$SAMPLE_ROOT/repo-branch").json
version_2() { [ "$(jq -r .version "$state")" = 2 ]; }
wait_until "the worktree state of the branch has version 2" version_2
