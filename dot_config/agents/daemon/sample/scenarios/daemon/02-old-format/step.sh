# The daemon drops a file of an old format when it loads the file, and converts nothing.
"$sample_dir/sample" stop
while IFS= read -r file; do
  jq '.version = 1' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
done < <(find "$SAMPLE_STATE/watchd" -name '*.json')
"$sample_dir/sample" start >/dev/null
(cd "$repo" && "$watchd" status >/dev/null)
dropped() { grep -q 'format 1 not supported, record removed' "$SAMPLE_STATE/watchd/watchd.log"; }
wait_until "the daemon drops a version 1 file" dropped
