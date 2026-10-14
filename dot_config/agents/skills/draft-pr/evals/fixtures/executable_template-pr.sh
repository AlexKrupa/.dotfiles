#!/usr/bin/env bash
# Usage: template-pr.sh <repo-dir>
# search-fix.sh, plus `docs/pull_request_template.md` (GitHub also reads templates from `docs/`)
# on `main`. Tests: with no wrapper, the description uses the template sections, not the skill
# sections.
"$(dirname "$0")/search-fix.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
git switch -q main
put docs/pull_request_template.md <<'EOF'
## Summary

<!-- What does this PR change and why? -->

## How was this tested?

<!-- Steps or tests -->

## Checklist

- [ ] I added or updated tests
- [ ] I updated the docs
EOF
commit "Add PR template"
git push -q
git switch -q fix/search-case
git rebase -q main
